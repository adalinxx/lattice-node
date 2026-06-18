import XCTest
import Foundation
import LatticeNodeAuth

/// RPC-A1: CookieAuth unit suite — exercises the REAL public CookieAuth surface
/// (generate / load / validate) the RPC auth path uses. Covers the token shape
/// and on-disk perms produced by `generate`, the header forms `validate` accepts
/// or rejects, and that the compare is full-length constant-time.
final class CookieAuthTests: XCTestCase {

    private func tmpCookiePath() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(".cookie")
    }

    // MARK: - generate: token shape + file permissions

    /// generate() writes a 64-hex-char (256-bit) token to a 0600 file, and the
    /// returned token matches the on-disk contents.
    func testGenerateProducesHexTokenWithOwnerOnlyPerms() throws {
        let path = tmpCookiePath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        let auth = try CookieAuth.generate(at: path)

        XCTAssertEqual(auth.token.count, 64, "token must be 64 hex chars (256 bits)")
        XCTAssertTrue(auth.token.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) },
                      "token must be lowercase hex")

        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), "cookie file must be written")
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        XCTAssertEqual(perms & 0o777, 0o600, "cookie file must be chmod 0600 (owner read/write only)")

        let onDisk = try String(contentsOf: path, encoding: .utf8)
        XCTAssertEqual(onDisk, auth.token, "on-disk token must equal the returned token")
    }

    /// load() reads back the token generate() wrote (round-trip), trimming any
    /// trailing newline a hand-edited file might carry.
    func testLoadRoundTripsGeneratedToken() throws {
        let path = tmpCookiePath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        let generated = try CookieAuth.generate(at: path)
        let loaded = try CookieAuth.load(from: path)
        XCTAssertEqual(loaded.token, generated.token, "load must round-trip the generated token")
        XCTAssertTrue(loaded.validate(authHeader: "Bearer \(generated.token)"),
                      "a loaded cookie must validate the generated token")
    }

    // MARK: - validate(authHeader:): accepted / rejected forms

    func testValidateAcceptsCorrectBearerHeader() {
        let auth = CookieAuth(token: String(repeating: "a", count: 64), path: tmpCookiePath())
        XCTAssertTrue(auth.validate(authHeader: "Bearer \(auth.token)"),
                      "the canonical 'Bearer <token>' header must be accepted")
    }

    /// The raw-token form (no scheme) is accepted only via validate(queryToken:),
    /// the narrow query-string credential path. The header path requires 'Bearer '.
    func testValidateAcceptsRawTokenViaQueryTokenPath() {
        let auth = CookieAuth(token: String(repeating: "a", count: 64), path: tmpCookiePath())
        XCTAssertTrue(auth.validate(queryToken: auth.token),
                      "the raw token must be accepted on the query-token path")
        XCTAssertFalse(auth.validate(queryToken: String(repeating: "b", count: 64)),
                       "a wrong raw token must be rejected on the query-token path")
        XCTAssertFalse(auth.validate(queryToken: nil),
                       "a missing query token must be rejected")
        XCTAssertFalse(auth.validate(queryToken: ""),
                       "an empty query token must be rejected")
    }

    func testValidateRejectsLowercaseBearerScheme() {
        let auth = CookieAuth(token: String(repeating: "a", count: 64), path: tmpCookiePath())
        XCTAssertFalse(auth.validate(authHeader: "bearer \(auth.token)"),
                       "the scheme is case-sensitive: lowercase 'bearer ' must be rejected")
    }

    func testValidateRejectsBareToken() {
        let auth = CookieAuth(token: String(repeating: "a", count: 64), path: tmpCookiePath())
        XCTAssertFalse(auth.validate(authHeader: auth.token),
                       "a bare token without the 'Bearer ' scheme must be rejected")
    }

    func testValidateRejectsTrailingWhitespaceToken() {
        let auth = CookieAuth(token: String(repeating: "a", count: 64), path: tmpCookiePath())
        XCTAssertFalse(auth.validate(authHeader: "Bearer \(auth.token) "),
                       "a trailing space makes the candidate differ in length and must be rejected")
        XCTAssertFalse(auth.validate(authHeader: "Bearer \(auth.token)\t"),
                       "a trailing tab must be rejected")
    }

    func testValidateRejectsEmptyToken() {
        let auth = CookieAuth(token: String(repeating: "a", count: 64), path: tmpCookiePath())
        XCTAssertFalse(auth.validate(authHeader: "Bearer "),
                       "an empty token after the scheme must be rejected")
        XCTAssertFalse(auth.validate(authHeader: ""), "an empty header must be rejected")
        XCTAssertFalse(auth.validate(authHeader: nil), "a missing header must be rejected")
    }

    /// Duplicate Authorization headers are collapsed by the HTTP layer into a
    /// single comma-joined value before reaching CookieAuth. The joined string is
    /// not a valid single credential and must be rejected — an attacker cannot
    /// smuggle a valid token past the gate by appending a second header.
    func testValidateRejectsDuplicateHeaderJoinedValue() {
        let token = String(repeating: "a", count: 64)
        let auth = CookieAuth(token: token, path: tmpCookiePath())
        // HTTPTypes / Hummingbird join repeated field values with ", ".
        let joined = "Bearer \(token), Bearer \(token)"
        XCTAssertFalse(auth.validate(authHeader: joined),
                       "a comma-joined duplicate Authorization header must be rejected")
    }

    func testValidateRejectsWrongToken() {
        let auth = CookieAuth(token: String(repeating: "a", count: 64), path: tmpCookiePath())
        let wrong = String(repeating: "b", count: 64)
        XCTAssertFalse(auth.validate(authHeader: "Bearer \(wrong)"),
                       "a same-length but different token must be rejected")
    }

    /// constant-time compare is full-length: a candidate that differs only in
    /// length (prefix of the real token) must be rejected by the length guard,
    /// and one differing only in the final byte must also be rejected.
    func testValidateConstantTimeFullLengthCompare() {
        let token = String(repeating: "a", count: 64)
        let auth = CookieAuth(token: token, path: tmpCookiePath())

        let shortPrefix = String(repeating: "a", count: 63)
        XCTAssertFalse(auth.validate(authHeader: "Bearer \(shortPrefix)"),
                       "a correct prefix that is one char short must be rejected (full-length compare)")

        let longerToken = token + "a"
        XCTAssertFalse(auth.validate(authHeader: "Bearer \(longerToken)"),
                       "a longer candidate must be rejected (full-length compare)")

        var lastDiff = token
        lastDiff.removeLast()
        lastDiff.append("b")
        XCTAssertFalse(auth.validate(authHeader: "Bearer \(lastDiff)"),
                       "a token differing only in the final byte must be rejected")
    }
}
