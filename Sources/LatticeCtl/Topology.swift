// The declarative unit `lattice` operates on: one host's chain-process tree.
//
// Lattice runs one process per chain; a child authenticates against its
// immediate parent's fact plane. This file makes that tree a value: each
// entry is one process, parents are derived from chain paths, and every
// verb reconciles against it rather than accumulating flag invocations.

import Foundation
import Lattice
import LatticeNode

struct TopologyChain: Codable {
    var listen: UInt16
    var fact: UInt16
    var rpc: UInt16
    /// Overlay bootstrap peers as `publicKey@host:port`. Only meaningful
    /// entries for this chain's own path; children of a local parent are
    /// wired to it automatically.
    var peers: [String]?
}

struct TopologyMine: Codable {
    var chain: String
    /// "cpu" or a path to any contract-conforming worker executable.
    var worker: String?
    var workers: Int?
    var batchSize: UInt64?
    /// A `lattice-rewards emit-batch` file; the cursor lives beside it.
    var rewards: String?
}

struct Topology: Codable {
    /// Chain path key (e.g. "Nexus", "Nexus/Payments") to process settings.
    var chains: [String: TopologyChain]
    var mine: TopologyMine?

    static let fileName = "lattice.json"

    static func load(root: URL) throws -> Topology {
        let url = root.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else {
            throw CtlError("no \(fileName) in \(root.path); run `lattice init` first")
        }
        return try JSONDecoder().decode(Topology.self, from: data)
    }

    func save(root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(self).write(
            to: root.appendingPathComponent(Self.fileName),
            options: .atomic
        )
    }

    /// Parent-before-child order, so `up` can wire children to a parent
    /// that is already running.
    func orderedPaths() -> [String] {
        chains.keys.sorted { $0.components(separatedBy: "/").count
            < $1.components(separatedBy: "/").count || $0 < $1 }
    }

    func validated() throws -> Topology {
        var ports: Set<UInt16> = []
        for (path, chain) in chains {
            guard let address = ChainAddress(string: path),
                  address.key == path else {
                throw CtlError("chain path is not absolute and Nexus-rooted: \(path)")
            }
            if address.components.count > 1 {
                let parent = address.components.dropLast().joined(separator: "/")
                guard chains[parent] != nil else {
                    throw CtlError("\(path) has no local parent \(parent); every child needs its immediate parent in the tree")
                }
            }
            for port in [chain.listen, chain.fact, chain.rpc] {
                guard ports.insert(port).inserted else {
                    throw CtlError("port \(port) is used twice")
                }
            }
        }
        if let mine, chains[mine.chain] == nil {
            throw CtlError("mine.chain \(mine.chain) is not in the tree")
        }
        return self
    }
}

struct CtlError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Filesystem layout under the data root. Identity keys live OUTSIDE the
/// wipeable chain directories so a flag-day wipe never destroys identity.
struct HostLayout {
    let root: URL

    init(root: String?) {
        self.root = URL(fileURLWithPath: root
            ?? FileManager.default.currentDirectoryPath)
    }

    func identityKey(for path: String) -> URL {
        root.appendingPathComponent("identity")
            .appendingPathComponent(
                path.replacingOccurrences(of: "/", with: "-") + ".key"
            )
    }

    func chainDirectory(for path: String) -> URL {
        root.appendingPathComponent("chains").appendingPathComponent(path)
    }

    func pidFile(for path: String) -> URL {
        root.appendingPathComponent("run").appendingPathComponent(
            path.replacingOccurrences(of: "/", with: "-") + ".pid"
        )
    }

    func logFile(for path: String) -> URL {
        root.appendingPathComponent("log").appendingPathComponent(
            path.replacingOccurrences(of: "/", with: "-") + ".log"
        )
    }
}
