import Foundation
import XCTest
import LatticeNodeRPCFuzzSupport

final class RPCRequestFuzzTargetTests: XCTestCase {
    func testCommittedCorpusReplaysThroughProductionHelpersWithoutCrashing() throws {
        let corpus = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("FuzzCorpus/RPCRequests")
        let files = try FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil)
            .filter { !$0.hasDirectoryPath }
        XCTAssertFalse(files.isEmpty, "requires a committed RPC request fuzz corpus")

        for file in files {
            RPCRequestFuzzTarget.exercise(try Data(contentsOf: file))
        }
    }

    func testStructuredSeedsHitProductionGenesisAndRPCBodyParsers() throws {
        let genesisPayload = GenesisHexCodec.encodeEntries([
            GenesisHexEntry(cid: "genesis", data: Data([0x01, 0x02])),
            GenesisHexEntry(cid: "spec", data: Data([0x03]))
        ])
        let genesisHex = genesisPayload.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(GenesisHexCodec.parseHex(genesisHex)?.map(\.cid), ["genesis", "spec"])
        RPCRequestFuzzTarget.exercise(Data(genesisHex.utf8))

        let register = Data(#"{"chainPath":["Nexus","Child"],"endpoint":"http://127.0.0.1:8081"}"#.utf8)
        XCTAssertEqual(RPCRequestBodyCodecs.decodeRegisterChainRPC(register)?.chainPath, ["Nexus", "Child"])
        RPCRequestFuzzTarget.exercise(register)

        let template = Data(#"{"chainPath":["Nexus"],"childNodes":["http://localhost:8090"]}"#.utf8)
        XCTAssertEqual(RPCRequestBodyCodecs.decodeChainTemplate(template)?.chainPath, ["Nexus"])
        RPCRequestFuzzTarget.exercise(template)

        let templateWithStrayMinerKeys = Data(#"{"chainPath":["Nexus"],"minerPublicKey":"ignored","minerPrivateKey":"ignored"}"#.utf8)
        XCTAssertEqual(RPCRequestBodyCodecs.decodeChainTemplate(templateWithStrayMinerKeys)?.chainPath, ["Nexus"])
        RPCRequestFuzzTarget.exercise(templateWithStrayMinerKeys)

        let candidate = Data(#"{"parentBlockHex":"00ff","parentHomesteadVolume":{"root":"root","entries":{"root":"00"}},"childNodes":["http://127.0.0.1:8091"]}"#.utf8)
        XCTAssertEqual(RPCRequestBodyCodecs.decodeChainCandidate(candidate)?.parentBlockHex, "00ff")
        XCTAssertEqual(RPCRequestBodyCodecs.decodeChainCandidate(candidate)?.parentHomesteadVolume?.root, "root")
        RPCRequestFuzzTarget.exercise(candidate)

        let submit = Data(#"{"signatures":{},"bodyCID":"bafyrei","bodyData":"00","chainPath":["Nexus"]}"#.utf8)
        XCTAssertEqual(RPCRequestBodyCodecs.decodeSubmitTransaction(submit)?.bodyCID, "bafyrei")
        RPCRequestFuzzTarget.exercise(submit)

        let prepare = Data(#"{"nonce":1,"signers":["alice"],"fee":0,"accountActions":[{"owner":"alice","delta":1}],"depositActions":[{"nonce":"01","demander":"bob","amountDemanded":1,"amountDeposited":1}],"chainPath":["Nexus"]}"#.utf8)
        XCTAssertEqual(RPCRequestBodyCodecs.decodePrepareTransaction(prepare)?.nonce, 1)
        RPCRequestFuzzTarget.exercise(prepare)

        let deploy = Data(#"{"directory":"Child","parentDirectory":"Nexus","targetBlockTime":1000,"initialReward":1,"halvingInterval":100,"premine":0,"maxTransactionsPerBlock":100,"maxStateGrowth":1000,"maxBlockSize":1000000,"retargetWindow":10}"#.utf8)
        XCTAssertEqual(RPCRequestBodyCodecs.decodeDeployChain(deploy)?.directory, "Child")
        RPCRequestFuzzTarget.exercise(deploy)
    }

    func testChainCandidateFuzzCapMatchesProductionLimit() {
        let overhead = #"{"parentBlockHex":""#.utf8.count + #""}"#.utf8.count
        let acceptedHex = String(repeating: "0", count: RPCRequestBodyCodecs.maxInputBytes + 1 - overhead)
        let accepted = Data(#"{"parentBlockHex":"\#(acceptedHex)"}"#.utf8)
        XCTAssertGreaterThan(accepted.count, RPCRequestBodyCodecs.maxInputBytes)
        XCTAssertLessThanOrEqual(accepted.count, RPCRequestBodyCodecs.maxChainCandidateInputBytes)
        XCTAssertNotNil(RPCRequestBodyCodecs.decodeChainCandidate(accepted))
        XCTAssertEqual(RPCRequestFuzzTarget.maxInputBytes, RPCRequestBodyCodecs.maxChainCandidateInputBytes)
        RPCRequestFuzzTarget.exercise(accepted)

        let rejectedHex = String(repeating: "0", count: RPCRequestBodyCodecs.maxChainCandidateInputBytes + 1 - overhead)
        let rejected = Data(#"{"parentBlockHex":"\#(rejectedHex)"}"#.utf8)
        XCTAssertEqual(rejected.count, RPCRequestBodyCodecs.maxChainCandidateInputBytes + 1)
        XCTAssertNil(RPCRequestBodyCodecs.decodeChainCandidate(rejected))
    }

    func testGenesisFuzzCapCoversPayloadsAboveGenericRPCBodyLimit() {
        let entryOverhead = 2 + 2 + "genesis".utf8.count + 4
        let entryData = Data(repeating: 0x42, count: RPCRequestBodyCodecs.maxInputBytes + 1 - entryOverhead)
        let payload = GenesisHexCodec.encodeEntries([
            GenesisHexEntry(cid: "genesis", data: entryData)
        ])
        XCTAssertEqual(payload.count, RPCRequestBodyCodecs.maxInputBytes + 1)
        XCTAssertLessThanOrEqual(payload.count, RPCRequestFuzzTarget.maxInputBytes)
        XCTAssertNil(GenesisHexCodec.parsePayload(payload, maxPayloadBytes: RPCRequestBodyCodecs.maxInputBytes))
        XCTAssertEqual(
            GenesisHexCodec.parsePayload(payload, maxPayloadBytes: RPCRequestFuzzTarget.maxInputBytes)?.first?.cid,
            "genesis"
        )
        RPCRequestFuzzTarget.exercise(payload)

        let hex = payload.map { String(format: "%02x", $0) }.joined()
        let hexData = Data(hex.utf8)
        XCTAssertLessThanOrEqual(hexData.count, RPCRequestFuzzTarget.maxInputBytes)
        XCTAssertEqual(
            GenesisHexCodec.parseHex(hex, maxPayloadBytes: RPCRequestFuzzTarget.maxInputBytes)?.first?.data.count,
            entryData.count
        )
        RPCRequestFuzzTarget.exercise(hexData)
    }
}
