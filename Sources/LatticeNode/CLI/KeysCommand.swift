import ArgumentParser
import Foundation
import Lattice

struct KeysCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keys",
        abstract: "Key management",
        subcommands: [Generate.self, Show.self, Address.self]
    )

    struct Generate: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Generate a new P256 keypair"
        )

        @Option(help: "Save to JSON file")
        var output: String?

        func run() throws {
            let keyPair = CryptoUtils.generateKeyPair()
            let address = CryptoUtils.createAddress(from: keyPair.publicKey)

            printHeader("New Keypair")
            printKeyValue("Address", address)
            printKeyValue("Public Key", keyPair.publicKey)
            printKeyValue("Private Key", keyPair.privateKey)

            if let outputPath = output {
                let json: [String: String] = [
                    "address": address,
                    "publicKey": keyPair.publicKey,
                    "privateKey": keyPair.privateKey,
                ]
                let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: outputPath))
                #if !os(Windows)
                chmod(outputPath, 0o600)
                #endif
                print("")
                printSuccess("Saved to \(outputPath)")
            }

            print("")
            printWarning("Store your private key securely. It cannot be recovered.")
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show key info from a JSON key file"
        )

        @Argument(help: "Path to key JSON file")
        var path: String

        func run() throws {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                printError("Invalid key file format")
                throw ExitCode.failure
            }

            printHeader("Key File: \(path)")
            if let address = json["address"] {
                printKeyValue("Address", address)
            }
            if let pub = json["publicKey"] {
                printKeyValue("Public Key", pub)
            }
            if json["privateKey"] != nil {
                printKeyValue("Private Key", "\(Style.dim)(present, hidden)\(Style.reset)")
            }
        }
    }

    struct Address: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Derive address from a public key"
        )

        @Argument(help: "Public key hex string")
        var publicKey: String

        func run() {
            let address = CryptoUtils.createAddress(from: publicKey)
            printHeader("Address Derivation")
            printKeyValue("Public Key", publicKey)
            printKeyValue("Address", address)
        }
    }
}
