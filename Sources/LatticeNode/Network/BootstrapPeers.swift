import Lattice
import Ivy

public enum BootstrapPeers {
    public static let nexus: [PeerEndpoint] = [
        PeerEndpoint(publicKey: "ed019cb680d6179870415cd1ef60f607bbd0b9d55717205e512b9e5747fb02e9ad0b", host: "137.66.36.149", port: 4001),
        PeerEndpoint(publicKey: "ed0199d490f0f460cdee13cdaec839fdc11d90ef47209282bde12493190c9598c39e", host: "137.66.14.188", port: 4001),
        PeerEndpoint(publicKey: "ed01ce0dbd7bcf615782bb8d180b967ec00cc948e85a2e2a864b290a081cf6f8f575", host: "137.66.16.78", port: 4001),
    ]

    public static let testnet: [PeerEndpoint] = [
        PeerEndpoint(publicKey: "ed01bca7919f19752e437559911890ace150d44e4b70eac50ed8c9c24219e90a4706", host: "213.188.210.140", port: 4001),
        PeerEndpoint(publicKey: "ed01acde460f099a0564391174bec0a90d0fb65060d776a8f90aa5a14bc3148ef40d", host: "137.66.49.171", port: 4001),
        PeerEndpoint(publicKey: "ed0118e72576c217ad08d5e89561217725568e3fd6e85ee29cb5941b3d91249379f2", host: "149.248.199.178", port: 4001),
    ]

    public static let maxPeerConnections: Int = 128
    public static let maxPeerConnectionsDiscovery: Int = 512
}
