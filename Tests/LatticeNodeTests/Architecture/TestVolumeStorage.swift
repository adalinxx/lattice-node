import Foundation
import UInt256
import VolumeBroker

@testable import LatticeNode

func testNodeStore(
    databasePath: URL,
    nexusGenesisCID: String,
    chainPath: [String],
    minimumRootWork: UInt256,
    spawningParentKey: String = "",
    issuingAuthorityKey: String = String(repeating: "a", count: 64)
) throws -> NodeStore {
    let broker = try DiskBroker(
        path: databasePath.deletingLastPathComponent()
            .appendingPathComponent("volumes.db").path
    )
    return try NodeStore(
        databasePath: databasePath,
        nexusGenesisCID: nexusGenesisCID,
        chainPath: chainPath,
        minimumRootWork: minimumRootWork,
        spawningParentKey: spawningParentKey,
        issuingAuthorityKey: issuingAuthorityKey,
        recoveryVolumeStorer: BrokerStorer(broker: broker),
        recoveryVolumeBroker: broker
    )
}
