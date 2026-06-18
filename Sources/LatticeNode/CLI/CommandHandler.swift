import Lattice
import cashew
import Foundation
import VolumeBroker

actor NodeState {
    var nodeArgs: NodeArgs

    init(nodeArgs: NodeArgs) {
        self.nodeArgs = nodeArgs
    }

    func updateArgs(_ args: NodeArgs) {
        self.nodeArgs = args
    }
}

@discardableResult
func handleCommand(_ line: String, node: LatticeNode, state: NodeState) async -> Bool {
    let parts = line.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: " ", omittingEmptySubsequences: true)
        .map(String.init)
    guard !parts.isEmpty else { return false }

    switch parts[0] {
    case "mine":
        // The node no longer mines in-process. Block production runs in the
        // external lattice-miner, which connects over the RPC
        // template/candidate endpoints.
        print("  This node does not mine. Run the external lattice-miner against")
        print("  its RPC endpoint to produce blocks (see docs/operations.md).")

    case "status":
        let statuses = await node.chainStatus()
        let currentArgs = await state.nodeArgs
        printStatus(statuses, resources: currentArgs)

    case "chains":
        let dirs = await node.allDirectories()
        let childDirs = await node.lattice.nexus.childDirectories()
        print("  Registered networks: \(dirs.joined(separator: ", "))")
        if !childDirs.isEmpty {
            print("  Known child chains: \(childDirs.sorted().joined(separator: ", "))")
        }

    case "peers":
        if let net = await node.network(for: "Nexus") {
            let count = await net.ivy.connectedPeers.count
            print("  Connected peers: \(count)")
        }

    case "quit", "exit":
        return true

    default:
        print("  Unknown command: \(parts[0])")
        print("  Commands: mine, status, chains, peers, quit")
    }
    return false
}
