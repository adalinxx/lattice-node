import Foundation
import XCTest

final class SupplyChainGateTests: XCTestCase {
    func testPackageResolvedFullyPinned() throws {
        let packageResolvedURL = try Self.packageRoot().appendingPathComponent("Package.resolved")
        let data = try Data(contentsOf: packageResolvedURL)

        XCTAssertNoThrow(try PackageResolvedPinValidator.validate(data: data))
    }

    func testLaunchCriticalDependenciesArePinned() throws {
        let packageResolvedURL = try Self.packageRoot().appendingPathComponent("Package.resolved")
        let data = try Data(contentsOf: packageResolvedURL)

        let pins = try PackageResolvedPinValidator.pins(data: data)
        let identities = Set(pins.map(\.identity))
        for identity in ["ivy", "tally", "cashew", "wasmkit"] {
            XCTAssertTrue(identities.contains(identity), "\(identity) must be present in Package.resolved")
        }
    }

    func testRejectsMissingOriginHash() {
        assertInvalid(
            """
            {
              "pins": [
                {
                  "identity": "ivy",
                  "state": {
                    "revision": "53fe41d2261184a3bf12641ae6a5eb35a7427841"
                  }
                }
              ]
            }
            """,
            contains: "originHash"
        )
    }

    func testRejectsEmptyOriginHash() {
        assertInvalid(
            """
            {
              "originHash": "",
              "pins": [
                {
                  "identity": "ivy",
                  "state": {
                    "revision": "53fe41d2261184a3bf12641ae6a5eb35a7427841"
                  }
                }
              ]
            }
            """,
            contains: "originHash"
        )
    }

    func testRejectsMissingRevision() {
        assertInvalid(
            """
            {
              "originHash": "d1f8dc79db9e522688cb8ee16f068d0a66d02c8ae258d8586f00af5cd3207fcb",
              "pins": [
                {
                  "identity": "ivy",
                  "state": {
                    "version": "5.23.0"
                  }
                }
              ]
            }
            """,
            contains: "ivy"
        )
    }

    func testRejectsNonFortyHexRevision() {
        assertInvalid(
            """
            {
              "originHash": "d1f8dc79db9e522688cb8ee16f068d0a66d02c8ae258d8586f00af5cd3207fcb",
              "pins": [
                {
                  "identity": "ivy",
                  "state": {
                    "revision": "not-a-revision"
                  }
                }
              ]
            }
            """,
            contains: "40-hex"
        )
    }

    func testRejectsBranchPins() {
        assertInvalid(
            """
            {
              "originHash": "d1f8dc79db9e522688cb8ee16f068d0a66d02c8ae258d8586f00af5cd3207fcb",
              "pins": [
                {
                  "identity": "lattice",
                  "state": {
                    "branch": "main",
                    "revision": "d27e174c4de23ff52dbe07cec0440838044a02a0"
                  }
                }
              ]
            }
            """,
            contains: "branch"
        )
    }

    private static func packageRoot() throws -> URL {
        if let packageDir = ProcessInfo.processInfo.environment["PACKAGE_DIR"], !packageDir.isEmpty {
            return URL(fileURLWithPath: packageDir)
        }

        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func assertInvalid(
        _ json: String,
        contains expectedMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let data = Data(json.utf8)

        do {
            try PackageResolvedPinValidator.validate(data: data)
            XCTFail("expected invalid Package.resolved fixture", file: file, line: line)
        } catch let error as PackageResolvedPinValidator.ValidationError {
            XCTAssertTrue(
                error.description.contains(expectedMessage),
                "expected error to contain \(expectedMessage), got \(error.description)",
                file: file,
                line: line
            )
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}

private enum PackageResolvedPinValidator {
    struct Pin {
        let identity: String
        let revision: String
    }

    enum ValidationError: Error, CustomStringConvertible {
        case invalidRoot
        case missingOriginHash
        case missingPins
        case invalidState(identity: String)
        case branchPin(identity: String)
        case invalidRevision(identity: String, revision: String?)

        var description: String {
            switch self {
            case .invalidRoot:
                return "Package.resolved must be a JSON object"
            case .missingOriginHash:
                return "Package.resolved originHash must be present and non-empty"
            case .missingPins:
                return "Package.resolved pins must be a non-empty array"
            case .invalidState(let identity):
                return "Package.resolved pin \(identity) must have an object state"
            case .branchPin(let identity):
                return "Package.resolved pin \(identity) must not carry a branch key"
            case .invalidRevision(let identity, let revision):
                let value = revision ?? "<missing>"
                return "Package.resolved pin \(identity) revision must be 40-hex, got \(value)"
            }
        }
    }

    private static let revisionPattern = try! NSRegularExpression(pattern: #"^[0-9a-f]{40}$"#)

    static func validate(data: Data) throws {
        _ = try pins(data: data)
    }

    static func pins(data: Data) throws -> [Pin] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ValidationError.invalidRoot
        }

        guard let originHash = root["originHash"] as? String, !originHash.isEmpty else {
            throw ValidationError.missingOriginHash
        }

        guard let pins = root["pins"] as? [[String: Any]], !pins.isEmpty else {
            throw ValidationError.missingPins
        }

        var validatedPins: [Pin] = []
        for pin in pins {
            let identity = pin["identity"] as? String ?? "<unknown>"
            guard let state = pin["state"] as? [String: Any] else {
                throw ValidationError.invalidState(identity: identity)
            }

            if state["branch"] != nil {
                throw ValidationError.branchPin(identity: identity)
            }

            guard let revision = state["revision"] as? String,
                  isFortyHex(revision) else {
                throw ValidationError.invalidRevision(
                    identity: identity,
                    revision: state["revision"] as? String
                )
            }
            validatedPins.append(Pin(identity: identity, revision: revision))
        }
        return validatedPins
    }

    private static func isFortyHex(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return revisionPattern.firstMatch(in: value, range: range) != nil
    }
}
