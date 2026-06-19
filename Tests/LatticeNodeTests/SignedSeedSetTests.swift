import XCTest
@testable import Lattice
@testable import LatticeNode
@testable import Ivy

final class SignedSeedSetTests: XCTestCase {

    func testValidSignedSetRoundTrips() async throws {
        let trusted = CryptoUtils.generateKeyPair()
        let peers = [
            peer("ed011111111111111111111111111111111111111111111111111111111111111111", "10.10.0.1", 4001),
            peer("ed012222222222222222222222222222222222222222222222222222222222222222", "10.20.0.1", 4001),
            peer("ed011111111111111111111111111111111111111111111111111111111111111111", "10.10.0.1", 4001),
        ]
        let record = try XCTUnwrap(DNSSeeds.encodeSignedSeedSet(peers: peers, signer: trusted))

        let resolved = DNSSeeds.parseSignedSeedSet(record, trustedPublicKeys: [trusted.publicKey])

        XCTAssertEqual(
            Set(resolved.map(DNSSeeds.encodePeerRecord)),
            Set(peers.prefix(2).map(DNSSeeds.encodePeerRecord))
        )
    }

    func testTamperedSeedRecordRejected() async throws {
        let trusted = CryptoUtils.generateKeyPair()
        let original = peer("ed013333333333333333333333333333333333333333333333333333333333333333", "10.0.0.1", 4001)
        let record = try XCTUnwrap(DNSSeeds.encodeSignedSeedSet(peers: [original], signer: trusted))
        let tampered = try tamperPayload(in: record) { payload in
            payload.replacingOccurrences(of: "10.0.0.1", with: "10.0.0.2")
        }

        let resolved = DNSSeeds.parseSignedSeedSet(tampered, trustedPublicKeys: [trusted.publicKey])

        XCTAssertTrue(resolved.isEmpty, "Tampering with any signed peer field must invalidate the set")
    }

    func testUntrustedSignerRejected() async throws {
        let trusted = CryptoUtils.generateKeyPair()
        let evil = CryptoUtils.generateKeyPair()
        let endpoint = peer("ed014444444444444444444444444444444444444444444444444444444444444444", "10.0.0.1", 4001)
        let record = try XCTUnwrap(DNSSeeds.encodeSignedSeedSet(peers: [endpoint], signer: evil))

        let resolved = DNSSeeds.parseSignedSeedSet(record, trustedPublicKeys: [trusted.publicKey])

        XCTAssertTrue(resolved.isEmpty, "Seed sets signed by unpinned keys must be refused")
    }

    func testCompromisedPrimaryStillBootstrapsFromTwoOperatorDiverseSeeds() async throws {
        let primary = CryptoUtils.generateKeyPair()
        let operatorA = CryptoUtils.generateKeyPair()
        let operatorB = CryptoUtils.generateKeyPair()
        let sources = [
            DNSSeedSource(hostname: "primary.example", operatorID: "primary", trustedPublicKeys: [primary.publicKey]),
            DNSSeedSource(hostname: "operator-a.example", operatorID: "operator-a", trustedPublicKeys: [operatorA.publicKey]),
            DNSSeedSource(hostname: "operator-b.example", operatorID: "operator-b", trustedPublicKeys: [operatorB.publicKey]),
        ]
        let primaryAttack = try XCTUnwrap(DNSSeeds.encodeSignedSeedSet(
            peers: [peer("ed01aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "203.0.113.10", 4001)],
            signer: CryptoUtils.generateKeyPair()
        ))
        let goodA = try XCTUnwrap(DNSSeeds.encodeSignedSeedSet(
            peers: [peer("ed015555555555555555555555555555555555555555555555555555555555555555", "10.10.0.1", 4001)],
            signer: operatorA
        ))
        let goodB = try XCTUnwrap(DNSSeeds.encodeSignedSeedSet(
            peers: [peer("ed016666666666666666666666666666666666666666666666666666666666666666", "10.20.0.1", 4001)],
            signer: operatorB
        ))

        let resolved = await DNSSeeds.resolveSources(sources, minimumOperators: 2) { hostname in
            switch hostname {
            case "primary.example": return [primaryAttack]
            case "operator-a.example": return [goodA]
            case "operator-b.example": return [goodB]
            default: return []
            }
        }

        XCTAssertEqual(resolved.map(DNSSeeds.encodePeerRecord).sorted(), [
            "ed015555555555555555555555555555555555555555555555555555555555555555@10.10.0.1:4001",
            "ed016666666666666666666666666666666666666666666666666666666666666666@10.20.0.1:4001",
        ])
    }

    func testSingleSignedOperatorFailsClosedWhenDiversityRequired() async throws {
        let trusted = CryptoUtils.generateKeyPair()
        let source = DNSSeedSource(hostname: "solo.example", operatorID: "solo", trustedPublicKeys: [trusted.publicKey])
        let record = try XCTUnwrap(DNSSeeds.encodeSignedSeedSet(
            peers: [peer("ed017777777777777777777777777777777777777777777777777777777777777777", "10.30.0.1", 4001)],
            signer: trusted
        ))

        let resolved = await DNSSeeds.resolveSources([source], minimumOperators: 2) { _ in [record] }

        XCTAssertTrue(resolved.isEmpty, "Mainnet bootstrap must not trust a single signed seed operator")
    }

    func testUnpinnedSeedSourceFailsClosedWithoutQueryingDNS() async throws {
        let source = DNSSeedSource(hostname: "unpinned.example", operatorID: "unpinned", trustedPublicKeys: [])
        let probe = ResolverProbe()

        let resolved = await DNSSeeds.resolveSources([source], minimumOperators: 1) { _ in
            await probe.markCalled()
            return ["unsigned-peer@203.0.113.1:4001"]
        }

        let resolverWasCalled = await probe.wasCalled()
        XCTAssertFalse(resolverWasCalled, "Launch-blocked sources without pinned keys must not query DNS")
        XCTAssertTrue(resolved.isEmpty)
    }

    func testTestnetDNSBootstrapIsExplicitlyHardcodedOnlyUntilKeysArePinned() async throws {
        XCTAssertFalse(DNSSeeds.isTestnetBootstrapConfigured)
        XCTAssertTrue(DNSSeeds.testnetSources.isEmpty)
        XCTAssertTrue(DNSSeeds.testnetHostnames.isEmpty)
        XCTAssertFalse(BootstrapPeers.testnet.isEmpty)  // testnet ships hardcoded seeds until DNS signed-seed-sets are pinned
        let resolved = await DNSSeeds.resolveTestnet()
        XCTAssertTrue(resolved.isEmpty)
    }

    private func peer(_ publicKey: String, _ host: String, _ port: UInt16) -> PeerEndpoint {
        PeerEndpoint(publicKey: publicKey, host: host, port: port)
    }

    private func tamperPayload(in record: String, mutate: (String) -> String) throws -> String {
        var parts = record.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(parts.count, 5)
        let payload = try XCTUnwrap(String(data: try XCTUnwrap(DNSSeeds.base64URLDecode(parts[4])), encoding: .utf8))
        parts[4] = DNSSeeds.base64URLEncode(Data(mutate(payload).utf8))
        return parts.joined(separator: ":")
    }

    private actor ResolverProbe {
        private var called = false

        func wasCalled() -> Bool {
            called
        }

        func markCalled() {
            called = true
        }
    }
}
