/// Node-local resource willingness. Exceeding one of these limits means this
/// node declines the work; it does not make otherwise valid chain data invalid.
public struct NodeResourcePolicy: Sendable, Equatable {
    public static let `default` = NodeResourcePolicy()

    /// The bytes one content session may hold: a block's body and everything
    /// fetched with it to validate it.
    public let maximumAcquisitionStorageBytes: Int

    /// The bytes of content the node acquires at once, every chain and
    /// session together (`--max-acquisition-bytes`): requested and not yet
    /// checked and written to the store. Past it, fetches wait.
    public let maximumAcquisitionBytes: Int

    public static let defaultMaximumAcquisitionBytes = 256 * 1_024 * 1_024

    public init(
        maximumAcquisitionStorageBytes: Int = 64 * 1_024 * 1_024,
        maximumAcquisitionBytes: Int = Self.defaultMaximumAcquisitionBytes
    ) {
        precondition(maximumAcquisitionStorageBytes > 0)
        precondition(maximumAcquisitionBytes > 0)
        self.maximumAcquisitionStorageBytes = maximumAcquisitionStorageBytes
        self.maximumAcquisitionBytes = maximumAcquisitionBytes
    }
}
