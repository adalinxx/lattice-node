import XCTest
import ArgumentParser
@testable import LatticeNode

/// the faucet was Sybil-drainable — bound to 0.0.0.0, the only abuse
/// control was a per-(requester-supplied)-address cooldown, address validation
/// was `hasPrefix("bafyrei")`, the PoW challenge was requester-chosen (so one
/// offline solution could be replayed), and the spending key was accepted on
/// argv.
///
/// These tests drive the real `FaucetManager` actor (and `FaucetCommand`
/// parsing) through an injected submitter seam so the node POST is stubbed.
/// PoW is gated on a *faucet-issued* challenge, so the tests obtain a real
/// server-issued token via `issueChallenge(for:)` and solve THAT — a test that
/// mints its own challenge would pass even if provenance were not enforced.
final class FaucetCommandTests: XCTestCase {

    /// Low difficulty so the test-side PoW solve is instant while still
    /// exercising the real verifier (the production default is 20 bits).
    private let testDifficulty: UInt8 = 4

    /// Counts submissions and always returns HTTP 200 so a permitted drip
    /// reaches `.dripped` without touching the network.
    actor SubmitCounter {
        private(set) var count = 0
        nonisolated var submitter: NodeSubmitter {
            { _ in
                await self.bump()
                return (Data("{}".utf8), 200)
            }
        }
        private func bump() { count += 1 }
    }

    private func makeManager(
        counter: SubmitCounter,
        cooldown: UInt64 = 86_400,
        ipCooldown: UInt64 = 86_400
    ) -> FaucetManager {
        FaucetManager(
            wallet: .create(),
            nodeURL: "http://localhost:9",
            amount: 1,
            cooldown: cooldown,
            chain: "Nexus",
            ipCooldown: ipCooldown,
            powDifficultyBits: testDifficulty,
            submit: counter.submitter
        )
    }

    /// Obtain a real server-issued challenge and solve it at the test
    /// difficulty. Drives the faucet's own challenge-issuing entry point so the
    /// solution carries genuine faucet provenance.
    private func issuedPoW(for address: String, manager: FaucetManager) async -> FaucetPoWSolution {
        let issued = await manager.issueChallenge(for: address)!
        let nonce = FaucetPoW.solve(address: address, challenge: issued.challenge.token, difficultyBits: testDifficulty)
        return FaucetPoWSolution(challenge: issued.challenge.token, nonce: nonce)
    }

    func test_drip_rejectsInvalidAddress() async {
        let counter = SubmitCounter()
        let manager = makeManager(counter: counter)
        // A single-character tamper of a real address (uppercased one char) is
        // not a canonical Lattice address CID and must be rejected before any
        // submission. `hasPrefix("bafyrei")` alone would have accepted it.
        let w = Wallet.create()
        let valid = w.address
        var chars = Array(valid)
        let i = chars.indices.dropFirst("bafyrei".count).first { chars[$0].isLowercase }!
        chars[i] = Character(String(chars[i]).uppercased())
        let tampered = String(chars)
        XCTAssertNotEqual(tampered, valid, "tamper must change the string")

        // No challenge is even minted for a tampered address.
        let noChallenge = await manager.issueChallenge(for: tampered)
        XCTAssertNil(noChallenge, "no challenge may be issued for an invalid address")

        // And drip fails closed for the tampered address (with the real key).
        let solution = FaucetPoWSolution(challenge: "x", nonce: 0)
        let result = await manager.drip(to: tampered, publicKey: w.publicKeyHex, powSolution: solution)
        guard case .failed = result else {
            return XCTFail("expected .failed for tampered address, got \(result)")
        }
        let c1 = await counter.count; XCTAssertEqual(c1, 0, "no submission may be attempted for an invalid address")

        // Prefix-only garbage (the old gate) is also rejected.
        let prefixOnly = await manager.drip(to: "bafyreiNOTAREALCID", publicKey: w.publicKeyHex, powSolution: solution)
        guard case .failed = prefixOnly else {
            return XCTFail("expected .failed for prefix-only string, got \(prefixOnly)")
        }
        let c2 = await counter.count; XCTAssertEqual(c2, 0)
    }

