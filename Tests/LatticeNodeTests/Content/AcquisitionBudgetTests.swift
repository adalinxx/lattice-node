import Foundation
import Ivy
import Lattice
import XCTest
import cashew
@testable import LatticeNode

/// One byte budget for content being acquired, shared by every session of
/// every chain: never exceeded, waited on rather than refused, and never
/// held by bodies fetched ahead against the block a chain connects next.
final class AcquisitionBudgetTests: XCTestCase {
    private static let slice = IvyRootContentSource.firstReservationBytes

    /// What the fetches saw of the budget while they ran.
    private actor Probe {
        var budget: AcquisitionBudget?
        private(set) var mostReserved = 0
        private(set) var running = 0
        private(set) var mostRunning = 0
        private(set) var started: [String] = []
        private var gates: [String: CheckedContinuation<Void, Never>] = [:]
        private var held: Set<String> = []

        func set(_ budget: AcquisitionBudget) { self.budget = budget }

        func enter(_ root: String) async {
            mostReserved = max(mostReserved, await budget?.reserved ?? 0)
            running += 1
            mostRunning = max(mostRunning, running)
            started.append(root)
        }

        func leave() { running -= 1 }

        /// Fetches of `roots` wait in `fetch` until `open` lets them go.
        func hold(_ roots: Set<String>) { held = roots }

        func gate(_ root: String) async {
            guard held.contains(root) else { return }
            await withCheckedContinuation { gates[root] = $0 }
        }

        func open() {
            held = []
            for gate in gates.values { gate.resume() }
            gates = [:]
        }

        func hasStarted(_ root: String) -> Bool { started.contains(root) }
    }

    private func content(_ nonce: UInt64) throws -> (cid: String, data: Data) {
        let node = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: ["signer"], nonce: nonce, chainPath: ["Nexus"]
        )
        return (try HeaderImpl(node: node).rawCID, try XCTUnwrap(node.toData()))
    }

    /// Every item served as its own Volume, each fetch reporting to `probe`.
    private func source(
        _ items: [(cid: String, data: Data)], capacity: Int, probe: Probe
    ) async -> IvyRootContentSource {
        let served = Dictionary(uniqueKeysWithValues: items.map { ($0.cid, $0.data) })
        let source = IvyRootContentSource(
            maximumStorageBytes: Self.slice,
            maximumAcquisitionBytes: capacity,
            fetch: { root in
                await probe.enter(root)
                await probe.gate(root)
                try? await Task.sleep(nanoseconds: 2_000_000)
                await probe.leave()
                guard let data = served[root] else { return .empty }
                return AttributedVolumeResponse(rootCID: root, entries: [root: data], servedBy: nil)
            }
        )
        await probe.set(source.budget)
        return source
    }

    private func eventually(_ what: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail(what)
    }

    /// Many sessions at once, bodies fetched ahead and the node's own reads,
    /// as for several chains: every one completes, and what is reserved for
    /// answers never passes the budget.
    func testTheBudgetIsNeverExceededAcrossManyConcurrentSessions() async throws {
        let items = try (0..<48).map { try content($0) }
        let probe = Probe()
        let capacity = 3 * Self.slice
        let source = await source(items, capacity: capacity, probe: probe)
        let fetched = await withTaskGroup(of: Bool.self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    await source.withRootTracing(item.cid, lookAhead: index % 3 != 0) { session in
                        await session.fetch([item.cid])
                    }.value == [item.cid: item.data]
                }
            }
            var all = true
            for await one in group { all = all && one }
            return all
        }
        XCTAssertTrue(fetched)
        let mostReserved = await probe.mostReserved
        let mostRunning = await probe.mostRunning
        XCTAssertLessThanOrEqual(mostReserved, capacity)
        XCTAssertLessThanOrEqual(mostRunning, 3, "an answer at a time per slice of the budget")
        XCTAssertGreaterThan(mostRunning, 1, "the sessions shared the budget")
        let left = await source.budget.reserved
        XCTAssertEqual(left, 0, "every reservation came back")
    }

    /// Bodies fetched ahead fill what they may of the budget and wait on
    /// their peers. The block its chain connects next still gets its body,
    /// and so does one fetched ahead once its chain needs it next; the
    /// rest complete when their answers come.
    func testAFullBudgetWaitsAndTheNextBlockToConnectStillProgresses() async throws {
        let ahead = try (0..<3).map { try content(100 + $0) }
        let next = try content(200)
        let promoted = try content(201)
        let probe = Probe()
        // Room for one body ahead beside the one kept for the next block.
        let source = await source(ahead + [next, promoted], capacity: 2 * Self.slice, probe: probe)
        await probe.hold(Set(ahead.map(\.cid)))

        let waiting = ahead.map { item in
            Task {
                await source.withRootTracing(item.cid, lookAhead: true) { session in
                    await session.fetch([item.cid])
                }.value
            }
        }
        let aheadStarted = { await probe.started.filter { root in ahead.contains { $0.cid == root } }.count }
        try await eventually("one body ahead holds its share") { await aheadStarted() == 1 }
        try await Task.sleep(nanoseconds: 20_000_000)
        let started = await aheadStarted()
        XCTAssertEqual(started, 1, "the other bodies ahead wait")

        // The chain's next block: not held back by those fetched ahead.
        await source.budget.prioritize([next.cid])
        let connected = await source.withRootTracing(next.cid, lookAhead: true) { session in
            await session.fetch([next.cid])
        }.value
        XCTAssertEqual(connected, [next.cid: next.data])

        // A body that waited ahead goes once its chain needs it next.
        let late = Task {
            await source.withRootTracing(promoted.cid, lookAhead: true) { session in
                await session.fetch([promoted.cid])
            }.value
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let early = await probe.hasStarted(promoted.cid)
        XCTAssertFalse(early, "still ahead: it waits")
        await source.budget.prioritize([promoted.cid])
        let promotedValue = await late.value
        XCTAssertEqual(promotedValue, [promoted.cid: promoted.data])

        await probe.open()
        for (task, item) in zip(waiting, ahead) {
            let value = await task.value
            XCTAssertEqual(value, [item.cid: item.data])
        }
        let left = await source.budget.reserved
        XCTAssertEqual(left, 0)
    }

    /// A wait for the budget ends with its task: nothing is reserved for it.
    func testACancelledWaitReservesNothing() async throws {
        let budget = AcquisitionBudget(capacity: 2, headroom: 1)
        let first = await budget.reserve(1, root: "a", lookAhead: true)
        XCTAssertTrue(first)
        let waiter = Task { await budget.reserve(1, root: "b", lookAhead: true) }
        try await Task.sleep(nanoseconds: 10_000_000)
        waiter.cancel()
        let granted = await waiter.value
        XCTAssertFalse(granted)
        await budget.release(1)
        let left = await budget.reserved
        XCTAssertEqual(left, 0)
    }
}
