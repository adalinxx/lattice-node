import Foundation
import Hummingbird
import HTTPTypes
import Synchronization

final class RPCRateLimiter: Sendable {
    private let state = Mutex(State())
    let requestsPerSecond: Int
    let burstSize: Int
    // Hard cap on tracked IPs to prevent memory exhaustion via IP spoofing.
    // Once the cap is hit, new IPs are rate-limited immediately (token=0).
    private static let maxBuckets = 10_000

    private struct State {
        var buckets: [String: Bucket] = [:]
        var lastCleanup: ContinuousClock.Instant = .now
    }

    private struct Bucket {
        var tokens: Double
        var lastRefill: ContinuousClock.Instant
    }

    init(requestsPerSecond: Int = 50, burstSize: Int = 100) {
        self.requestsPerSecond = requestsPerSecond
        self.burstSize = burstSize
    }

    func allow(ip: String) -> Bool {
        // Truncate IP to prevent excessively long strings from bloating the dict
        let key = String(ip.prefix(64))
        let now = ContinuousClock.Instant.now
        return state.withLock { s in
            if now - s.lastCleanup > .seconds(60) {
                s.buckets = s.buckets.filter { now - $0.value.lastRefill < .seconds(120) }
                s.lastCleanup = now
            }

            // Reject new IPs when at capacity to prevent memory exhaustion
            if s.buckets[key] == nil && s.buckets.count >= Self.maxBuckets {
                return false
            }

            var bucket = s.buckets[key] ?? Bucket(tokens: Double(burstSize), lastRefill: now)
            let elapsed = Double((now - bucket.lastRefill).components.seconds)
                + Double((now - bucket.lastRefill).components.attoseconds) / 1e18
            bucket.tokens = min(Double(burstSize), bucket.tokens + elapsed * Double(requestsPerSecond))
            bucket.lastRefill = now

            if bucket.tokens >= 1.0 {
                bucket.tokens -= 1.0
                s.buckets[key] = bucket
                return true
            }
            s.buckets[key] = bucket
            return false
        }
    }
}

struct RateLimitMiddleware<Context: RequestContext>: RouterMiddleware {
    let limiter: RPCRateLimiter
    /// Only trust X-Forwarded-For / X-Real-IP when the node operator has
    /// explicitly confirmed that a trusted reverse proxy sets these headers.
    /// Without a trusted proxy, these headers are attacker-controlled and
    /// allow IP spoofing to evade per-IP rate limits.
    let trustProxyHeaders: Bool

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        // When not behind a trusted proxy, key off the per-connection source IP
        // captured from the channel (RPCRequestContext) — the request headers do
        // not carry the TCP peer address, so without this every direct-connect
        // client would collapse into one shared "unknown" bucket (SEC: one client
        // could then starve all others). Behind a trusted proxy, the forwarded
        // header is authoritative and takes precedence.
        let connectionIP = (context as? RPCRequestContext)?.sourceIP
        let ip = RPCClientIP.extract(from: request.headers, trustProxyHeaders: trustProxyHeaders, connectionIP: connectionIP)

        guard limiter.allow(ip: ip) else {
            var headers = HTTPFields()
            headers.append(HTTPField(name: .init("Retry-After")!, value: "1"))
            return Response(
                status: .tooManyRequests,
                headers: headers,
                body: .init(byteBuffer: .init(string: "{\"error\":\"rate limit exceeded\"}"))
            )
        }
        return try await next(request, context)
    }
}

enum RPCClientIP {
    private static let flyClientIPHeader = HTTPField.Name("Fly-Client-IP")!
    private static let forwardedForHeader = HTTPField.Name("X-Forwarded-For")!
    private static let realIPHeader = HTTPField.Name("X-Real-IP")!

    // This value is for rate-limit bucketing only. Do not use it as an
    // authentication or authorization identity.
    static func extract(from headers: HTTPFields, trustProxyHeaders: Bool, connectionIP: String? = nil) -> String {
        // Without a trusted proxy, proxy headers are attacker-controlled and must
        // be ignored. Fall back to the per-connection source IP (the socket peer
        // address). Each direct-connect client then gets its own token pool;
        // "unknown" is only used when even the connection address is unavailable.
        guard trustProxyHeaders else {
            return normalized(connectionIP) ?? "unknown"
        }

        // Fly's HTTP handler sets Fly-Client-IP to the client address as seen by
        // Fly Proxy. Prefer it over X-Forwarded-For to avoid parsing a list that
        // may include caller-controlled hops when no proxy sits in front of Fly.
        if let flyClientIP = normalized(headers[flyClientIPHeader]) {
            return flyClientIP
        }

        if let forwardedFor = headers[forwardedForHeader],
           let first = forwardedFor.split(separator: ",").first,
           let ip = normalized(String(first)) {
            return ip
        }

        if let realIP = normalized(headers[realIPHeader]) {
            return realIP
        }

        // Even with trusted-proxy mode on, if the forwarded headers are missing
        // fall back to the connection IP rather than collapsing to "unknown".
        return normalized(connectionIP) ?? "unknown"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return trimmed
    }
}
