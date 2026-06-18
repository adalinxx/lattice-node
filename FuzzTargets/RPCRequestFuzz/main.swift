import Foundation
import LatticeNodeRPCFuzzSupport

// Manual libFuzzer build: swift build --product RPCRequestFuzz -Xswiftc -DLIBFUZZER -Xswiftc -sanitize=fuzzer
#if LIBFUZZER
@_cdecl("LLVMFuzzerTestOneInput")
public func LLVMFuzzerTestOneInput(_ rawBytes: UnsafePointer<UInt8>, _ count: Int) -> CInt {
    guard count <= RPCRequestFuzzTarget.maxInputBytes else { return 0 }
    RPCRequestFuzzTarget.exercise(Data(bytes: rawBytes, count: count))
    return 0
}

#if LIBFUZZER_BUILD_CHECK
@main
enum RPCRequestLibFuzzerBuildCheck {
    static func main() {
        RPCRequestFuzzTarget.exercise(Data())
    }
}
#endif
#else
@main
enum RPCRequestCorpusReplay {
    static func main() throws {
        let paths = CommandLine.arguments.dropFirst()
        guard !paths.isEmpty else {
            RPCRequestFuzzTarget.exercise(Data())
            return
        }

        for path in paths {
            try replay(path: URL(fileURLWithPath: path))
        }
    }

    private static func replay(path: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
            throw NSError(domain: "RPCRequestFuzz", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing corpus path \(path.path)"])
        }

        if isDirectory.boolValue {
            let files = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
                .filter { !$0.hasDirectoryPath }
                .sorted { $0.path < $1.path }
            for file in files {
                RPCRequestFuzzTarget.exercise(try Data(contentsOf: file))
            }
        } else {
            RPCRequestFuzzTarget.exercise(try Data(contentsOf: path))
        }
    }
}
#endif
