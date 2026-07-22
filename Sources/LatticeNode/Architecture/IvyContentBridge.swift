import Foundation
import Ivy
import Tally
import VolumeBroker
import cashew

/// A cashew source whose network request is always bound to the candidate root
/// selected by the caller. The root is never guessed from a frontier of CIDs.
public struct IvyRootContentSource: ContentSource, Sendable {
    public struct Attribution: Sendable, Equatable {
        public let servedByPublicKeys: Set<String>
        public let allResponsesComplete: Bool

        public var soleRemoteSupplierPublicKey: String? {
            servedByPublicKeys.count == 1 ? servedByPublicKeys.first : nil
        }
    }

    public final class AttributionCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Attribution?

        public init() {}

        fileprivate func record(_ attribution: Attribution) {
            lock.withLock { value = attribution }
        }

        public func snapshot() -> Attribution? {
            lock.withLock { value }
        }
    }

    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var peerPublicKeys: Set<String> = []
        private var complete = true

        func record(_ response: AttributedVolumeResponse, complete: Bool) {
            lock.lock()
            if let peer = response.servedBy {
                peerPublicKeys.insert(peer.publicKey)
            }
            self.complete = self.complete && complete
            lock.unlock()
        }

        func snapshot() -> Attribution {
            lock.lock()
            defer { lock.unlock() }
            return Attribution(
                servedByPublicKeys: peerPublicKeys,
                allResponsesComplete: complete
            )
        }

        func markIncomplete() {
            lock.withLock { complete = false }
        }
    }

    private final class Context: @unchecked Sendable {
        private static let maximumVolumes = 10_000
        private static let maximumBytes = 64 * 1024 * 1024

        let rootCID: String
        let trace = Trace()
        private let lock = NSLock()
        private var entries: [String: Data] = [:]
        private var volumes: [String: SerializedVolume] = [:]
        private var attemptedRoots = Set<String>()
        private var byteCount = 0

        init(rootCID: String) {
            self.rootCID = rootCID
        }

        func cached(_ cids: Set<String>) -> [String: Data] {
            lock.withLock { entries.filter { cids.contains($0.key) } }
        }

        func reserve(rootCID: String) -> Bool {
            lock.withLock {
                guard volumes[rootCID] == nil,
                      attemptedRoots.count < Self.maximumVolumes else {
                    return false
                }
                return attemptedRoots.insert(rootCID).inserted
            }
        }

        func store(_ volume: SerializedVolume) -> Bool {
            lock.withLock {
                var addedBytes = 0
                for (cid, data) in volume.entries where entries[cid] == nil {
                    let next = addedBytes.addingReportingOverflow(data.count)
                    guard !next.overflow else { return false }
                    addedBytes = next.partialValue
                }
                let nextTotal = byteCount.addingReportingOverflow(addedBytes)
                guard !nextTotal.overflow,
                      nextTotal.partialValue <= Self.maximumBytes else {
                    return false
                }
                for (cid, data) in volume.entries {
                    if let existing = entries[cid], existing != data { return false }
                }
                entries.merge(volume.entries) { existing, _ in existing }
                volumes[volume.root] = volume
                byteCount = nextTotal.partialValue
                return true
            }
        }

        func volume(rootCID: String) -> SerializedVolume? {
            lock.withLock { volumes[rootCID] }
        }
    }

    private enum Scope {
        @TaskLocal static var context: Context?
    }

    private let fetch: @Sendable (String) async -> AttributedVolumeResponse

    public init(ivy: Ivy) {
        fetch = { rootCID in
            await ivy.fetchVolume(rootCID: rootCID)
        }
    }

    public init(ivy: Ivy, peer: AuthenticatedPeer) {
        fetch = { rootCID in
            let response = await ivy.fetchVolume(
                rootCID: rootCID,
                from: peer
            )
            return response.servedBy == peer.id ? response : .empty
        }
    }

    init(
        fetch: @escaping @Sendable (String) async -> AttributedVolumeResponse
    ) {
        self.fetch = fetch
    }

    public func withRoot<T: Sendable>(
        _ rootCID: String,
        operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        let result = try await withRootTracing(rootCID, operation: operation)
        return result.value
    }

    public func withRootTracing<T: Sendable>(
        _ rootCID: String,
        initialResponse: AttributedVolumeResponse? = nil,
        capture: AttributionCapture? = nil,
        operation: @Sendable () async throws -> T
    ) async rethrows -> (value: T, attribution: Attribution) {
        let context = Context(rootCID: rootCID)
        if let initialResponse {
            let initialVolume = SerializedVolume(
                root: initialResponse.rootCID,
                entries: initialResponse.entries
            )
            let complete = initialResponse.rootCID == rootCID
                && (try? initialVolume.validate()) != nil
                && context.reserve(rootCID: rootCID)
                && context.store(initialVolume)
            context.trace.record(initialResponse, complete: complete)
        }
        do {
            let value = try await Scope.$context.withValue(
                context,
                operation: operation
            )
            let attribution = context.trace.snapshot()
            capture?.record(attribution)
            return (value, attribution)
        } catch {
            capture?.record(context.trace.snapshot())
            throw error
        }
    }

    public func fetch(_ cids: Set<String>) async -> [String: Data] {
        guard let context = Scope.context else { return [:] }
        guard !cids.isEmpty,
              cids.allSatisfy({ _isBoundedWireAtom($0) }) else {
            return [:]
        }
        let cached = context.cached(cids)
        for rootCID in cids.subtracting(cached.keys).sorted() {
            guard context.reserve(rootCID: rootCID) else { continue }
            let response = await fetch(rootCID)
            let volume = SerializedVolume(
                root: response.rootCID,
                entries: response.entries
            )
            let complete = response.rootCID == rootCID
                && (try? volume.validate()) != nil
                && context.store(volume)
            context.trace.record(response, complete: complete)
        }
        let result = context.cached(cids)
        if result.count != cids.count {
            context.trace.markIncomplete()
            return [:]
        }
        return result
    }

    func volume(rootCID: String) async -> SerializedVolume? {
        guard let context = Scope.context,
              context.rootCID == rootCID else { return nil }
        if context.volume(rootCID: rootCID) == nil {
            _ = await fetch([rootCID])
        }
        return context.volume(rootCID: rootCID)
    }
}

