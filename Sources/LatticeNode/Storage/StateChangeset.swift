import Foundation

public struct StateChangeset: Sendable {
    public let height: UInt64
    public let blockHash: String
    public let stateRoot: String

    public init(
        height: UInt64,
        blockHash: String,
        stateRoot: String
    ) {
        self.height = height
        self.blockHash = blockHash
        self.stateRoot = stateRoot
    }
}
