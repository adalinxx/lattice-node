/// Node-local resource willingness. Exceeding one of these limits means this
/// node declines the work; it does not make otherwise valid chain data invalid.
public struct NodeResourcePolicy: Sendable, Equatable {
    public static let `default` = NodeResourcePolicy()

    public let maximumChainSpecBytes: Int
    public let maximumParentWitnessBytes: Int
    public let maximumWasmPolicies: Int
    public let maximumAcquisitionVolumes: Int
    public let maximumAcquisitionMembers: Int
    public let maximumAcquisitionStorageBytes: Int

    public init(
        maximumChainSpecBytes: Int = 1 * 1_024 * 1_024,
        maximumParentWitnessBytes: Int =
            Int(IvyConfig.protocolMaxFrameSize) - 1_024,
        maximumWasmPolicies: Int = 64,
        maximumAcquisitionVolumes: Int = 20_548,
        maximumAcquisitionMembers: Int = Int(UInt16.max),
        maximumAcquisitionStorageBytes: Int = 64 * 1_024 * 1_024
    ) {
        precondition(
            maximumChainSpecBytes > 0
                && maximumParentWitnessBytes > 0
                && maximumWasmPolicies > 0
                && maximumAcquisitionVolumes > 0
                && maximumAcquisitionMembers > 0
                && maximumAcquisitionStorageBytes > 0
        )
        self.maximumChainSpecBytes = maximumChainSpecBytes
        self.maximumParentWitnessBytes = maximumParentWitnessBytes
        self.maximumWasmPolicies = maximumWasmPolicies
        self.maximumAcquisitionVolumes = maximumAcquisitionVolumes
        self.maximumAcquisitionMembers = maximumAcquisitionMembers
        self.maximumAcquisitionStorageBytes = maximumAcquisitionStorageBytes
    }
}
import Ivy