/// Serves complete local Volume boundaries from the recovered chain process.
struct ChainProcessIvyContentSource: IvyContentSource {
    let process: ChainProcess
    let authorizes: (@Sendable (AuthenticatedPeer) async -> Bool)?
    let transientRootVolume: (@Sendable (String) async -> SerializedVolume?)?

    init(
        process: ChainProcess,
        authorizes: (@Sendable (AuthenticatedPeer) async -> Bool)? = nil,
        transientRootVolume: (@Sendable (String) async -> SerializedVolume?)? = nil
    ) {
        self.process = process
        self.authorizes = authorizes
        self.transientRootVolume = transientRootVolume
    }

    func authorizesContentRequest(
        from peer: AuthenticatedPeer,
        rootCID: String,
        cids: [String]
    ) async -> Bool {
        false
    }

    func authorizesVolumeRequest(
        from peer: AuthenticatedPeer,
        rootCID: String
    ) async -> Bool {
        await authorizes?(peer) ?? true
    }

    func content(
        rootCID: String,
        cids: [String],
        maxDataBytes: Int
    ) async -> [ContentEntry] {
        // Node protocol v2 exchanges complete Volumes. Entry selection cannot
        // prove membership in the named root and is therefore never served.
        []
    }

    func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
        let volume: SerializedVolume
        if let transient = await transientRootVolume?(rootCID) {
            volume = transient
        } else if let stored = await process.volume(rootCID) {
            volume = stored
        } else {
            return []
        }
        guard (try? volume.validate()) != nil,
              volume.entries.values.reduce(0, { $0 + $1.count }) <= maxDataBytes else {
            return []
        }
        return volume.entries.sorted { $0.key < $1.key }.map {
            ContentEntry(cid: $0.key, data: $0.value)
        }
    }
}
