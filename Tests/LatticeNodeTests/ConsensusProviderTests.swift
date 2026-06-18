import XCTest
import Foundation
import Tally
import UInt256
@testable import LatticeNode

private final class ProviderBox: @unchecked Sendable { var provider: ConsensusProvider? }

final class ConsensusProviderTests: XCTestCase {
    func testRequestWireRoundTrip() {
        let payload = ConsensusProvider.encodeRequest(requestId: 42, chainPath: ["Nexus", "Alpha"], committerHashes: ["bafyblock"])
        let decoded = ConsensusProvider.decodeRequest(payload)
        XCTAssertEqual(decoded?.requestId, 42)
        XCTAssertEqual(decoded?.chainPath, ["Nexus", "Alpha"])
        XCTAssertEqual(decoded?.committerHashes, ["bafyblock"])
    }

    func testResponseWireRoundTripWithAndWithoutWeight() {
        let w = UInt256(123456789) &* UInt256(987654321)
        let withW = ConsensusProvider.decodeResponse(ConsensusProvider.encodeResponse(requestId: 7, weight: w))
        XCTAssertEqual(withW?.requestId, 7)
        XCTAssertEqual(withW?.weight, w)
        let nilW = ConsensusProvider.decodeResponse(ConsensusProvider.encodeResponse(requestId: 8, weight: nil))
        XCTAssertEqual(nilW?.requestId, 8)
        XCTAssertNil(nilW?.weight ?? nil)
    }

    func testServeRefusesOutOfScopePeer() async {
        let provider = ConsensusProvider(
            weightLookup: { _, _ in UInt256(999) },
            mayServe: { _, _ in false },             // out of scope
            send: { _, _, _ in })
        let peer = PeerID(publicKey: "abc")
        let resp = await provider.handleRequest(
            ConsensusProvider.encodeRequest(requestId: 1, chainPath: ["Nexus"], committerHashes: ["h"]), from: peer)
        XCTAssertNil(resp, "an out-of-scope peer gets no response (no weight leaked)")
    }

    func testServeReturnsWeightForInScopePeer() async {
        let expected = UInt256(7) &* UInt256(1_000_000)
        let provider = ConsensusProvider(
            weightLookup: { path, hashes in path == ["Nexus"] && hashes == ["h"] ? expected : nil },
            mayServe: { _, _ in true },
            send: { _, _, _ in })
        let peer = PeerID(publicKey: "abc")
        let payload = await provider.handleRequest(
            ConsensusProvider.encodeRequest(requestId: 5, chainPath: ["Nexus"], committerHashes: ["h"]), from: peer)
        XCTAssertNotNil(payload)
        let resp = ConsensusProvider.decodeResponse(payload!)
        XCTAssertEqual(resp?.requestId, 5)
        XCTAssertEqual(resp?.weight, expected)
    }

    /// Full in-process loopback: a client requests, the server gates+looks up and
    /// responds, the client's continuation resolves with the served weight.
    func testClientServerRoundTripResolves() async {
        let serverBox = ProviderBox(), clientBox = ProviderBox()
        let clientPeer = PeerID(publicKey: "client"), serverPeer = PeerID(publicKey: "server")
        let served = UInt256(42) &* UInt256(1_000_000_000)

        let server = ConsensusProvider(
            weightLookup: { _, _ in served },
            mayServe: { _, _ in true },
            send: { _, _, _ in })                    // server replies via handleRequest's return
        let client = ConsensusProvider(
            weightLookup: { _, _ in nil },
            mayServe: { _, _ in true },
            send: { _, _, payload in
                if let resp = await serverBox.provider?.handleRequest(payload, from: clientPeer) {
                    // The response arrives FROM the server (the peer we queried).
                    await clientBox.provider?.handleResponse(resp, from: serverPeer)
                }
            })
        serverBox.provider = server
        clientBox.provider = client

        let result = await client.requestWeight(from: serverPeer, chainPath: ["Nexus"], committerHashes: ["h"])
        XCTAssertEqual(result, served)
        let pendingC = await client.pendingCountForTesting()
        XCTAssertEqual(pendingC, 0, "the resolved request is removed from pending")
    }

    /// Anti-forgery (consensus-safety): a cw-response from a peer OTHER than the one
    /// queried must be ignored — otherwise a malicious peer could inject an arbitrary
    /// inherited weight into fork choice.
    func testForgedResponseFromWrongPeerIsIgnored() async {
        let serverBox = ProviderBox(), clientBox = ProviderBox()
        let clientPeer = PeerID(publicKey: "client"), serverPeer = PeerID(publicKey: "server")
        let attacker = PeerID(publicKey: "attacker")
        let real = UInt256(5)

        let server = ConsensusProvider(
            requestTimeout: .milliseconds(200),
            weightLookup: { _, _ in real }, mayServe: { _, _ in true }, send: { _, _, _ in })
        let client = ConsensusProvider(
            requestTimeout: .milliseconds(200),
            weightLookup: { _, _ in nil }, mayServe: { _, _ in true },
            send: { _, _, payload in
                // Race a FORGED response from the attacker (huge weight) before the
                // real server answers — the client must reject it.
                let forged = ConsensusProvider.encodeResponse(requestId: 0, weight: UInt256(99) &* UInt256(1_000_000_000))
                await clientBox.provider?.handleResponse(forged, from: attacker)
                if let resp = await serverBox.provider?.handleRequest(payload, from: clientPeer) {
                    await clientBox.provider?.handleResponse(resp, from: serverPeer)
                }
            })
        serverBox.provider = server
        clientBox.provider = client

        let result = await client.requestWeight(from: serverPeer, chainPath: ["Nexus"], committerHashes: ["h"])
        XCTAssertEqual(result, real, "the forged attacker response is ignored; the real one resolves")
    }

    func testClientTimesOutToNil() async {
        let provider = ConsensusProvider(
            requestTimeout: .milliseconds(100),
            weightLookup: { _, _ in nil },
            mayServe: { _, _ in true },
            send: { _, _, _ in })                    // never responds
        let result = await provider.requestWeight(from: PeerID(publicKey: "x"), chainPath: ["Nexus"], committerHashes: ["h"])
        XCTAssertNil(result, "no response within the timeout ⇒ nil")
        let pending = await provider.pendingCountForTesting()
        XCTAssertEqual(pending, 0, "timed-out request is cleared")
    }
}
