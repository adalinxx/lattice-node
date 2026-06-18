import Hummingbird
import NIOCore

/// Request context that captures the per-connection source IP from the
/// Hummingbird channel at request-creation time.
///
/// `request.headers` does NOT carry the TCP peer address; on a public bind
/// (no trusted reverse proxy) the only trustworthy rate-limit key is the
/// connection's remote address. We read it here from `channel.remoteAddress`
/// so `RateLimitMiddleware` can give each source IP an independent token pool
/// instead of collapsing every direct-connect client into one shared bucket.
struct RPCRequestContext: RequestContext {
    var coreContext: CoreRequestContextStorage
    /// Connection source IP (host only, no port) as seen at the socket. `nil`
    /// for non-IP channels (e.g. unix sockets / in-process test harnesses).
    let sourceIP: String?

    init(source: ApplicationRequestContextSource) {
        self.coreContext = .init(source: source)
        self.sourceIP = source.channel.remoteAddress?.ipAddress
    }
}
