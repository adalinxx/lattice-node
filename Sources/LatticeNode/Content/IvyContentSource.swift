import Foundation
import Ivy
import Lattice
import Tally
import VolumeBroker
import cashew

/// Where a content session writes each Volume once it checks against its
/// CIDs, and reads back what is held. What a session writes is retained
/// under the session's name for `root` until the session, or the node for
/// a block's body, lets go of it.
protocol AcquiredContentStore: Sendable {
    func storeAcquired(_ volumes: [SerializedVolume], root: String, session: String) async -> Bool
    func releaseAcquired(root: String, session: String) async
    func localData(_ cids: Set<String>) async -> [String: Data]
    func localVolume(_ root: String) async -> SerializedVolume?
}

/// A session with no node store behind it (tests, tools) holds what it
/// fetched in memory, for itself alone.
private struct SessionMemoryStore: AcquiredContentStore {
    let broker = MemoryBroker()

    func storeAcquired(_ volumes: [SerializedVolume], root: String, session: String) async -> Bool {
        (try? await broker.storeVolumesLocal(volumes)) != nil
    }

    func releaseAcquired(root: String, session: String) async {}

    func localData(_ cids: Set<String>) async -> [String: Data] {
        await broker.fetchDataLocal(cids: cids)
    }

    func localVolume(_ root: String) async -> SerializedVolume? {
        await broker.fetchVolumeLocal(root: root)
    }
}

/// A cashew source whose network request is always bound to the candidate root
/// selected by the caller. The root is never guessed from a frontier of CIDs.
public struct IvyRootContentSource: Sendable {
    private static let defaultPolicy = NodeResourcePolicy.default
    /// What a session is charged for each entry it holds, beyond the entry's
    /// CID and bytes: the heap a held entry costs in the session's set and
    /// its store's three tables (hash slots at their load, the owner set, the
    /// string and data headers). Measured at 273 to 430 bytes an entry
    /// (1,000 to 300,000 entries of 1 to 113 bytes, arm64 macOS) and rounded
    /// up, so the byte budget bounds memory however small a peer makes the
    /// entries it sends.
    static let retainedEntryOverhead = 512

    /// What a request first reserves of the node's acquisition budget, and
    /// the most its answer may carry. A guess, not a limit: a Volume past it
    /// is asked for again with the session's whole allowance reserved.
    static let firstReservationBytes = 1 << 20

    /// The bytes an answer holds in memory: each entry's CID and data, at
    /// most what its archive carried on the wire.
    static func answerBytes(_ entries: [String: Data]) -> Int {
        entries.reduce(0) { $0 + $1.key.utf8.count + $1.value.count }
    }

    public struct Attribution: Sendable, Equatable {
        public let servedByPublicKeys: Set<String>
        public let allResponsesComplete: Bool
        public let localCapacityUnavailable: Bool
        /// Verified content this session received was past its byte budget
        /// by this node's own count: this node's choice, not content nobody
        /// served. Never a size a peer only declared.
        public let byteBudgetExceeded: Bool
        public let contentUnavailable: Bool

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

    fileprivate final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var peerPublicKeys: Set<String> = []
        private var complete = true
        private var locallyLimited = false
        private var overBudget = false
        private var unavailable = false

        func record(_ response: AttributedVolumeResponse, complete: Bool) {
            record(servedBy: response.servedBy, failure: response.failure, empty: response == .empty, complete: complete)
        }

        func record(servedBy peer: PeerID?, failure: VolumeFetchFailure?, empty: Bool, complete: Bool) {
            lock.lock()
            if let peer {
                peerPublicKeys.insert(peer.publicKey)
            }
            self.complete = self.complete && complete
            locallyLimited = locallyLimited
                || failure == .localCapacityUnavailable
            unavailable = unavailable || empty
            lock.unlock()
        }

        func snapshot() -> Attribution {
            lock.lock()
            defer { lock.unlock() }
            return Attribution(
                servedByPublicKeys: peerPublicKeys,
                allResponsesComplete: complete,
                localCapacityUnavailable: locallyLimited,
                byteBudgetExceeded: overBudget,
                contentUnavailable: unavailable
            )
        }

        func markIncomplete() {
            lock.withLock { complete = false }
        }

        func markOverBudget() {
            lock.withLock { overBudget = true }
        }
    }

