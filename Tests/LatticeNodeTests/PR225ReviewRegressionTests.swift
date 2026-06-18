import XCTest

final class PR225ReviewRegressionTests: XCTestCase {
    func testRegisteredRPCProxyCapMatchesLargeTemplateRoutes() throws {
        let rpcServerSource = try readRepoFile("Sources/LatticeNode/RPC/RPCServer.swift")
        let templateSource = try readRepoFile("Sources/LatticeNode/RPC/RPCServer+TemplateRoutes.swift")

        XCTAssertTrue(templateSource.contains("collect(upTo: 4_194_304)"))
        XCTAssertTrue(rpcServerSource.contains("static let maxProxiedRPCResponseBytes = 4_194_304"))
        XCTAssertFalse(rpcServerSource.contains("static let maxProxiedRPCResponseBytes = 131_072"))
    }
}

private func readRepoFile(_ relativePath: String) throws -> String {
    let url = try repoRoot().appendingPathComponent(relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}

private func repoRoot() throws -> URL {
    var url = URL(fileURLWithPath: #filePath)
    while url.pathComponents.count > 1 {
        let package = url.appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: package.path) {
            return url
        }
        url.deleteLastPathComponent()
    }
    throw NSError(domain: "PR225ReviewRegressionTests", code: 1)
}
