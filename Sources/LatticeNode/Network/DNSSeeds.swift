import Foundation
import Ivy
import Lattice

public struct DNSSeedSource: Sendable, Equatable {
    public let hostname: String
    public let operatorID: String
    public let trustedPublicKeys: [String]

    public init(hostname: String, operatorID: String, trustedPublicKeys: [String]) {
        self.hostname = hostname
        self.operatorID = operatorID
        self.trustedPublicKeys = trustedPublicKeys
    }
}

public enum DNSSeeds: Sendable {
    public static let minimumMainnetSeedOperators = 2

    // Empty trustedPublicKeys are launch-blocked ops values.
    // A source with no pinned key is ignored, so DNS bootstrap fails closed
    // instead of admitting unsigned peer records.
    public static let sources: [DNSSeedSource] = [
        DNSSeedSource(
            hostname: "seeds.example.org",
            operatorID: "adalinxx",
            trustedPublicKeys: []
        ),
    ]

    // Testnet DNS bootstrap is intentionally hardcoded-only until an operator
    // seed-signing key is pinned. Keeping this empty avoids advertising a DNS
    // hostname that resolveTestnet() must silently skip.
    public static let testnetSources: [DNSSeedSource] = []

    public static var hostnames: [String] { sources.map(\.hostname) }
    public static var testnetHostnames: [String] { testnetSources.map(\.hostname) }
    public static var isMainnetBootstrapConfigured: Bool { sources.contains { !$0.trustedPublicKeys.isEmpty } }
    public static var isTestnetBootstrapConfigured: Bool { testnetSources.contains { !$0.trustedPublicKeys.isEmpty } }

    private static let digTimeout: TimeInterval = 5

    public static func resolveTestnet() async -> [PeerEndpoint] {
        await resolveSources(testnetSources, minimumOperators: 1)
    }

    public static func resolve() async -> [PeerEndpoint] {
        await resolveSources(sources, minimumOperators: minimumMainnetSeedOperators)
    }

    static func resolveSources(
        _ sources: [DNSSeedSource],
        minimumOperators: Int,
        txtResolver: @escaping @Sendable (String) async -> [String] = resolveTXTRecords(hostname:)
    ) async -> [PeerEndpoint] {
        var peersByOperator: [String: [PeerEndpoint]] = [:]
        for source in sources {
            guard !source.trustedPublicKeys.isEmpty else { continue }
            let records = await txtResolver(source.hostname)
            let resolved = records.flatMap { parseSignedSeedSet($0, trustedPublicKeys: source.trustedPublicKeys) }
            if !resolved.isEmpty {
                peersByOperator[source.operatorID, default: []].append(contentsOf: resolved)
            }
        }

        guard Set(peersByOperator.keys).count >= minimumOperators else {
            return []
        }

        var peers: [PeerEndpoint] = []
        for operatorID in peersByOperator.keys.sorted() {
            peers.append(contentsOf: peersByOperator[operatorID] ?? [])
        }
        var seen = Set<String>()
        return peers.filter {
            let key = encodePeerRecord($0)
            return seen.insert(key).inserted
        }
    }

    private static func resolveTXTRecords(hostname: String) async -> [String] {
        guard let output = await runDig(type: "TXT", hostname: hostname) else {
            return []
        }
        return output.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        .filter { !$0.isEmpty }
    }

    static func parsePeerRecord(_ record: String) -> PeerEndpoint? {
        let parts = record.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let pubKey = String(parts[0])
        let hostPort = parts[1].split(separator: ":", maxSplits: 1)
        guard hostPort.count == 2, let port = UInt16(hostPort[1]) else { return nil }
        guard !pubKey.isEmpty, !hostPort[0].isEmpty else { return nil }
        return PeerEndpoint(publicKey: pubKey, host: String(hostPort[0]), port: port)
    }

    static func encodePeerRecord(_ peer: PeerEndpoint) -> String {
        "\(peer.publicKey)@\(peer.host):\(peer.port)"
    }

    static func encodeSignedSeedSet(peers: [PeerEndpoint], signer: (privateKey: String, publicKey: String)) -> String? {
        let payload = canonicalSeedPayload(peers: peers)
        guard let signature = CryptoUtils.sign(message: payload, privateKeyHex: signer.privateKey),
              let payloadBytes = payload.data(using: .utf8) else {
            return nil
        }
        return "lattice-seed-set:v1:\(signer.publicKey):\(signature):\(base64URLEncode(payloadBytes))"
    }

    static func parseSignedSeedSet(_ record: String, trustedPublicKeys: [String]) -> [PeerEndpoint] {
        let parts = record.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count == 5,
              parts[0] == "lattice-seed-set",
              parts[1] == "v1" else {
            return []
        }

        let signer = String(parts[2])
        guard trustedPublicKeys.contains(signer),
              let payloadData = base64URLDecode(String(parts[4])),
              let payload = String(data: payloadData, encoding: .utf8),
              CryptoUtils.verify(message: payload, signature: String(parts[3]), publicKeyHex: signer) else {
            return []
        }

        return parseCanonicalSeedPayload(payload)
    }

    private static func canonicalSeedPayload(peers: [PeerEndpoint]) -> String {
        var seen = Set<String>()
        let records = peers
            .map(encodePeerRecord)
            .filter { seen.insert($0).inserted }
            .sorted()
        return (["lattice-seed-set:v1"] + records).joined(separator: "\n")
    }

    private static func parseCanonicalSeedPayload(_ payload: String) -> [PeerEndpoint] {
        var lines = payload.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "lattice-seed-set:v1" else { return [] }
        lines.removeFirst()

        var seen = Set<String>()
        var peers: [PeerEndpoint] = []
        for line in lines {
            guard seen.insert(line).inserted,
                  let peer = parsePeerRecord(line) else {
                return []
            }
            peers.append(peer)
        }
        guard canonicalSeedPayload(peers: peers) == payload else { return [] }
        return peers
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: 4 - padding))
        }
        return Data(base64Encoded: base64)
    }

    /// Run dig with a timeout. Returns nil if dig is not available or times out.
    private static func runDig(type: String, hostname: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let digPath = "/usr/bin/dig"
                guard FileManager.default.isExecutableFile(atPath: digPath) else {
                    continuation.resume(returning: nil)
                    return
                }

                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: digPath)
                process.arguments = ["+short", "+time=3", "+tries=1", hostname, type]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                // Kill after timeout
                let deadline = DispatchTime.now() + digTimeout
                DispatchQueue.global().asyncAfter(deadline: deadline) {
                    if process.isRunning { process.terminate() }
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                guard process.terminationStatus == 0, !data.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }
}
