import Lattice
import Ivy

public enum BootstrapPeers {
    public static let nexus: [PeerEndpoint] = [

    ]

    public static let testnet: [PeerEndpoint] = [
        PeerEndpoint(publicKey: "ed01bca7919f19752e437559911890ace150d44e4b70eac50ed8c9c24219e90a4706", host: "213.188.210.140", port: 4001),
        PeerEndpoint(publicKey: "ed01acde460f099a0564391174bec0a90d0fb65060d776a8f90aa5a14bc3148ef40d", host: "137.66.49.171", port: 4001),
        PeerEndpoint(publicKey: "ed0118e72576c217ad08d5e89561217725568e3fd6e85ee29cb5941b3d91249379f2", host: "149.248.199.178", port: 4001),
    ]

    public static let maxPeerConnections: Int = 128
    public static let maxPeerConnectionsDiscovery: Int = 512
}
