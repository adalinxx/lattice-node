import Lattice
import Foundation

func printStatus(_ statuses: [LatticeNode.ChainInfo], resources: NodeArgs) {
    print()
    let chainCount = max(statuses.count, 1)
    let memPerChain = resources.memoryGB / Double(chainCount)
    let diskPerChain = resources.diskGB / Double(chainCount)
    print("  Resources: \(fmt(resources.memoryGB)) GB memory / \(fmt(resources.diskGB)) GB disk across \(chainCount) chain(s)")
    print("  Per-chain: \(fmt(memPerChain)) GB memory / \(fmt(diskPerChain)) GB disk / \(Int(resources.mempoolMB)/chainCount) MB mempool")
    print()
    print("  Chain               Height     Tip                    Mining   Mempool")
    print("  -----               ------     ---                    ------   -------")
    for s in statuses {
        let dir = s.directory.padding(toLength: 18, withPad: " ", startingAt: 0)
        let height = String(s.height).padding(toLength: 10, withPad: " ", startingAt: 0)
        let tip = String(s.tip.prefix(22)).padding(toLength: 22, withPad: " ", startingAt: 0)
        let mining = (s.mining ? "YES" : "no").padding(toLength: 8, withPad: " ", startingAt: 0)
        print("  \(dir) \(height) \(tip) \(mining) \(s.mempoolCount)")
    }
    print()
}

private func fmt(_ gb: Double) -> String {
    String(format: "%.2f", gb)
}