    /// Address validation must bind the address to its PublicKey: a valid CID
    /// for a different key (a structurally-perfect address that is NOT the CID
    /// of the supplied public key) is rejected.
    func test_drip_rejectsAddressNotMatchingPublicKey() async {
        let counter = SubmitCounter()
        let manager = makeManager(counter: counter)
        let a = Wallet.create()  // structurally valid, real address
        let b = Wallet.create()  // a different, unrelated public key
        let solution = await issuedPoW(for: a.address, manager: manager)
        // Address belongs to a, but we present b's public key → mismatch.
        let result = await manager.drip(to: a.address, publicKey: b.publicKeyHex, powSolution: solution)
        guard case .failed = result else {
            return XCTFail("expected .failed when address does not match public key, got \(result)")
        }
        let c = await counter.count; XCTAssertEqual(c, 0)
    }

    func test_drip_acceptsValidAddress() async {
        let counter = SubmitCounter()
        let manager = makeManager(counter: counter)
        let w = Wallet.create()
        let solution = await issuedPoW(for: w.address, manager: manager)
        let result = await manager.drip(to: w.address, publicKey: w.publicKeyHex, powSolution: solution)
        guard case .dripped = result else {
            return XCTFail("expected .dripped for a valid address, got \(result)")
        }
        let c = await counter.count; XCTAssertEqual(c, 1)
    }

    func test_drip_requiresValidPoW() async {
        let counter = SubmitCounter()
        let manager = makeManager(counter: counter)
        let w = Wallet.create()

        // Missing PoW → powRequired, no submission.
        let missing = await manager.drip(to: w.address, publicKey: w.publicKeyHex, powSolution: nil)
        guard case .powRequired = missing else {
            return XCTFail("expected .powRequired with no PoW, got \(missing)")
        }

        // Invalid PoW against a real issued challenge (a nonce we verify does
        // not clear the target) → powRequired.
        let issued = await manager.issueChallenge(for: w.address)!
        let badNonce = await invalidNonce(for: w.address, challenge: issued.challenge.token)
        let invalid = await manager.drip(
            to: w.address,
            publicKey: w.publicKeyHex,
            powSolution: FaucetPoWSolution(challenge: issued.challenge.token, nonce: badNonce)
        )
        guard case .powRequired = invalid else {
            return XCTFail("expected .powRequired with invalid PoW, got \(invalid)")
        }

        let c = await counter.count; XCTAssertEqual(c, 0, "no submission for missing/invalid PoW")
    }

    /// SYBIL GATE provenance: a perfectly valid PoW solution whose challenge was
    /// NOT issued by this faucet must be rejected with the distinct
    /// `.invalidChallenge` result and zero submissions. This is the test that
    /// is RED before challenge provenance is enforced.
    func test_drip_rejectsUnissuedChallenge() async {
        let counter = SubmitCounter()
        let manager = makeManager(counter: counter)
        let w = Wallet.create()
        // A challenge the requester picked itself (never issued by the faucet),
        // solved correctly.
        let selfChosen = "attacker-chosen-challenge"
        let nonce = FaucetPoW.solve(address: w.address, challenge: selfChosen, difficultyBits: testDifficulty)
        XCTAssertTrue(FaucetPoW.isValid(address: w.address, challenge: selfChosen, nonce: nonce, difficultyBits: testDifficulty))
        let result = await manager.drip(
            to: w.address,
            publicKey: w.publicKeyHex,
            powSolution: FaucetPoWSolution(challenge: selfChosen, nonce: nonce)
        )
        guard case .invalidChallenge = result else {
            return XCTFail("expected .invalidChallenge for a non-faucet-issued challenge, got \(result)")
        }
        let c = await counter.count; XCTAssertEqual(c, 0, "no submission for an unissued challenge")
    }

    /// A challenge is single-use: after a successful drip its token can't be
    /// replayed.
    func test_challenge_singleUse() async {
        let counter = SubmitCounter()
        let manager = makeManager(counter: counter)
        let w = Wallet.create()
        let solution = await issuedPoW(for: w.address, manager: manager)
        let first = await manager.drip(to: w.address, publicKey: w.publicKeyHex, powSolution: solution)
        guard case .dripped = first else { return XCTFail("first should drip, got \(first)") }
        // Replay the same token (cooldown would also fire, but provenance is
        // consumed first): must not be honoured as a fresh challenge.
        let replay = await manager.drip(to: w.address, publicKey: w.publicKeyHex, powSolution: solution)
        switch replay {
        case .invalidChallenge, .cooldown:
            break  // either fail-closed result is acceptable; never .dripped
        default:
            XCTFail("replayed single-use challenge must not drip again, got \(replay)")
        }
    }

