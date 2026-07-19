import Foundation
import Ivy
import Tally
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

    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var peerPublicKeys: Set<String> = []
        private var complete = true

        func record(_ response: AttributedContentResponse, complete: Bool) {
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
    }

    private final class Context: @unchecked Sendable {
        let rootCID: String
        let trace = Trace()

        init(rootCID: String) { self.rootCID = rootCID }
    }

    private enum Scope {
        @TaskLocal static var context: Context?
    }

    private let fetch: @Sendable (String, [String]) async -> AttributedContentResponse

    public init(ivy: Ivy) {
        fetch = { rootCID, cids in
            await ivy.fetchContent(rootCID: rootCID, cids: cids)
        }
    }

    init(
        fetch: @escaping @Sendable (String, [String]) async -> AttributedContentResponse
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
        operation: @Sendable () async throws -> T
    ) async rethrows -> (value: T, attribution: Attribution) {
        let context = Context(rootCID: rootCID)
        let value = try await Scope.$context.withValue(context, operation: operation)
        return (value, context.trace.snapshot())
    }

    public func fetch(_ cids: Set<String>) async -> [String: Data] {
        guard let context = Scope.context else { return [:] }
        let rootCID = context.rootCID
        guard
              _isBoundedWireAtom(rootCID),
              !cids.isEmpty,
              cids.allSatisfy({ _isBoundedWireAtom($0) }) else {
            return [:]
        }
        let response = await fetch(
            rootCID,
            cids.filter { $0 != rootCID }.sorted()
        )
        let expectedResponse = cids.union([rootCID])
        let complete = Set(response.entries.keys) == expectedResponse
        context.trace.record(response, complete: complete)
        guard complete else { return [:] }
        return response.entries.filter { cids.contains($0.key) }
    }
}

/// Serves only exact, complete selections from the recovered chain process.
/// The process itself decides which local sparse or complete Volume bytes are
/// available; this adapter adds only Ivy's response-size contract.
struct ChainProcessIvyContentSource: IvyContentSource {
    let process: ChainProcess

    func content(
        rootCID: String,
        cids: [String],
        maxDataBytes: Int
    ) async -> [ContentEntry] {
        guard !cids.isEmpty,
              cids.first == rootCID,
              Set(cids).count == cids.count else { return [] }
        let entries = await process.content(Set(cids))
        guard entries.count == cids.count else { return [] }

        var remaining = maxDataBytes
        var result: [ContentEntry] = []
        result.reserveCapacity(cids.count)
        for cid in cids {
            guard let data = entries[cid], data.count <= remaining else { return [] }
            remaining -= data.count
            result.append(ContentEntry(cid: cid, data: data))
        }
        return result
    }
}
