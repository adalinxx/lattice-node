import XCTest
@testable import Lattice
@testable import LatticeNode
import Lattice
import UInt256

final class I6NodeBoundedStructuresTests: XCTestCase {
    private func transfer(_ wallet: Wallet, nonce: UInt64, fee: UInt64 = 1) -> Transaction {
        wallet.buildTransfer(
            to: Wallet.create().address,
            amount: 1,
            fee: fee,
            nonce: nonce,
            chainPath: ["Nexus"]
        )!
    }

    private func streamTerminates(_ stream: AsyncStream<String>, maxElements: Int = 4) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                for _ in 0..<maxElements {
                    if await iterator.next() == nil { return true }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(500))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    func testSSEBackpressureDisconnectsSubscriberOnOverflow() async throws {
        let subscriptions = SubscriptionManager()
        let eventTypes: Set<SubscriptionEventType> = [.newBlock]
        let subscription = await RPCRoutes.makeEventStreamSubscription(
            subscriptions: subscriptions,
            eventTypes: eventTypes,
            bufferLimit: 1
        )
        guard let subscription else {
            return XCTFail("fixture: subscription should be accepted")
        }

        await subscriptions.emit(.newBlock(hash: "h0", height: 0, directory: "Nexus", timestamp: 0))
        await subscriptions.emit(.newBlock(hash: "h1", height: 1, directory: "Nexus", timestamp: 1))
        await subscriptions.emit(.newBlock(hash: "h2", height: 2, directory: "Nexus", timestamp: 2))

        let subscriberCount = await subscriptions.subscriberCount
        XCTAssertEqual(subscriberCount, 0, "overflowing an undrained SSE stream must remove the subscriber")
        let terminated = await streamTerminates(subscription.stream)
        XCTAssertTrue(
            terminated,
            "overflowing an undrained SSE stream must finish the stream instead of buffering indefinitely"
        )
    }

    func testDrainedMempoolAccountQueuesUseBoundedScalarFloorLRU() async throws {
        let floorCap = 16
        let mempool = NodeMempool(maxSize: floorCap, maxPerAccount: 1, maxNonceGap: 64)
        let wallets = (0..<(floorCap * 3)).map { _ in Wallet.create() }

        for wallet in wallets {
            switch await mempool.addTransaction(transfer(wallet, nonce: 0)) {
            case .added:
                break
            case .replacedExisting, .rejected:
                return XCTFail("fixture: distinct sender tx should be admitted")
            }
            await mempool.batchUpdateConfirmedNonces(updates: [(sender: wallet.address, nonce: 1)])
        }

        let remainingCount = await mempool.count
        let accountQueueCount = await mempool.accountQueueCountForTesting()
        let retainedFloorCount = await mempool.retainedConfirmedNonceFloorCountForTesting()
        XCTAssertEqual(remainingCount, 0, "all one-shot transactions should be drained")
        XCTAssertEqual(
            accountQueueCount,
            0,
            "drained senders must not retain full AccountTxQueue values"
        )
        XCTAssertLessThanOrEqual(
            retainedFloorCount,
            floorCap,
            "retained drained-sender nonce floors must be capped by mempool capacity"
        )

        let returning = try XCTUnwrap(wallets.last)
        let returningFloor = await mempool.retainedConfirmedNonceFloorForTesting(sender: returning.address)
        XCTAssertEqual(
            returningFloor,
            1,
            "the most recent drained sender should retain only its scalar confirmedNonce floor"
        )

        switch await mempool.addTransaction(transfer(returning, nonce: 0)) {
        case .rejected(let reason):
            XCTAssertTrue(reason.message.contains("Nonce already confirmed"))
        case .added, .replacedExisting:
            XCTFail("a returning drained sender must still reject a stale nonce below the retained floor")
        }

        switch await mempool.addTransaction(transfer(returning, nonce: 1)) {
        case .added:
            break
        case .replacedExisting, .rejected:
            XCTFail("a returning drained sender must reconstruct its queue at the retained floor")
        }
    }

    func testLiveInheritedWeightPromotesOnlyGrowsAndFallsBackToDurableFloor() {
        let index = LiveInheritedWeightIndex()
        let child = "child"
        let durableFloors: [String: UInt256] = [child: UInt256(20)]
        index.setDurableFloor { childHash in
            durableFloors[childHash] ?? .zero
        }

        XCTAssertTrue(index.recordParentAnchor(childHash: child, parentHash: "parent"))
        XCTAssertEqual(index.committers(forChild: child), ["parent"])
        // No live promote yet → the live projection is .zero; the durable floor wins.
        XCTAssertEqual(index.inheritedWeight(forChild: child), UInt256(20))

        // A live promote of the child's served union above the floor takes over.
        XCTAssertTrue(index.promoteChildUnionWeight(childHash: child, weight: UInt256(25)))
        XCTAssertEqual(index.inheritedWeight(forChild: child), UInt256(25))

        // A lower promote is a no-op (only-grows) and never lowers the reported weight.
        XCTAssertFalse(index.promoteChildUnionWeight(childHash: child, weight: UInt256(5)))
        XCTAssertEqual(index.inheritedWeight(forChild: child), UInt256(25))
    }

    /// Hierarchical-GHOST: a child committed by carriers on two parent forks must
    /// retain BOTH committers (the prior single-slot map dropped the first — the
    /// cross-fork grind loss). The full set is what the parent is re-queried with.
    func testTwoCarriersForOneChildBothRetained() {
        let index = LiveInheritedWeightIndex()
        let child = "child"
        XCTAssertTrue(index.recordParentAnchor(childHash: child, parentHash: "forkA"))
        XCTAssertTrue(index.recordParentAnchor(childHash: child, parentHash: "forkB"))
        // Re-recording an existing committer is a no-op (idempotent), not a drop.
        XCTAssertFalse(index.recordParentAnchor(childHash: child, parentHash: "forkA"))
        XCTAssertEqual(Set(index.committers(forChild: child)), ["forkA", "forkB"],
                       "both cross-fork committers must be retained for the parent re-query")
    }

    /// The served union never regresses: once a child's faithful union is promoted,
    /// a later lower answer (e.g. a transient/orphaned-fork view) cannot lower it.
    func testServedUnionNeverRegresses() {
        let index = LiveInheritedWeightIndex()
        let child = "child"
        XCTAssertTrue(index.promoteChildUnionWeight(childHash: child, weight: UInt256(100)))
        let high = index.inheritedWeight(forChild: child)
        XCTAssertFalse(index.promoteChildUnionWeight(childHash: child, weight: UInt256(40)))
        XCTAssertGreaterThanOrEqual(index.inheritedWeight(forChild: child), high)
        XCTAssertEqual(index.inheritedWeight(forChild: child), UInt256(100))
    }
}