    /// Find a nonce that is NOT a valid solution at the test difficulty.
    private func invalidNonce(for address: String, challenge: String) async -> UInt64 {
        var nonce: UInt64 = 0
        while FaucetPoW.isValid(address: address, challenge: challenge, nonce: nonce, difficultyBits: testDifficulty) {
            nonce &+= 1
        }
        return nonce
    }

    func test_perAddressCooldown_stillEnforced() async {
        let counter = SubmitCounter()
        let manager = makeManager(counter: counter)
        let w = Wallet.create()
        let first = await manager.drip(to: w.address, publicKey: w.publicKeyHex, powSolution: await issuedPoW(for: w.address, manager: manager))
        guard case .dripped = first else { return XCTFail("first should drip, got \(first)") }
        // Second drip to the same address within the 24h window → cooldown.
        let second = await manager.drip(to: w.address, publicKey: w.publicKeyHex, powSolution: await issuedPoW(for: w.address, manager: manager))
        guard case .cooldown = second else {
            return XCTFail("second drip to same address should be .cooldown, got \(second)")
        }
    }

    /// A submitter that parks the FIRST drip mid-`submit` until released, so a
    /// second concurrent drip can run while the first is still inside its await
    /// window. Returns HTTP 200 (a landed drip) for every call it does serve.
    actor GatedSubmitter {
        private(set) var count = 0
        private var release: CheckedContinuation<Void, Never>?
        private var firstArrived: CheckedContinuation<Void, Never>?
        private var sawFirst = false

        nonisolated var submitter: NodeSubmitter {
            { _ in await self.serve() }
        }

        private func serve() async -> (Data, Int)? {
            count += 1
            if count == 1 {
                // Signal that the first drip has entered its await window, then
                // park here until the test releases us.
                firstArrived?.resume(); firstArrived = nil; sawFirst = true
                await withCheckedContinuation { self.release = $0 }
            }
            return (Data("{}".utf8), 200)
        }

        /// Suspend until the first drip is parked inside `submit`.
        func awaitFirstParked() async {
            if sawFirst { return }
            await withCheckedContinuation { firstArrived = $0 }
        }

        func releaseFirst() { release?.resume(); release = nil }
    }

    /// RACE: two concurrent drips for the SAME address. The cooldown timestamp
    /// is only written after the node submit, so an actor `await` lets the second
    /// drip clear the cooldown check before the first records anything. Without
    /// the in-flight reservation BOTH would submit, draining 2x. The reservation
    /// must let exactly one land and reject the other as `.cooldown`.
    func test_concurrentSameAddress_onlyOneDrips() async {
        let gated = GatedSubmitter()
        let manager = FaucetManager(
            wallet: .create(), nodeURL: "http://localhost:9", amount: 1,
            cooldown: 86_400, chain: "Nexus", ipCooldown: 86_400,
            powDifficultyBits: testDifficulty, submit: gated.submitter
        )
        let w = Wallet.create()
        let s1 = await issuedPoW(for: w.address, manager: manager)
        let s2 = await issuedPoW(for: w.address, manager: manager)

        async let first = manager.drip(to: w.address, publicKey: w.publicKeyHex, powSolution: s1)
        // Wait until drip #1 is parked inside submit (reservation held), then
        // fire drip #2: it must collide with the reservation, not the (still
        // unwritten) cooldown timestamp.
        await gated.awaitFirstParked()
        let second = await manager.drip(to: w.address, publicKey: w.publicKeyHex, powSolution: s2)
        await gated.releaseFirst()
        let firstResult = await first

        guard case .dripped = firstResult else {
            return XCTFail("first concurrent drip should land, got \(firstResult)")
        }
        guard case .cooldown = second else {
            return XCTFail("second concurrent same-address drip must be rejected, got \(second)")
        }
        let c = await gated.count
        XCTAssertEqual(c, 1, "exactly one submission may reach the node")
    }