    /// What became of the Volume a bundle carried for a root.
    fileprivate enum Bundled {
        /// It verified and is held: its server is credited once it is asked for.
        case held(servedBy: PeerID?, bytes: Int)
        /// It did not verify: its server is reported once it is asked for.
        case invalid(servedBy: PeerID?)
    }

    fileprivate final class Context: @unchecked Sendable {
        let rootCID: String
        let name = UUID().uuidString
        let trace = Trace()
        let contentStore: any AcquiredContentStore
        let budget: AcquisitionBudget
        let lookAhead: Bool
        private let maximumStorageBytes: Int
        private let lock = NSLock()
        private var attemptedRoots = Set<String>()
        private var bundle: Task<AuthenticatedPeer?, Never>?
        /// What the bundle carried for each root, until the root is asked for.
        private var bundled: [String: Bundled] = [:]
        private var accountedMembers = Set<String>()
        private var storageByteCount = 0

        init(
            rootCID: String, maximumStorageBytes: Int, store: any AcquiredContentStore,
            budget: AcquisitionBudget, lookAhead: Bool
        ) {
            self.rootCID = rootCID
            self.maximumStorageBytes = maximumStorageBytes
            self.contentStore = store
            self.budget = budget
            self.lookAhead = lookAhead
        }

        func cached(_ cids: Set<String>) async -> [String: Data] {
            await contentStore.localData(cids)
        }

        var accountedBytes: Int { lock.withLock { storageByteCount } }

        /// What one more answer may carry: what is left of the session's
        /// own bound, and never more than the node's whole budget.
        var allowance: Int { min(max(maximumStorageBytes - accountedBytes, 0), budget.capacity) }

        func reserve(rootCID: String) -> Bool {
            lock.withLock { attemptedRoots.insert(rootCID).inserted }
        }

        func reserveBudget(_ bytes: Int) async -> Bool {
            await budget.reserve(bytes, root: rootCID, lookAhead: lookAhead)
        }

        /// What a peer's bundle of this session's root carried for
        /// `rootCID`, and the session that sent it. The bundle is requested
        /// once, on the session's first miss. A Volume from it is checked
        /// and written to the store as it arrives, and uncredited until it
        /// is taken as the answer to a request for its root.
        func bundled(
            _ rootCID: String,
            fetch: @escaping BundleFetch
        ) async -> (volume: Bundled, session: AuthenticatedPeer?)? {
            let task = lock.withLock {
                if let bundle { return bundle }
                let task = Task { [root = self.rootCID] in
                    let reserved = min(IvyRootContentSource.firstReservationBytes, self.allowance)
                    guard await self.reserveBudget(reserved) else { return nil as AuthenticatedPeer? }
                    let answer = await fetch(root)
                    let held = await self.hold(answer.volumes, reserved: reserved)
                    await self.budget.release(held)
                    return answer.session
                }
                bundle = task
                return task
            }
            let session = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            let volume = lock.withLock { bundled.removeValue(forKey: rootCID) }
            return volume.map { ($0, session) }
        }

        /// Writes what the bundle carried to the store, in the order served,
        /// while it fits the bytes reserved for it (and what more the
        /// budget has free) and the session's own bound. Volumes past either
        /// are dropped, and requested if the traversal needs them. Returns
        /// the bytes reserved, to give back.
        private func hold(_ volumes: [AttributedVolumeResponse], reserved: Int) async -> Int {
            var reserved = reserved
            var used = 0
            var accepted: [SerializedVolume] = []
            for response in volumes where lock.withLock({ bundled[response.rootCID] == nil }) {
                let volume = SerializedVolume(root: response.rootCID, entries: response.entries)
                guard (try? volume.validate()) != nil else {
                    lock.withLock { bundled[response.rootCID] = .invalid(servedBy: response.servedBy) }
                    continue
                }
                let bytes = IvyRootContentSource.answerBytes(volume.entries)
                if used + bytes > reserved {
                    guard await budget.tryReserve(used + bytes - reserved, root: rootCID, lookAhead: lookAhead) else { break }
                    reserved = used + bytes
                }
                guard account(volume) else { break }
                used += bytes
                accepted.append(volume)
                let data = volume.entries.values.reduce(0) { $0 + $1.count }
                lock.withLock { bundled[response.rootCID] = .held(servedBy: response.servedBy, bytes: data) }
            }
            if !accepted.isEmpty, !(await contentStore.storeAcquired(accepted, root: rootCID, session: name)) {
                lock.withLock { for volume in accepted { bundled[volume.root] = nil } }
            }
            return reserved
        }

        /// The session is over: a bundle still on its way is not waited for.
        func cancelBundle() {
            lock.withLock { bundle }?.cancel()
        }

        /// Charges `volume` against the session's own bound: false past it.
        private func account(_ volume: SerializedVolume) -> Bool {
            lock.withLock {
                var addedStorageBytes = 0
                for (cid, data) in volume.entries
                    where !accountedMembers.contains(cid) {
                    let framed = cid.utf8.count
                        .addingReportingOverflow(data.count)
                    guard !framed.overflow else { return false }
                    let framedWithOverhead = framed.partialValue
                        .addingReportingOverflow(IvyRootContentSource.retainedEntryOverhead)
                    guard !framedWithOverhead.overflow else { return false }
                    let next = addedStorageBytes.addingReportingOverflow(
                        framedWithOverhead.partialValue
                    )
                    guard !next.overflow else { return false }
                    addedStorageBytes = next.partialValue
                }
                let nextStorageBytes = storageByteCount.addingReportingOverflow(
                    addedStorageBytes
                )
                guard !nextStorageBytes.overflow,
                      nextStorageBytes.partialValue <= maximumStorageBytes else {
                    return false
                }
                accountedMembers.formUnion(volume.entries.keys)
                storageByteCount = nextStorageBytes.partialValue
                return true
            }
        }

        /// Writes a requested Volume that verified to the store.
        func store(_ volume: SerializedVolume) async -> Bool {
            guard account(volume) else {
                trace.markOverBudget()
                return false
            }
            return await contentStore.storeAcquired([volume], root: rootCID, session: name)
        }

        func volume(rootCID: String) async -> SerializedVolume? {
            guard rootCID == self.rootCID else { return nil }
            return await contentStore.localVolume(rootCID)
        }

        func release() async {
            await contentStore.releaseAcquired(root: rootCID, session: name)
        }
    }

