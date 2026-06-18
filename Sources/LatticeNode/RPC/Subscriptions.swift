import Foundation

public enum SubscriptionEventType: String, Sendable, CaseIterable {
    case newBlock
    case newTransaction
    case chainReorg
    case syncStatus
}

public enum NodeEvent: Sendable {
    case newBlock(hash: String, height: UInt64, directory: String, timestamp: Int64)
    case newTransaction(cid: String, fee: UInt64, sender: String)
    case chainReorg(directory: String, oldTip: String, newTip: String, depth: UInt64)
    case syncProgress(directory: String, current: UInt64, target: UInt64)

    public var type: SubscriptionEventType {
        switch self {
        case .newBlock: return .newBlock
        case .newTransaction: return .newTransaction
        case .chainReorg: return .chainReorg
        case .syncProgress: return .syncStatus
        }
    }

    private struct Envelope: Encodable {
        let event: String
        let data: EventData
    }

    private enum EventData: Encodable {
        case block(BlockData)
        case transaction(TransactionData)
        case reorg(ReorgData)
        case sync(SyncData)

        struct BlockData: Encodable { let hash: String; let height: UInt64; let directory: String; let timestamp: Int64 }
        struct TransactionData: Encodable { let cid: String; let fee: UInt64; let sender: String }
        struct ReorgData: Encodable { let directory: String; let oldTip: String; let newTip: String; let depth: UInt64 }
        struct SyncData: Encodable { let directory: String; let current: UInt64; let target: UInt64 }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .block(let d): try d.encode(to: encoder)
            case .transaction(let d): try d.encode(to: encoder)
            case .reorg(let d): try d.encode(to: encoder)
            case .sync(let d): try d.encode(to: encoder)
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    public func toJSON() -> String {
        let envelope: Envelope
        switch self {
        case .newBlock(let hash, let height, let directory, let timestamp):
            envelope = Envelope(event: "newBlock", data: .block(.init(hash: hash, height: height, directory: directory, timestamp: timestamp)))
        case .newTransaction(let cid, let fee, let sender):
            envelope = Envelope(event: "newTransaction", data: .transaction(.init(cid: cid, fee: fee, sender: sender)))
        case .chainReorg(let directory, let oldTip, let newTip, let depth):
            envelope = Envelope(event: "chainReorg", data: .reorg(.init(directory: directory, oldTip: oldTip, newTip: newTip, depth: depth)))
        case .syncProgress(let directory, let current, let target):
            envelope = Envelope(event: "syncStatus", data: .sync(.init(directory: directory, current: current, target: target)))
        }
        guard let data = try? Self.encoder.encode(envelope) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

public actor SubscriptionManager {
    public struct Subscriber: Sendable {
        let id: UUID
        let events: Set<SubscriptionEventType>
        let send: @Sendable (UUID, String) async -> Void
        /// Per-client key (source IP) for the per-client held-connection cap.
        let clientKey: String?
    }

    private var subscribers: [UUID: Subscriber] = [:]
    /// Held-connection count per client key, so one client (IP) cannot hold the
    /// entire global pool and starve everyone else — the same starvation class
    /// the per-IP RPC limiter closes, applied to long-lived SSE streams.
    private var perClientCounts: [String: Int] = [:]

    static let maxSubscribers = 1_000
    /// Max concurrent SSE streams a single client (source IP) may hold. Bounds
    /// one-IP monopolization of the global pool. Node-configurable via the
    /// initializer; defaults to a small fraction of the global cap.
    public static let defaultMaxSubscribersPerClient = 32
    let maxSubscribersPerClient: Int

    public init(maxSubscribersPerClient: Int = SubscriptionManager.defaultMaxSubscribersPerClient) {
        self.maxSubscribersPerClient = maxSubscribersPerClient
    }

    public func subscribe(
        events: Set<SubscriptionEventType>,
        clientKey: String? = nil,
        send: @escaping @Sendable (String) async -> Void
    ) -> UUID? {
        subscribeWithID(events: events, clientKey: clientKey) { _, json in
            await send(json)
        }
    }

    public func subscribeWithID(
        events: Set<SubscriptionEventType>,
        clientKey: String? = nil,
        send: @escaping @Sendable (UUID, String) async -> Void
    ) -> UUID? {
        guard subscribers.count < Self.maxSubscribers else { return nil }
        // Per-client cap: a single source IP cannot hold more than its share of
        // the global pool. Unknown client keys (e.g. in-process harness) bypass.
        if let clientKey, (perClientCounts[clientKey] ?? 0) >= maxSubscribersPerClient {
            return nil
        }
        let id = UUID()
        subscribers[id] = Subscriber(id: id, events: events, send: send, clientKey: clientKey)
        if let clientKey { perClientCounts[clientKey, default: 0] += 1 }
        return id
    }

    public func unsubscribe(id: UUID) {
        guard let removed = subscribers.removeValue(forKey: id) else { return }
        if let key = removed.clientKey, let n = perClientCounts[key] {
            if n <= 1 { perClientCounts.removeValue(forKey: key) }
            else { perClientCounts[key] = n - 1 }
        }
    }

    public func emit(_ event: NodeEvent) async {
        let json = event.toJSON()
        let matchingSubscribers = subscribers.values.filter { $0.events.contains(event.type) }
        for subscriber in matchingSubscribers {
            await subscriber.send(subscriber.id, json)
        }
    }

    public var subscriberCount: Int { subscribers.count }

    public func subscriberCount(clientKey: String) -> Int {
        perClientCounts[clientKey] ?? 0
    }
}
