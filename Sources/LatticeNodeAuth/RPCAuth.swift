import Foundation
#if canImport(Security)
import Security
#endif

public enum RPCAuthMode: Sendable {
    case none
    case cookie(path: URL)
}

public struct RPCAuthConfig: Sendable {
    public let mode: RPCAuthMode

    public static let none = RPCAuthConfig(mode: .none)

    public static func cookie(dataDir: URL) -> RPCAuthConfig {
        RPCAuthConfig(mode: .cookie(path: dataDir.appendingPathComponent(".cookie")))
    }
}

public enum RPCAuthError: Error {
    case cookieGenerationFailed
}

public struct CookieAuth: Sendable {
    public let token: String
    public let path: URL

    public init(token: String, path: URL) {
        self.token = token
        self.path = path
    }

    public static func generate(at path: URL) throws -> CookieAuth {
        var bytes = [UInt8](repeating: 0, count: 32)
        #if canImport(Darwin)
        let result = bytes.withUnsafeMutableBufferPointer { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        guard result == errSecSuccess else {
            throw RPCAuthError.cookieGenerationFailed
        }
        #else
        guard let urandom = fopen("/dev/urandom", "r") else {
            throw RPCAuthError.cookieGenerationFailed
        }
        defer { fclose(urandom) }
        guard fread(&bytes, 1, 32, urandom) == 32 else {
            throw RPCAuthError.cookieGenerationFailed
        }
        #endif
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try token.write(to: path, atomically: true, encoding: .utf8)
        #if !os(Windows)
        chmod(path.path, 0o600)
        #endif
        return CookieAuth(token: token, path: path)
    }

    public static func load(from path: URL) throws -> CookieAuth {
        let token = try String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return CookieAuth(token: token, path: path)
    }

    public func validate(authHeader: String?) -> Bool {
        guard let header = authHeader, header.hasPrefix("Bearer ") else { return false }
        let candidate = String(header.dropFirst(7))
        return constantTimeEqual(candidate, token)
    }

    public func validate(queryToken: String?) -> Bool {
        guard let queryToken else { return false }
        return constantTimeEqual(queryToken, token)
    }

    /// XOR-based constant-time string comparison — prevents timing oracle attacks
    /// on the auth token even though the token's 256-bit entropy makes timing
    /// attacks infeasible in practice.
    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var result: UInt8 = 0
        for (x, y) in zip(aBytes, bBytes) { result |= x ^ y }
        return result == 0
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: path)
    }
}