    /// One Volume, its answer at most the given bytes (Ivy declines a
    /// larger one before taking it in: `callerBoundaryExceeded`).
    private let fetch: @Sendable (String, Int) async -> AttributedVolumeResponse
    /// The Volumes a peer that speaks bundles holds under a root (what it
    /// stored with that block), or none, and the session that sent them.
    /// Whatever a bundle lacks is fetched with `fetch`. The capable sessions
    /// the DHT names under the block's chain rendezvous are asked before the
    /// others; the record is a hint for whom to ask, never for what to accept.
    fileprivate typealias BundleFetch =
        @Sendable (String) async -> (volumes: [AttributedVolumeResponse], session: AuthenticatedPeer?)
    private let fetchBundle: @Sendable (_ rootCID: String, _ hosts: ChainHosts?) async
        -> (volumes: [AttributedVolumeResponse], session: AuthenticatedPeer?)
    /// Credits the peer that served a requested Volume once it verifies, so
    /// the overlay favours peers that serve this node when it is contended.
    private let credit: @Sendable (PeerID, Int) async -> Void
    /// Reports the peer that served a Volume failing its check for a root:
    /// the bytes it sent are not what their CIDs name.
    private let report: @Sendable (String, PeerID) async -> Void
    /// What the connected peers' hellos said they speak: who a bundle is asked of.
    let peerCapabilities = PeerCapabilities()
    let maximumStorageBytes: Int
    /// The node's one bound on content being acquired, every session's.
    let budget: AcquisitionBudget

    public final class Session: ContentSource {
        private let fetchVolume: @Sendable (String, Int) async -> AttributedVolumeResponse
        private let fetchBundle: BundleFetch
        private let credit: @Sendable (PeerID, Int) async -> Void
        private let report: @Sendable (String, PeerID) async -> Void
        private let peerCapabilities: PeerCapabilities
        private let context: Context

        fileprivate init(
            context: Context,
            fetch: @escaping @Sendable (String, Int) async -> AttributedVolumeResponse,
            fetchBundle: @escaping BundleFetch,
            credit: @escaping @Sendable (PeerID, Int) async -> Void,
            report: @escaping @Sendable (String, PeerID) async -> Void,
            peerCapabilities: PeerCapabilities
        ) {
            self.fetchVolume = fetch
            self.fetchBundle = fetchBundle
            self.credit = credit
            self.report = report
            self.peerCapabilities = peerCapabilities
            self.context = context
        }

