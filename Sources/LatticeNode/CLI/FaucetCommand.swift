import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Lattice
import Hummingbird
import NIOCore

struct FaucetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "faucet",
        abstract: "Run a testnet faucet that drips tokens to requesting addresses"
    )

    /// REJECTED: the spending key must never be passed on argv — it leaks via
    /// `ps` / `/proc/<pid>/cmdline` / shell history. Accept only the
    /// `LATTICE_FAUCET_KEY` env var or `--faucet-key-file`. Kept as a parseable
    /// option solely so we can hard-fail with a clear message instead of an
    /// opaque "unknown flag".
    @Option(help: "REJECTED: do not pass the spending key on argv. Use LATTICE_FAUCET_KEY env or --faucet-key-file.")
    var faucetKey: String?

    @Option(help: "Path to a file (0600) containing the faucet private key hex")
    var faucetKeyFile: String?

    @Option(help: "Host address to bind the faucet server to (default 127.0.0.1; use 0.0.0.0 to expose publicly)")
    var bind: String = "127.0.0.1"

    @Option(help: "Testnet node RPC URL to submit transactions through")
    var nodeURL: String = "http://localhost:8080"

    @Option(help: "HTTP port for the faucet server")
    var port: UInt16 = 8090

    /// DRIP AMOUNT is fixed to the chain's initial block reward and is NOT an
    /// operator-tunable flag: a configurable `--amount` would let the faucet
    /// disburse an arbitrary value per request, diverging from the
    /// `drip = initialReward` invariant (1_048_576 on Nexus). Derived from the
    /// chain spec so it tracks the spec rather than a hardcoded literal.
    var amount: UInt64 { NexusGenesis.spec.initialReward }

    @Option(help: "Per-address cooldown in seconds before the same address can request again")
    var cooldown: UInt64 = 86_400

    @Option(help: "Per-client-IP cooldown in seconds")
    var ipCooldown: UInt64 = 86_400

    @Option(help: "PoW Sybil-gate difficulty in leading-zero bits")
    var powDifficultyBits: UInt8 = FaucetPoW.defaultDifficultyBits

    @Option(help: "Chain path to drip on")
    var chainPath: String = "Nexus"

    /// Resolve the faucet key from the allowed (non-argv) sources, hard-failing
    /// if it is supplied via `--faucet-key`. Returns the key hex.
    ///
    /// A `--faucet-key-file` must be `0600` (owner read/write only). A key file
    /// that is group/other-readable is rejected: the secret would be exposed to
    /// any local user, defeating the point of moving it off argv.
    static func resolveKeyHex(
        faucetKey: String?,
        faucetKeyFile: String?,
        env: [String: String]
    ) throws -> String {
        if faucetKey != nil {
            throw ValidationError(
                "Refusing to read the faucet spending key from --faucet-key (argv is visible via ps/proc). Set LATTICE_FAUCET_KEY or use --faucet-key-file."
            )
        }
        if let file = faucetKeyFile {
            try enforceKeyFilePermissions(file)
            let contents = try String(contentsOfFile: file, encoding: .utf8)
            return contents.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let envKey = env["LATTICE_FAUCET_KEY"], !envKey.isEmpty {
            return envKey
        }
        throw ValidationError("Provide the faucet key via LATTICE_FAUCET_KEY env or --faucet-key-file")
    }

    /// Fail closed unless the key file is exactly `0600`.
    static func enforceKeyFilePermissions(_ path: String) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        guard let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value else {
            throw ValidationError("Cannot read permissions of faucet key file \(path)")
        }
        let mode = perms & 0o777
        guard mode == 0o600 else {
            throw ValidationError(
                "Faucet key file \(path) has permissions \(String(mode, radix: 8)); require 0600 (chmod 600 \(path))."
            )
        }
    }

    func run() async throws {
        let keyHex = try Self.resolveKeyHex(
            faucetKey: faucetKey,
            faucetKeyFile: faucetKeyFile,
            env: ProcessInfo.processInfo.environment
        )
        guard let wallet = Wallet.fromPrivateKey(keyHex) else {
            printError("Invalid faucet private key")
            throw ExitCode.failure
        }

        printLogo()
        printHeader("Lattice Testnet Faucet")
        printKeyValue("Address", wallet.address)
        printKeyValue("Node URL", nodeURL)
        printKeyValue("Bind", bind)
        printKeyValue("Port", "\(port)")
        printKeyValue("Drip amount", "\(amount) tokens")
        printKeyValue("Cooldown", "\(cooldown)s per address")
        printKeyValue("Per-IP cooldown", "\(ipCooldown)s")
        printKeyValue("PoW difficulty", "\(powDifficultyBits) bits")
        printKeyValue("Chain path", chainPath)

        let manager = FaucetManager(
            wallet: wallet,
            nodeURL: nodeURL,
            amount: amount,
            cooldown: cooldown,
            chain: chainPath,
            ipCooldown: ipCooldown,
            powDifficultyBits: powDifficultyBits
        )

        if let balance = await manager.fetchBalance() {
            printKeyValue("Faucet balance", "\(balance) tokens")
        }
        printSuccess("Faucet ready at http://\(bind):\(port)/faucet")

        let faucetManager = manager
        let router = Router(context: FaucetRequestContext.self)

        // Server-issued challenge: the requester first asks the faucet for a
        // challenge bound to its address, then solves the PoW against THAT
        // token. The drip path only honours tokens minted here.
        router.post("faucet/challenge") { request, context -> Response in
            struct Req: Decodable { let address: String }
            guard let req = try? await JSONDecoder().decode(Req.self, from: Data(buffer: request.body.collect(upTo: 65536))) else {
                return faucetResponse(error: "missing or invalid body: {\"address\":\"...\"}", status: .badRequest)
            }
            guard let issued = await faucetManager.issueChallenge(for: req.address) else {
                return faucetResponse(error: "invalid address: not a valid Lattice address CID", status: .badRequest)
            }
            struct ChallengeResponse: Encodable { let challenge: String; let difficultyBits: UInt8; let address: String }
            return faucetResponse(
                encodable: ChallengeResponse(challenge: issued.challenge.token, difficultyBits: issued.difficultyBits, address: req.address),
                status: .ok
            )
        }

        router.post("faucet") { request, context -> Response in
            struct Req: Decodable { let address: String; let publicKey: String; let challenge: String?; let nonce: UInt64? }
            guard let req = try? await JSONDecoder().decode(Req.self, from: Data(buffer: request.body.collect(upTo: 65536))) else {
                return faucetResponse(error: "missing or invalid body: {\"address\":\"...\",\"publicKey\":\"...\",\"challenge\":\"...\",\"nonce\":N}",  status: .badRequest)
            }
            let clientIP = context.remoteAddress?.ipAddress
            let solution: FaucetPoWSolution?
            if let challenge = req.challenge, let nonce = req.nonce {
                solution = FaucetPoWSolution(challenge: challenge, nonce: nonce)
            } else {
                solution = nil
            }
            let result = await faucetManager.drip(to: req.address, publicKey: req.publicKey, clientIP: clientIP, powSolution: solution)
            switch result {
            case .dripped(let txCID):
                struct DripSuccess: Encodable { let txCID: String; let amount: UInt64; let address: String }
                return faucetResponse(encodable: DripSuccess(txCID: txCID, amount: faucetManager.amount, address: req.address), status: .ok)
            case .cooldown(let remaining):
                return faucetResponse(error: "cooldown: \(remaining)s remaining", status: .tooManyRequests)
            case .tooManyRequests(let remaining):
                return faucetResponse(error: "rate limited (per-IP): \(remaining)s remaining", status: .tooManyRequests)
            case .powRequired(let bits):
                return faucetResponse(error: "proof-of-work required: request a challenge at /faucet/challenge, solve the \(bits)-bit PoW bound to the address, and resubmit with {challenge,nonce}", status: .forbidden)
            case .invalidChallenge:
                return faucetResponse(error: "invalid or expired challenge: request a fresh one at /faucet/challenge", status: .forbidden)
            case .failed(let msg):
                return faucetResponse(error: msg, status: .badRequest)
            }
        }

        router.get("health") { _, _ in
            struct Health: Encodable { let status: String }
            return faucetResponse(encodable: Health(status: "ok"), status: .ok)
        }

        let app = Application(
            router: router,
            configuration: .init(address: .hostname(bind, port: Int(port)))
        )

        let keepAlive = AsyncStream<Void> { continuation in
            let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            signal(SIGINT, SIG_IGN)
            src.setEventHandler { continuation.finish() }
            src.resume()
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await app.run() }
            group.addTask { for await _ in keepAlive {} }
            _ = try await group.next()
            group.cancelAll()
        }

        printSuccess("Faucet stopped")
    }
}

