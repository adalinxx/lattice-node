import Foundation

/// The bytes of content this node is acquiring at once, across every chain
/// and content session: reserved before a request is sent, at most what its
/// answer may carry, and given back once the answer is checked against its
/// CIDs and written to the store, or failed. Past the operator's bound a
/// request waits; nothing asked for is declined for it.
///
/// A look-ahead body may not take the last `headroom` bytes: those are for
/// the blocks a chain can connect next and the node's own work, so a window
/// of fetches ahead of them never holds what they need. A reservation is
/// held for one answer, never while waiting for another, so the budget
/// always comes back.
actor AcquisitionBudget {
    let capacity: Int
    let headroom: Int
    private var used = 0
    private var urgentRoots: Set<String> = []
    private var waiters: [Waiter] = []

    private struct Waiter {
        let id: UUID
        let bytes: Int
        let root: String
        let lookAhead: Bool
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// `headroom` is the largest single body: what one next block may need.
    init(capacity: Int, headroom: Int) {
        precondition(capacity > 0 && headroom > 0)
        self.capacity = capacity
        self.headroom = min(headroom, capacity)
    }

    var reserved: Int { used }

    /// The blocks each chain can connect next: their look-ahead bodies are
    /// fetched as the node's own work.
    func prioritize(_ roots: Set<String>) {
        guard roots != urgentRoots else { return }
        urgentRoots = roots
        grant()
    }

    /// Reserves `bytes` (at most the capacity) for an answer to a request
    /// of the session for `root`, waiting while the budget is full. False
    /// when the task was cancelled first.
    func reserve(_ bytes: Int, root: String, lookAhead: Bool) async -> Bool {
        let bytes = min(max(bytes, 0), capacity)
        guard !Task.isCancelled else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: id, bytes: bytes, root: root, lookAhead: lookAhead, continuation: continuation))
                if Task.isCancelled { cancel(id) } else { grant() }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// Takes `bytes` more without waiting, if they fit now and nobody waits.
    func tryReserve(_ bytes: Int, root: String, lookAhead: Bool) -> Bool {
        guard bytes >= 0, bytes <= capacity, waiters.isEmpty,
              fits(bytes, lookAhead: lookAhead && !urgentRoots.contains(root)) else {
            return false
        }
        used += bytes
        return true
    }

    func release(_ bytes: Int) {
        used -= min(max(bytes, 0), capacity)
        precondition(used >= 0)
        grant()
    }

    private func fits(_ bytes: Int, lookAhead: Bool) -> Bool {
        bytes <= capacity - used - (lookAhead ? headroom : 0)
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
        grant()
    }

    /// Waiters in order, the ones the node needs next first; within each,
    /// the first that does not fit holds the ones behind it, so a large
    /// answer is not passed over for good by small ones.
    private func grant() {
        for urgent in [true, false] {
            while let index = waiters.firstIndex(where: { isUrgent($0) == urgent }) {
                let waiter = waiters[index]
                guard fits(waiter.bytes, lookAhead: !urgent) else { break }
                waiters.remove(at: index)
                used += waiter.bytes
                waiter.continuation.resume(returning: true)
            }
        }
    }

    private func isUrgent(_ waiter: Waiter) -> Bool {
        !waiter.lookAhead || urgentRoots.contains(waiter.root)
    }
}
