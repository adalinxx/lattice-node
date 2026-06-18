import Foundation

public struct ChainAddress: Hashable, Sendable, Codable, CustomStringConvertible {
    public let components: [String]

    public init?(_ components: [String]) {
        guard !components.isEmpty, !components.contains(where: { $0.isEmpty }) else { return nil }
        self.components = components
    }

    public var root: String { components[0] }
    public var edgeLabel: String { components[components.count - 1] }
    public var key: String { components.joined(separator: "/") }
    public var description: String { key }
}