/// Request context that exposes the connecting peer's address so the faucet
/// handler can throttle per client IP (derived from the connection, not a
/// request-body field).
struct FaucetRequestContext: RemoteAddressRequestContext {
    var coreContext: CoreRequestContextStorage
    let remoteAddress: SocketAddress?

    init(source: ApplicationRequestContextSource) {
        self.coreContext = .init(source: source)
        self.remoteAddress = source.channel.remoteAddress
    }
}

private func faucetResponse(encodable: some Encodable, status: HTTPResponse.Status) -> Response {
    let data = (try? JSONEncoder().encode(encodable)) ?? Data("{}".utf8)
    return Response(
        status: status,
        headers: HTTPFields([.init(name: .contentType, value: "application/json")]),
        body: .init(byteBuffer: ByteBuffer(data: data))
    )
}

private func faucetResponse(error: String, status: HTTPResponse.Status) -> Response {
    struct E: Encodable { let error: String }
    return faucetResponse(encodable: E(error: error), status: status)
}

enum DripResult: Equatable {
    case dripped(String)
    case cooldown(Int)
    /// Per-client-IP rate limit hit (seconds remaining).
    case tooManyRequests(Int)
    /// Missing or invalid proof-of-work solution (Sybil gate). Carries the
    /// required difficulty in bits so the requester can solve and resubmit.
    case powRequired(UInt8)
    /// The submitted challenge was not issued by this faucet for this address,
    /// or has expired / already been used. Distinct from `.powRequired`: the
    /// PoW may be valid, but its challenge has no faucet provenance — the
    /// requester must request a fresh challenge and resolve.
    case invalidChallenge
    case failed(String)
}

