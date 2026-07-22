import Foundation
import LatticeLightClient
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@main
struct LatticeProofVerifier {
    static func main() async {
        do {
            let data = try readInput()
            let proof = try JSONDecoder().decode(LightClientProof.self, from: data)
            if let blockCID = await LightClientProtocol.verify(proof) {
                print("valid \(blockCID)")
                exit(0)
            }
            writeError("invalid")
            exit(2)
        } catch {
            writeError("error: \(error)")
            exit(1)
        }
    }

    private static func readInput() throws -> Data {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--help"] {
            print("usage: lattice-proof-verifier [--file proof.json]")
            exit(0)
        }
        if args.isEmpty {
            return FileHandle.standardInput.readDataToEndOfFile()
        }
        if args.count == 2, args[0] == "--file" {
            return try Data(contentsOf: URL(fileURLWithPath: args[1]))
        }
        writeError("usage: lattice-proof-verifier [--file proof.json]")
        exit(64)
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
