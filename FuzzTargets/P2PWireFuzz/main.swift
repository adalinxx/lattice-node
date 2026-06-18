import Foundation
import Ivy
import LatticeNodeWire

enum P2PWireFuzzTarget {
    static let maxInputBytes = 1 << 20

    static func exercise(_ payload: Data) {
        guard payload.count <= maxInputBytes else { return }
        _ = Message.deserialize(payload)
        NetworkWireCodecs.exerciseParserSurface(payload)
    }
}

#if LIBFUZZER
@_cdecl("LLVMFuzzerTestOneInput")
public func LLVMFuzzerTestOneInput(_ rawBytes: UnsafePointer<UInt8>, _ count: Int) -> CInt {
    guard count <= P2PWireFuzzTarget.maxInputBytes else { return 0 }
    P2PWireFuzzTarget.exercise(Data(bytes: rawBytes, count: count))
    return 0
}
#else
@main
enum P2PWireCorpusReplay {
    static func main() throws {
        let paths = CommandLine.arguments.dropFirst()
        guard !paths.isEmpty else {
            P2PWireFuzzTarget.exercise(Data())
            return
        }

        for path in paths {
            try replay(path: URL(fileURLWithPath: path))
        }
    }

    private static func replay(path: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
            throw NSError(domain: "P2PWireFuzz", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing corpus path \(path.path)"])
        }

        if isDirectory.boolValue {
            let files = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
                .filter { !$0.hasDirectoryPath }
                .sorted { $0.path < $1.path }
            for file in files {
                P2PWireFuzzTarget.exercise(try Data(contentsOf: file))
            }
        } else {
            P2PWireFuzzTarget.exercise(try Data(contentsOf: path))
        }
    }
}
#endif