/// Async node submitter seam. Returns `(responseBody, httpStatus)` or `nil` on
/// transport failure. Defaults to a live `URLSession.shared` POST; tests inject
/// a stub so `drip` is exercisable without a network (and reliably on Linux CI,
/// where `URLSession.shared` interception via `URLProtocol` is unreliable).
typealias NodeSubmitter = @Sendable (URLRequest) async -> (Data, Int)?

actor FaucetManager {
    private let wallet: Wallet
    private let nodeURL: String
    let amount: UInt64
    private let cooldown: UInt64
    private let chain: String
    private let ipCooldown: UInt64
    private let powDifficultyBits: UInt8
    private let submit: NodeSubmitter
    private var chainPath: [String] { chain.split(separator: "/").map(String.init) }
    private var nonce: UInt64?
    private var lastDrip: [String: Date] = [:]
    private var lastDripByIP: [String: Date] = [:]
    /// Addresses and peer IPs reserved for an in-flight drip. An actor `await`
    /// (fetchNonce / submit) suspends the running call and lets other queued
    /// drips resume before `lastDrip`/`lastDripByIP` are written — so two
    /// concurrent requests for the same address (or IP) could both clear the
    /// cooldown check and both submit, bypassing the 24h throttle. Reserving the
    /// address and IP *synchronously* (before any suspension point) and
    /// rejecting any call that collides with a live reservation closes that race.
    /// Reservations are released after the await window, converting to a cooldown
    /// timestamp on a landed drip and rolling back on any failure so the slot is
    /// freed for a legitimate retry.
    private var inFlightAddresses: Set<String> = []
    private var inFlightIPs: Set<String> = []
    /// Server-issued, single-use PoW challenges keyed by token. A drip is only
    /// honoured against a challenge this faucet minted for the same address and
    /// that has neither expired nor been consumed. Without this provenance the
    /// PoW gate is defeated: a requester could pick its own challenge, solve it
    /// once offline, and replay the solution across an unbounded request burst.
    private var issuedChallenges: [String: FaucetChallenge] = [:]
    /// How long an issued challenge remains solvable before it must be reissued.
    private let challengeTTL: TimeInterval = 600
    /// Hard cap on tracked addresses. When full, expired entries are evicted
    /// first; if still full after eviction, the request is rejected. Without
    /// this cap any caller can exhaust faucet server memory by submitting
    /// requests from an unlimited number of unique valid addresses.
    private static let maxLastDripEntries = 100_000
    /// Hard cap on outstanding challenges, evicted-then-rejected like drips so a
    /// flood of challenge requests cannot exhaust server memory.
    private static let maxIssuedChallenges = 100_000

    init(
        wallet: Wallet,
        nodeURL: String,
        amount: UInt64,
        cooldown: UInt64,
        chain: String,
        ipCooldown: UInt64 = 86_400,
        powDifficultyBits: UInt8 = FaucetPoW.defaultDifficultyBits,
        submit: @escaping NodeSubmitter = FaucetManager.liveSubmit
    ) {
        self.wallet = wallet
        self.nodeURL = nodeURL
        self.amount = amount
        self.cooldown = cooldown
        self.chain = chain
        self.ipCooldown = ipCooldown
        self.powDifficultyBits = powDifficultyBits
        self.submit = submit
        // Nonce is fetched lazily on first drip — avoids blocking startup on
        // a network call to the testnet node (which may not be ready yet when
        // the faucet and testnet restart simultaneously).
        self.nonce = nil
    }

    static let liveSubmit: NodeSubmitter = { req in
        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }

    func fetchBalance() async -> UInt64? {
        guard let url = URL(string: "\(nodeURL)/api/balance/\(wallet.address)?chainPath=\(chain)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let b = json["balance"] as? UInt64 { return b }
        if let b = json["balance"] as? Int { return UInt64(b) }
        return nil
    }

    private static func fetchNonce(address: String, nodeURL: String, chain: String) async -> UInt64? {
        guard let url = URL(string: "\(nodeURL)/api/nonce/\(address)?chainPath=\(chain)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        if let n = json["nonce"] as? UInt64 { return n }
        if let n = json["nonce"] as? Int { return UInt64(n) }
        return 0
    }

    /// Issue a fresh, single-use PoW challenge bound to `address`. The requester
    /// must solve this exact token and submit `{publicKey, challenge: token,
    /// nonce}`; `drip` only honours tokens minted here. Returns `nil` if the
    /// address is not a structurally-valid Lattice address CID (no challenge is
    /// minted for garbage) or the outstanding-challenge cap is reached.
    func issueChallenge(for address: String, now: Date = Date()) -> (challenge: FaucetChallenge, difficultyBits: UInt8)? {
        guard CryptoUtils.isValidAddress(address) else { return nil }
        // Evict expired challenges when approaching the cap.
        if issuedChallenges.count >= Self.maxIssuedChallenges {
            issuedChallenges = issuedChallenges.filter { $0.value.expiry > now }
            if issuedChallenges.count >= Self.maxIssuedChallenges { return nil }
        }
        let challenge = FaucetChallenge.issue(address: address, ttl: challengeTTL, now: now)
        issuedChallenges[challenge.token] = challenge
        return (challenge, powDifficultyBits)
    }

    func drip(
        to address: String,
        publicKey: String,
        clientIP: String? = nil,
        powSolution: FaucetPoWSolution? = nil
    ) async -> DripResult {
        guard !address.isEmpty else {
            return .failed("invalid address: must not be empty")
        }
        // Fail closed at the trust boundary: the address must be the CID of the
        // supplied PublicKey, round-tripped through the exact construction path
        // Lattice uses (`CryptoUtils.createAddress`). A structurally-valid CID
        // for any non-PublicKey content — or a `hasPrefix("bafyrei")` string —
        // is rejected; without the public-key binding the gate is bypassable.
        guard CryptoUtils.isAddress(address, of: publicKey) else {
            return .failed("invalid address: not the CID of the supplied public key")
        }

        let now = Date()

        // SYBIL GATE (provenance + work). The solution must reference a
        // challenge THIS faucet issued for THIS address, not yet expired and not
        // yet consumed, AND clear the PoW target. Fail closed otherwise. The
        // challenge is consumed (single-use) only on a successful, accepted
        // submission below so a transient node error doesn't burn it.
        guard let solution = powSolution else {
            return .powRequired(powDifficultyBits)
        }
        guard let issued = issuedChallenges[solution.challenge],
              issued.address == address,
              issued.expiry > now
        else {
            // Drop the stale entry if it had expired.
            if let stale = issuedChallenges[solution.challenge], stale.expiry <= now {
                issuedChallenges[solution.challenge] = nil
            }
            return .invalidChallenge
        }
        guard FaucetPoW.isValid(
            address: address,
            challenge: solution.challenge,
            nonce: solution.nonce,
            difficultyBits: powDifficultyBits
        ) else {
            return .powRequired(powDifficultyBits)
        }

        // Per-client-IP throttle (derived from the connection peer).
        if let ip = clientIP, let last = lastDripByIP[ip] {
            let elapsed = now.timeIntervalSince(last)
            if elapsed < Double(ipCooldown) {
                return .tooManyRequests(Int(Double(ipCooldown) - elapsed))
            }
        }

        // Per-address cooldown.
        if let last = lastDrip[address] {
            let elapsed = now.timeIntervalSince(last)
            if elapsed < Double(cooldown) {
                return .cooldown(Int(Double(cooldown) - elapsed))
            }
        }

        // Concurrency throttle: reject (don't queue) any drip that collides with
        // a same-address or same-IP request already past the cooldown check and
        // suspended in its await window. Reported as a cooldown / rate-limit
        // because that's the observable effect — the requester has a request in
        // flight and must wait for the 24h window. Without this an actor `await`
        // would let a concurrent burst slip past the throttle before the first
        // drip records its timestamp.
        if inFlightAddresses.contains(address) {
            return .cooldown(Int(cooldown))
        }
        if let ip = clientIP, inFlightIPs.contains(ip) {
            return .tooManyRequests(Int(ipCooldown))
        }

        // Evict expired entries when approaching the cap so the dict doesn't
        // grow unbounded under a flood of unique addresses.
        if lastDrip.count >= Self.maxLastDripEntries {
            let expiredBefore = now.addingTimeInterval(-Double(cooldown))
            lastDrip = lastDrip.filter { $0.value > expiredBefore }
            if lastDrip.count >= Self.maxLastDripEntries {
                return .failed("Faucet at capacity, try again later")
            }
        }

        // Reserve the address (and IP) for the duration of the await window so a
        // concurrent request collides above. The reservation is released after
        // the awaits: converted to a 24h cooldown on a landed drip, rolled back
        // on any failure so a legitimate retry isn't locked out.
        inFlightAddresses.insert(address)
        if let ip = clientIP { inFlightIPs.insert(ip) }
        var dripLanded = false
        defer {
            inFlightAddresses.remove(address)
            if let ip = clientIP { inFlightIPs.remove(ip) }
            if dripLanded {
                lastDrip[address] = now
                if let ip = clientIP { lastDripByIP[ip] = now }
            }
        }

        if nonce == nil {
            nonce = await Self.fetchNonce(address: wallet.address, nodeURL: nodeURL, chain: chain)
        }
        let txNonce = nonce ?? 0

        // Retry with escalating fee to handle RBF rejections
        var fee: UInt64 = 2
        for _ in 0..<5 {
            guard let tx = wallet.buildTransfer(
                to: address, amount: amount, fee: fee, nonce: txNonce, chainPath: chainPath
            ) else { return .failed("failed to build transaction") }

            guard let bodyData = tx.body.node?.toData() else { return .failed("failed to serialize transaction body") }
            let bodyCID = tx.body.rawCID
            let bodyHex = bodyData.map { String(format: "%02x", $0) }.joined()

            struct Sub: Encodable { let signatures: [String: String]; let bodyCID: String; let bodyData: String; let chainPath: [String] }
            guard let payload = try? JSONEncoder().encode(Sub(signatures: tx.signatures, bodyCID: bodyCID, bodyData: bodyHex, chainPath: chainPath)),
                  let url = URL(string: "\(nodeURL)/api/transaction") else { return .failed("failed to encode submission") }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = payload

            guard let (data, status) = await submit(req) else { return .failed("node unreachable") }
            if status == 200 {
                nonce = txNonce + 1
                dripLanded = true
                // Consume the challenge (single-use) now that the drip landed.
                issuedChallenges[solution.challenge] = nil
                NodeLogger("faucet").info("Dripped \(amount) to \(address) nonce=\(txNonce) fee=\(fee) txCID=\(String(bodyCID.prefix(16)))…")
                return .dripped(bodyCID)
            }
            let errMsg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "submission failed (\(status))"
            // Parse "RBF fee too low: need at least N, got M" and retry with N
            if errMsg.contains("RBF fee too low"),
               let part = errMsg.components(separatedBy: "at least ").last,
               let needed = UInt64(part.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? "") {
                fee = needed
                continue
            }
            return .failed(errMsg)
        }
        return .failed("RBF retry limit exceeded")
    }
}