    /// RACE on the per-IP throttle: two concurrent drips for DIFFERENT valid
    /// addresses from the same peer IP. Only one may land; the other must be
    /// rejected as `.tooManyRequests` rather than slipping through the await gap.
    func test_concurrentSameIP_onlyOneDrips() async {
        let gated = GatedSubmitter()
        let manager = FaucetManager(
            wallet: .create(), nodeURL: "http://localhost:9", amount: 1,
            cooldown: 86_400, chain: "Nexus", ipCooldown: 86_400,
            powDifficultyBits: testDifficulty, submit: gated.submitter
        )
        let ip = "198.51.100.9"
        let a = Wallet.create()
        let b = Wallet.create()
        let sa = await issuedPoW(for: a.address, manager: manager)
        let sb = await issuedPoW(for: b.address, manager: manager)

        async let first = manager.drip(to: a.address, publicKey: a.publicKeyHex, clientIP: ip, powSolution: sa)
        await gated.awaitFirstParked()
        let second = await manager.drip(to: b.address, publicKey: b.publicKeyHex, clientIP: ip, powSolution: sb)
        await gated.releaseFirst()
        let firstResult = await first

        guard case .dripped = firstResult else {
            return XCTFail("first concurrent drip should land, got \(firstResult)")
        }
        guard case .tooManyRequests = second else {
            return XCTFail("second concurrent same-IP drip must be rate limited, got \(second)")
        }
        let c = await gated.count
        XCTAssertEqual(c, 1, "exactly one submission may reach the node")
    }

    func test_perIP_cooldown() async {
        let counter = SubmitCounter()
        let manager = makeManager(counter: counter)
        let ip = "203.0.113.7"
        let a = Wallet.create()
        let first = await manager.drip(to: a.address, publicKey: a.publicKeyHex, clientIP: ip, powSolution: await issuedPoW(for: a.address, manager: manager))
        guard case .dripped = first else { return XCTFail("first should drip, got \(first)") }
        // Different valid address, same IP, inside the 24h IP window → throttled.
        let b = Wallet.create()
        let second = await manager.drip(to: b.address, publicKey: b.publicKeyHex, clientIP: ip, powSolution: await issuedPoW(for: b.address, manager: manager))
        guard case .tooManyRequests = second else {
            return XCTFail("second drip from same IP should be .tooManyRequests, got \(second)")
        }
    }

    func test_bind_defaultsToLoopback() throws {
        let def = try FaucetCommand.parse([])
        XCTAssertEqual(def.bind, "127.0.0.1")
        let exposed = try FaucetCommand.parse(["--bind", "0.0.0.0"])
        XCTAssertEqual(exposed.bind, "0.0.0.0")
    }

    func test_dripAmount_defaultsToInitialReward() throws {
        let def = try FaucetCommand.parse([])
        XCTAssertEqual(def.amount, NexusGenesis.spec.initialReward)
        XCTAssertEqual(def.amount, 1_048_576)
    }

    /// DRIP AMOUNT is fixed to the chain's initial reward and must NOT be
    /// operator-overridable: `--amount` is not a parseable flag, so an operator
    /// cannot make the faucet disburse an arbitrary value per request.
    func test_dripAmount_notOverridableViaArgv() {
        XCTAssertThrowsError(
            try FaucetCommand.parse(["--amount", "9999999"]),
            "the drip amount must not be overridable on argv"
        )
    }

    func test_faucetKey_argvRejected() throws {
        // Key only via --faucet-key argv → hard-fail.
        XCTAssertThrowsError(
            try FaucetCommand.resolveKeyHex(faucetKey: "deadbeef", faucetKeyFile: nil, env: [:])
        )
        // Key via env → accepted.
        let viaEnv = try FaucetCommand.resolveKeyHex(
            faucetKey: nil, faucetKeyFile: nil, env: ["LATTICE_FAUCET_KEY": "deadbeef"]
        )
        XCTAssertEqual(viaEnv, "deadbeef")

        // Key via a 0600 file → accepted.
        let dir = FileManager.default.temporaryDirectory
        let file = dir.appendingPathComponent("faucet-key-\(UUID().uuidString).hex")
        try "deadbeef".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: file.path)
        defer { try? FileManager.default.removeItem(at: file) }
        let viaFile = try FaucetCommand.resolveKeyHex(faucetKey: nil, faucetKeyFile: file.path, env: [:])
        XCTAssertEqual(viaFile, "deadbeef")

        // A group/other-readable key file (0644) → rejected.
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: file.path)
        XCTAssertThrowsError(
            try FaucetCommand.resolveKeyHex(faucetKey: nil, faucetKeyFile: file.path, env: [:]),
            "a non-0600 key file must be rejected"
        )
    }
}