        fileprivate func acceptInitialResponse(
            _ response: AttributedVolumeResponse
        ) async {
            let volume = SerializedVolume(
                root: response.rootCID,
                entries: response.entries
            )
            let valid = response.rootCID == context.rootCID
                && (try? volume.validate()) != nil
                && context.reserve(rootCID: context.rootCID)
            let complete = valid ? await context.store(volume) : false
            if complete { await creditServer(response.servedBy, volume: volume) }
            if !valid, let peer = response.servedBy { await report(context.rootCID, peer) }
            context.trace.record(response, complete: complete)
        }

        public func fetch(_ cids: Set<String>) async -> [String: Data] {
            guard !cids.isEmpty,
                  cids.allSatisfy({ _isBoundedWireAtom($0) }) else {
                return [:]
            }
            let cached = await context.cached(cids)
            for rootCID in cids.subtracting(cached.keys).sorted() {
                guard context.reserve(rootCID: rootCID) else { continue }
                // A Volume that does not verify, bundled or requested, reports
                // the peer that sent it, and the Volume is then requested
                // again: a bad Volume costs its server, never the block.
                // A Volume nobody sent (none found, or this node's own
                // capacity or cancellation) blames no one and is not retried,
                // nor is one from a peer already reported here.
                var reported = Set<PeerID>()
                switch await context.bundled(rootCID, fetch: fetchBundle) {
                case let (.held(peer, bytes), _)?:
                    if let peer { await credit(peer, bytes) }
                    context.trace.record(servedBy: peer, failure: nil, empty: false, complete: true)
                    continue
                case let (.invalid(peer), session)?:
                    if let peer {
                        reported.insert(peer)
                        await report(rootCID, peer)
                    }
                    context.trace.record(servedBy: peer, failure: nil, empty: false, complete: false)
                    if let session { peerCapabilities.revoke(ChainHandshake.volumeBundle, from: session) }
                case nil:
                    break
                }
                while true {
                    guard let answer = await request(rootCID) else {
                        context.trace.markIncomplete()
                        break
                    }
                    let blamed = answer.valid ? nil : answer.response.servedBy.flatMap { reported.insert($0).inserted ? $0 : nil }
                    if let blamed { await report(rootCID, blamed) }
                    context.trace.record(answer.response, complete: answer.complete)
                    guard !answer.valid, blamed != nil else { break }
                }
            }
            let result = await context.cached(cids)
            if result.count != cids.count {
                context.trace.markIncomplete()
                return [:]
            }
            return result
        }

        /// Asks for `rootCID` with bytes of the node's budget reserved for
        /// the answer, first a little, and the session's whole allowance if
        /// the Volume is larger, and writes it to the store if it verifies
        /// before giving the bytes back. Nil when the task was cancelled
        /// while it waited for the budget.
        private func request(
            _ rootCID: String
        ) async -> (response: AttributedVolumeResponse, valid: Bool, complete: Bool)? {
            let ceiling = context.allowance
            guard ceiling > 0 else {
                context.trace.markOverBudget()
                return (Self.declined, false, false)
            }
            var bytes = min(IvyRootContentSource.firstReservationBytes, ceiling)
            while true {
                guard await context.reserveBudget(bytes) else { return nil }
                let response = await fetchVolume(rootCID, bytes)
                let declined = response.failure == .callerBoundaryExceeded
                if declined || IvyRootContentSource.answerBytes(response.entries) > bytes, bytes < ceiling {
                    await context.budget.release(bytes)
                    bytes = ceiling
                    continue
                }
                if declined {
                    // A size the peer only declared is its claim: past the
                    // session's whole allowance it is not taken, and says
                    // nothing about this node's budget.
                    await context.budget.release(bytes)
                    return (response, false, false)
                }
                // An answer past the session's whole allowance (from a
                // fetch that takes no bound) is checked, and refused by it.
                let volume = SerializedVolume(root: response.rootCID, entries: response.entries)
                let valid = response.rootCID == rootCID && (try? volume.validate()) != nil
                let complete = valid ? await context.store(volume) : false
                await context.budget.release(bytes)
                if complete { await creditServer(response.servedBy, volume: volume) }
                return (response, valid, complete)
            }
        }

