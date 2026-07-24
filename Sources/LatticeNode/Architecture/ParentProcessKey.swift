import Ivy

/// A locally configured Ivy process identity. It authenticates parent facts
/// but is never committed into chain state.
public struct ParentProcessKey: Codable, Hashable, Sendable,
    LosslessStringConvertible {
    public static let encodedByteCount = 64
    public let value: String

    public init?(_ value: String) {
        guard let key = try? PeerKey(value) else { return nil }
        self.value = key.hex
    }

    public var description: String { value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let key = Self(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid Ivy process key"
            )
        }
        self = key
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
