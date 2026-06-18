import ArgumentParser
import Foundation

struct IdentityCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "identity",
        abstract: "Generate or show node identity (no node startup)"
    )

    @Option(name: .long, help: "Data directory")
    var dataDir: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lattice").path

    @Flag(name: .long, help: "Output public key only (for scripting)")
    var publicKeyOnly: Bool = false

    func run() throws {
        let dataDirURL = URL(fileURLWithPath: dataDir)
        let identity = try loadOrCreateIdentity(dataDir: dataDirURL)

        if publicKeyOnly {
            print(identity.publicKey)
        } else {
            print(identity.publicKey)
        }
    }
}