        /// What this node's own bound declined before taking it in.
        private static let declined = AttributedVolumeResponse(
            rootCID: "", entries: [:], servedBy: nil, failure: .callerBoundaryExceeded
        )

        public var attribution: Attribution { context.trace.snapshot() }

        fileprivate func cancelBundle() { context.cancelBundle() }

        /// What the entries this session holds are charged against its budget.
        var accountedBytes: Int { context.accountedBytes }

        /// A Volume this session requested passed CID validation: credit the
        /// peer that served it with its bytes.
        private func creditServer(_ peer: PeerID?, volume: SerializedVolume) async {
            guard let peer else { return }
            let bytes = volume.entries.values.reduce(0) { $0 + $1.count }
            await credit(peer, bytes)
        }

        func volume(rootCID: String) async -> SerializedVolume? {
            guard context.rootCID == rootCID else { return nil }
            if await context.volume(rootCID: rootCID) == nil {
                _ = await fetch([rootCID])
            }
            return await context.volume(rootCID: rootCID)
        }
    }

    public init(ivy: Ivy, policy: NodeResourcePolicy = .default) {
        let capabilities = peerCapabilities
        credit = Self.tallyCredit(ivy)
        report = Self.tallyReport(ivy)
        maximumStorageBytes = policy.maximumAcquisitionStorageBytes
        budget = AcquisitionBudget(
            capacity: policy.maximumAcquisitionBytes, headroom: policy.maximumAcquisitionStorageBytes
        )
        // A Volume is taken up to the bytes reserved for it, measured by
        // its archive before Ivy takes it in; a larger one is declined
        // there (`callerBoundaryExceeded`) and asked for again with more.
        fetch = { rootCID, bytes in
            await ivy.fetchVolume(rootCID: rootCID, maximumArchiveBytes: bytes, maximumEntries: .max)
        }
        // Asked only of the sessions whose hello said they answer it, one at
        // a time, each read as still capable when its turn comes. A session
        // keeps the capability only while every bundle it is asked for ends
        // (whole, or "no bundle"): one whose answer ends any other way is
        // then fetched from one Volume at a time, like a peer that speaks no
        // bundles. An answer this node cut short or never asked for (its
        // own capacity or boundary, a request not sent, its cancellation)
        // reports a failure and is not the peer's. The current peers of the
        // block's chain are asked before the others.
        fetchBundle = { rootCID, hosts in
            var named = Set<Data>()
            if let hosts {
                named = Set(await capabilities.sessions(hosting: hosts, ivy: ivy).map(\.sessionID))
            }
            var asked = Set<Data>()
            while let peer = ({
                let left = capabilities.sessions(speaking: ChainHandshake.volumeBundle)
                    .filter { !asked.contains($0.sessionID) }
                return left.filter { named.contains($0.sessionID) }.randomElement() ?? left.randomElement()
            })() {
                asked.insert(peer.sessionID)
                let answer = await ivy.fetchVolumeBundle(rootCID: rootCID, from: [peer])
                if !answer.ended, answer.failure == nil, !Task.isCancelled {
                    capabilities.revoke(ChainHandshake.volumeBundle, from: peer)
                }
                if !answer.volumes.isEmpty { return (answer.volumes, peer) }
            }
            return ([], nil)
        }
    }

    /// Credit verified content to the serving peer in the overlay's Tally.
    private static func tallyCredit(_ ivy: Ivy) -> @Sendable (PeerID, Int) async -> Void {
        { peer, bytes in await ivy.tally.recordUsefulReceived(peer: peer, bytes: bytes) }
    }

    /// A peer that served a Volume failing its check broke the protocol
    /// provably: Tally records the violation.
    private static func tallyReport(_ ivy: Ivy) -> @Sendable (String, PeerID) async -> Void {
        { _, peer in await ivy.tally.recordProtocolViolation(peer: peer) }
    }

