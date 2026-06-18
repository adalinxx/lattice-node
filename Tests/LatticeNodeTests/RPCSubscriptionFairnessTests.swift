import XCTest
@testable import LatticeNode

final class RPCSubscriptionFairnessTests: XCTestCase {
    func testOneClientCannotConsumeAllGlobalSubscriptionSlots() async throws {
        let subscriptions = SubscriptionManager(maxSubscribersPerClient: 100)
        let events: Set<SubscriptionEventType> = [.newBlock]
        var accepted: [UUID] = []

        for _ in 0..<100 {
            let id = await subscriptions.subscribe(events: events, clientKey: "198.51.100.7") { _ in }
            guard let id else {
                return XCTFail("expected subscription to be accepted before per-client cap")
            }
            accepted.append(id)
        }

        let rejected = await subscriptions.subscribe(events: events, clientKey: "198.51.100.7") { _ in }
        let totalCount = await subscriptions.subscriberCount
        let firstClientCount = await subscriptions.subscriberCount(clientKey: "198.51.100.7")
        XCTAssertNil(rejected)
        XCTAssertEqual(totalCount, 100)
        XCTAssertEqual(firstClientCount, 100)

        let otherClient = await subscriptions.subscribe(events: events, clientKey: "198.51.100.8") { _ in }
        let countAfterOtherClient = await subscriptions.subscriberCount
        XCTAssertNotNil(otherClient)
        XCTAssertEqual(countAfterOtherClient, 101)
    }

    func testUnsubscribeReleasesPerClientSubscriptionSlot() async throws {
        let subscriptions = SubscriptionManager(maxSubscribersPerClient: 100)
        let events: Set<SubscriptionEventType> = [.newBlock]
        var ids: [UUID] = []

        for _ in 0..<100 {
            let id = await subscriptions.subscribe(events: events, clientKey: "198.51.100.7") { _ in }
            guard let id else {
                return XCTFail("expected subscription to be accepted before per-client cap")
            }
            ids.append(id)
        }

        let rejected = await subscriptions.subscribe(events: events, clientKey: "198.51.100.7") { _ in }
        XCTAssertNil(rejected)
        await subscriptions.unsubscribe(id: ids[0])

        let replacement = await subscriptions.subscribe(events: events, clientKey: "198.51.100.7") { _ in }
        let firstClientCount = await subscriptions.subscriberCount(clientKey: "198.51.100.7")
        XCTAssertNotNil(replacement)
        XCTAssertEqual(firstClientCount, 100)
    }
}
