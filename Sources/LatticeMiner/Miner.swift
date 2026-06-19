// lattice-miner: proof-of-work nonce-search worker.
//
// This worker does not fetch templates, allocate work, submit solutions,
// construct blocks, know child topology, generate proofs, or publish blocks.
// It searches one immutable assignment and reports the nonce/hash result.

import Foundation
import ArgumentParser
import Crypto
import Lattice
import LatticeMinerCore

private struct WorkerResult: Encodable {
    let workId: String
    let status: String
    let nonce: UInt64?
    let hash: String?
    let rangeStart: UInt64
    let rangeCount: UInt64
}

@available(macOS 15.0, *)
@main
struct LatticeMiner: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lattice-miner",
        abstract: "Search one immutable proof-of-work nonce range."
    )

    @Option(name: .long, help: "Work identifier assigned by the coordinator/node.")
    var workId: String

    @Option(name: .long, help: "Hex-encoded serialized nonce-0 Block node. Optional when --prefix-hex is given.")
    var blockHex: String?

    @Option(name: .long, help: "Hex-encoded nonce-independent PoW preimage prefix. Preferred: lets a worker mine without parsing the block (no Lattice dependency).")
    var prefixHex: String?

    @Option(name: .long, help: "Hex-encoded PoW target.")
    var target: String

    @Option(name: .long, help: "First nonce in this assignment.")
    var startNonce: UInt64 = 0

    @Option(name: .long, help: "Number of nonces to search.")
    var count: UInt64

    func run() throws {
        guard let parsedTarget = MinerLoopLogic.parseTarget(target) else {
            throw ValidationError("Invalid target")
        }
        // Prefer the coordinator-supplied prefix (no block parsing); fall back to
        // deriving it from the full block for older callers.
        let midstate: SHA256
        if let prefixHex, let prefixData = Data(hex: prefixHex), !prefixData.isEmpty {
            midstate = ProofOfWork.midstate(prefixBytes: [UInt8](prefixData))
        } else if let blockHex, let blockData = Data(hex: blockHex), let block = Block(data: blockData) {
            midstate = ProofOfWork.midstate(for: block)
        } else {
            throw ValidationError("Provide --prefix-hex or --block-hex")
        }

        let nonce = ProofOfWork.searchBatch(
            midstate: midstate,
            target: max(parsedTarget, ChainSpec.minimumTarget),
            startNonce: startNonce,
            count: count
        )
        let result: WorkerResult
        if let nonce {
            result = WorkerResult(
                workId: workId,
                status: "found",
                nonce: nonce,
                hash: ProofOfWork.hash(midstate: midstate, nonce: nonce).toHexString(),
                rangeStart: startNonce,
                rangeCount: count
            )
        } else {
            result = WorkerResult(
                workId: workId,
                status: "exhausted",
                nonce: nil,
                hash: nil,
                rangeStart: startNonce,
                rangeCount: count
            )
        }

        let data = try JSONEncoder().encode(result)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
