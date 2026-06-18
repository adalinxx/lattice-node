import Foundation
import Ivy

struct NodeArgs {
    var port: UInt16 = 4001
    var dataDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lattice")
    var bootstrapPeers: [PeerEndpoint] = []
    var memoryGB: Double = 0.25
    var diskGB: Double = 1.0
    var mempoolMB: Double = 64.0
    var miningBatch: UInt64 = 10_000
    var autosize: Bool = false
    var maxMemoryGB: Double? = nil
    var maxDiskGB: Double? = nil
    var rpcPort: UInt16? = nil
    var rpcBindAddress: String = "127.0.0.1"
    var enableDiscovery: Bool = true
    var rpcAllowedOrigin: String = "http://127.0.0.1"
    var discoveryOnly: Bool = false
    var maxPeerConnections: Int? = nil
    var maxFrameSize: UInt32 = IvyConfig.defaultMaxFrameSize
}
