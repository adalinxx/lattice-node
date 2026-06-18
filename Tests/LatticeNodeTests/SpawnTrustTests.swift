import XCTest
import Foundation
import Crypto
import Ivy
import Tally
@testable import LatticeNode

final class SpawnTrustTests: XCTestCase {
    private func keyPair(_ seed: UInt8) -> (publicKey: String, privateKey: Data) {
        let priv = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32))
        let pubHex = priv.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        return (publicKey: pubHex, privateKey: priv.rawRepresentation)
    }

    // Spawn tree: root → a → b, scopes nesting strictly deeper.
    private func tree() -> (chain: [SpawnCertificate], rootKey: String, leaf: PeerID, aKey: String) {
        let root = keyPair(0x01), a = keyPair(0x02), b = keyPair(0x03)
        let chain = [
            SpawnCertificate.issue(childPublicKey: a.publicKey, chainPath: ["Nexus", "a"], issuerKeyPair: root)!,
            SpawnCertificate.issue(childPublicKey: b.publicKey, chainPath: ["Nexus", "a", "b"], issuerKeyPair: a)!,
        ]
        return (chain, root.publicKey, PeerID(publicKey: b.publicKey), a.publicKey)
    }

    func testTrustedChainClassifiedWithScope() async {
        let (chain, rootKey, leaf, _) = tree()
        let trust = SpawnTrust(trustedRoot: rootKey)
        let scope = await trust.classify(presentedChain: chain, peer: leaf)
        XCTAssertEqual(scope, ["Nexus", "a", "b"])
        let isTrusted = await trust.isTrusted(leaf)
        XCTAssertTrue(isTrusted)
        let recorded = await trust.verifiedScope(for: leaf)
        XCTAssertEqual(recorded, ["Nexus", "a", "b"])
    }

    func testWrongRootIsFederated() async {
        let (chain, _, leaf, _) = tree()
        let trust = SpawnTrust(trustedRoot: keyPair(0x09).publicKey) // not the real root
        let scope = await trust.classify(presentedChain: chain, peer: leaf)
        XCTAssertNil(scope)
        let isTrusted = await trust.isTrusted(leaf)
        XCTAssertFalse(isTrusted)
    }

    func testStolenChainWrongLeafIsFederated() async {
        let (chain, rootKey, _, _) = tree()
        let trust = SpawnTrust(trustedRoot: rootKey)
        // A valid chain ending in b, presented by a connection that authenticated
        // as a DIFFERENT key — the leaf-binding must reject it.
        let imposter = PeerID(publicKey: keyPair(0x42).publicKey)
        let scope = await trust.classify(presentedChain: chain, peer: imposter)
        XCTAssertNil(scope)
    }

    func testEmptyChainIsFederated() async {
        let (_, rootKey, leaf, _) = tree()
        let trust = SpawnTrust(trustedRoot: rootKey)
        let scope = await trust.classify(presentedChain: [], peer: leaf)
        XCTAssertNil(scope)
    }

    func testNilTrustedRootIsAlwaysFederated() async {
        let (chain, _, leaf, _) = tree()
        let trust = SpawnTrust(trustedRoot: nil)
        let scope = await trust.classify(presentedChain: chain, peer: leaf)
        XCTAssertNil(scope)
        let has = await trust.hasTrustedRoot
        XCTAssertFalse(has)
    }

    func testScopeEnforcement() async {
        let (chain, rootKey, leaf, _) = tree()
        let trust = SpawnTrust(trustedRoot: rootKey)
        _ = await trust.classify(presentedChain: chain, peer: leaf)
        // leaf's scope is exactly Nexus/a/b.
        let exact = await trust.isTrusted(leaf, forChainPath: ["Nexus", "a", "b"])
        XCTAssertTrue(exact, "trusted for its own scope")
        let descendant = await trust.isTrusted(leaf, forChainPath: ["Nexus", "a", "b", "c"])
        XCTAssertTrue(descendant, "trusted for descendants of its scope")
        let sibling = await trust.isTrusted(leaf, forChainPath: ["Nexus", "a", "z"])
        XCTAssertFalse(sibling, "NOT trusted for a sibling subtree")
        let ancestor = await trust.isTrusted(leaf, forChainPath: ["Nexus", "a"])
        XCTAssertFalse(ancestor, "NOT trusted to speak for a shallower ancestor path")
        let otherTree = await trust.isTrusted(leaf, forChainPath: ["Nexus", "beta"])
        XCTAssertFalse(otherTree)
    }

    func testMayServeConsensusToAncestorsOnly() async {
        let (chain, rootKey, leaf, _) = tree()  // leaf scope = Nexus/a/b
        let trust = SpawnTrust(trustedRoot: rootKey)
        _ = await trust.classify(presentedChain: chain, peer: leaf)
        // A descendant may query its ancestors' (and own) weight...
        let root = await trust.mayServeConsensus(to: leaf, forChainPath: ["Nexus"])
        XCTAssertTrue(root, "may query the root ancestor")
        let mid = await trust.mayServeConsensus(to: leaf, forChainPath: ["Nexus", "a"])
        XCTAssertTrue(mid, "may query an intermediate ancestor")
        let own = await trust.mayServeConsensus(to: leaf, forChainPath: ["Nexus", "a", "b"])
        XCTAssertTrue(own, "may query its own chain")
        // ...but not a descendant, a sibling, or another tree.
        let descendant = await trust.mayServeConsensus(to: leaf, forChainPath: ["Nexus", "a", "b", "c"])
        XCTAssertFalse(descendant, "may NOT query a descendant chain")
        let sibling = await trust.mayServeConsensus(to: leaf, forChainPath: ["Nexus", "beta"])
        XCTAssertFalse(sibling, "may NOT query a sibling subtree")
        let imposter = PeerID(publicKey: keyPair(0x55).publicKey)
        let untrusted = await trust.mayServeConsensus(to: imposter, forChainPath: ["Nexus"])
        XCTAssertFalse(untrusted, "an untrusted peer may query nothing")
    }

    func testForgetClearsTrust() async {
        let (chain, rootKey, leaf, _) = tree()
        let trust = SpawnTrust(trustedRoot: rootKey)
        _ = await trust.classify(presentedChain: chain, peer: leaf)
        await trust.forget(leaf)
        let isTrusted = await trust.isTrusted(leaf)
        XCTAssertFalse(isTrusted)
    }

    func testChainSurvivesBase64JsonRoundTrip() async {
        // The contract the --spawn-cert-chain CLI flag decodes and 2b-ii issuance
        // must produce: base64(JSON([SpawnCertificate])). A round-trip must preserve
        // the chain well enough to still classify trusted.
        let (chain, rootKey, leaf, _) = tree()
        let encoded = try! JSONEncoder().encode(chain).base64EncodedString()
        let decoded = try! JSONDecoder().decode([SpawnCertificate].self, from: Data(base64Encoded: encoded)!)
        XCTAssertEqual(decoded, chain)
        let trust = SpawnTrust(trustedRoot: rootKey)
        let scope = await trust.classify(presentedChain: decoded, peer: leaf)
        XCTAssertEqual(scope, ["Nexus", "a", "b"])
    }

    func testReclassifyWithBadChainClearsPreviousTrust() async {
        let (chain, rootKey, leaf, _) = tree()
        let trust = SpawnTrust(trustedRoot: rootKey)
        _ = await trust.classify(presentedChain: chain, peer: leaf)
        // A later presentation that fails verification must DROP the prior trust
        // (fail closed), not leave the stale scope in place.
        _ = await trust.classify(presentedChain: [], peer: leaf)
        let isTrusted = await trust.isTrusted(leaf)
        XCTAssertFalse(isTrusted)
    }
}