    /// Over a `fetch` that takes no bound: an answer larger than the bytes
    /// reserved for it is asked for again with the session's whole
    /// allowance, and past that refused by the session's own bound.
    init(
        maximumStorageBytes: Int = Self.defaultPolicy.maximumAcquisitionStorageBytes,
        maximumAcquisitionBytes: Int = Self.defaultPolicy.maximumAcquisitionBytes,
        fetch: @escaping @Sendable (String) async -> AttributedVolumeResponse,
        fetchBundle: @escaping @Sendable (String) async -> [AttributedVolumeResponse] = { _ in [] },
        credit: @escaping @Sendable (PeerID, Int) async -> Void = { _, _ in },
        report: @escaping @Sendable (String, PeerID) async -> Void = { _, _ in }
    ) {
        self.credit = credit
        self.report = report
        self.maximumStorageBytes = maximumStorageBytes
        budget = AcquisitionBudget(capacity: maximumAcquisitionBytes, headroom: maximumStorageBytes)
        self.fetch = { rootCID, _ in await fetch(rootCID) }
        self.fetchBundle = { rootCID, _ in (await fetchBundle(rootCID), nil) }
    }

    public func withRoot<T: Sendable>(
        _ rootCID: String,
        operation: @Sendable (Session) async throws -> T
    ) async rethrows -> T {
        let result = try await withRootTracing(rootCID, operation: operation)
        return result.value
    }

    /// A content session for `rootCID`. What it fetches is written to
    /// `store` as each Volume verifies (in memory for the session alone
    /// without one) and let go of when the session ends, unless it is to
    /// `keep` it: the node then lets go of it by the root (a block's body
    /// once the block is decided, a template's reads once its tip moves).
    /// A `lookAhead` session (a body fetched ahead of its connect) waits
    /// behind the node's own work for the acquisition budget unless its
    /// block is one a chain connects next.
    func withRootTracing<T: Sendable>(
        _ rootCID: String,
        bundle: Bool = true,
        hosts: ChainHosts? = nil,
        store: (any AcquiredContentStore)? = nil,
        lookAhead: Bool = false,
        keep: Bool = false,
        initialResponse: AttributedVolumeResponse? = nil,
        capture: AttributionCapture? = nil,
        operation: @Sendable (Session) async throws -> T
    ) async rethrows -> (value: T, attribution: Attribution) {
        let fetchBundle = fetchBundle
        let bundled: BundleFetch = { rootCID in
            bundle ? await fetchBundle(rootCID, hosts) : ([], nil)
        }
        let context = Context(
            rootCID: rootCID,
            maximumStorageBytes: maximumStorageBytes,
            store: store ?? SessionMemoryStore(),
            budget: budget,
            lookAhead: lookAhead
        )
        let session = Session(
            context: context,
            fetch: fetch,
            fetchBundle: bundled,
            credit: credit,
            report: report,
            peerCapabilities: peerCapabilities
        )
        if let initialResponse {
            await session.acceptInitialResponse(initialResponse)
        }
        do {
            let value = try await operation(session)
            let attribution = session.attribution
            capture?.record(attribution)
            await end(session, context, keep: keep)
            return (value, attribution)
        } catch {
            capture?.record(session.attribution)
            await end(session, context, keep: keep)
            throw error
        }
    }

    /// A bundle still on its way is not waited for, and what the session
    /// wrote goes unless it is kept.
    private func end(_ session: Session, _ context: Context, keep: Bool) async {
        session.cancelBundle()
        if !keep { await context.release() }
    }
}

/// Serves complete local Volume boundaries from the recovered chain storage.
struct NodeStorageIvyContentSource: IvyContentSource {
    let storage: NodeStorage
    let transientRootVolume: (@Sendable (String) async -> SerializedVolume?)?

    init(
        storage: NodeStorage,
        transientRootVolume: (@Sendable (String) async -> SerializedVolume?)? = nil
    ) {
        self.storage = storage
        self.transientRootVolume = transientRootVolume
    }

    func volumeBundle(rootCID: String) async -> [String] {
        await storage.volumeBundle(rootCID)
    }

    func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
        let volume: SerializedVolume
        if let transient = await transientRootVolume?(rootCID) {
            volume = transient
        } else if let stored = await storage.volume(rootCID) {
            volume = stored
        } else {
            return []
        }
        guard (try? volume.validate()) != nil else { return [] }
        var remaining = maxDataBytes
        for data in volume.entries.values {
            guard data.count <= remaining else { return [] }
            remaining -= data.count
        }
        return volume.entries.sorted { $0.key < $1.key }.map {
            ContentEntry(cid: $0.key, data: $0.value)
        }
    }
}
