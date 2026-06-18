import XCTest
@testable import Lattice
@testable import LatticeNode
import LatticeNodeAuth
import UInt256
import cashew
import VolumeBroker
import Foundation
import WAT
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - In-Memory Broker for Tests

/// A test-only fetcher that wraps a MemoryBroker and BrokerFetcher, providing
/// both fetch and store capabilities for unit tests.
actor TestBrokerFetcher: Fetcher {
    let broker: MemoryBroker
    let fetcher: BrokerFetcher

    init() {
        let broker = MemoryBroker()
        self.broker = broker
        self.fetcher = BrokerFetcher(broker: broker)
    }

    func fetch(rawCid: String) async throws -> Data {
        try await fetcher.fetch(rawCid: rawCid)
    }

    /// Store a single CID→Data entry as a trivial volume payload.
    func store(rawCid: String, data: Data) async {
        try? await broker.storeVolumeLocal(SerializedVolume(root: rawCid, entries: [rawCid: data]))
    }
}

func cas() -> TestBrokerFetcher { TestBrokerFetcher() }

func seedEmptyStateVolume(into broker: any VolumeBroker) async throws {
    let storer = BrokerStorer(broker: broker)
    try LatticeState.emptyHeader.storeRecursively(storer: storer)
    let volumes = storer.collectVolumes(root: LatticeState.emptyHeader.rawCID)
    if !volumes.isEmpty {
        try await broker.storeVolumesLocal(volumes)
    }
}

extension BufferedStorer {
    /// Flush buffered entries to a TestBrokerFetcher for test convenience.
    func flush(to fetcher: TestBrokerFetcher) async {
        for (cid, data) in entries {
            await fetcher.store(rawCid: cid, data: data)
        }
    }
}

// MARK: - Chain Spec & Genesis

// `dir` is retained for source compatibility with existing callers, but a chain's
// directory is no longer carried by ChainSpec — it travels with GenesisConfig/context.
// Use `testGenesis(spec:directory:)` to root a genesis at a non-default directory.
func testSpec(_ dir: String = DEFAULT_ROOT_DIRECTORY, premine: UInt64 = 0, retargetWindow: UInt64 = 1000) -> ChainSpec {
    _ = dir
    return ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
              maxBlockSize: 1_000_000, premine: premine, targetBlockTime: 1_000,
              initialReward: 1024, halvingInterval: 10_000, retargetWindow: retargetWindow)
}

func testGenesis(spec: ChainSpec? = nil, directory: String = DEFAULT_ROOT_DIRECTORY) -> GenesisConfig {
    GenesisConfig(spec: spec ?? testSpec(), timestamp: now() - 10_000, target: UInt256.max, directory: directory)
}

// MARK: - Block Fixture Helpers

func buildRetargetedTestBlock(
    previous: Block,
    timestamp: Int64,
    nonce: UInt64,
    fetcher: Fetcher
) async throws -> Block {
    var candidateNonce = nonce
    while true {
        let block = try await BlockBuilder.buildBlock(
            previous: previous,
            timestamp: timestamp,
            nonce: candidateNonce,
            fetcher: fetcher
        )
        if block.validateProofOfWork(nexusHash: block.proofOfWorkHash()) {
            return block
        }
        let (next, overflow) = candidateNonce.addingReportingOverflow(1)
        if overflow { throw BlockBuilderError.stateComputationFailed }
        candidateNonce = next
    }
}

func storeBlockFixture(
    _ block: Block,
    to fetcher: TestBrokerFetcher,
    includeState: Bool = true
) async throws {
    let header = try VolumeImpl<Block>(node: block)
    let storer = BufferedStorer()
    try header.storeRecursively(storer: storer)

    var excludedStateCIDs = Set<String>()
    if !includeState {
        excludedStateCIDs = [
            block.parentState.rawCID,
            block.prevState.rawCID,
            block.postState.rawCID,
        ]
    }

    for (cid, data) in storer.entries where !excludedStateCIDs.contains(cid) {
        await fetcher.store(rawCid: cid, data: data)
    }
}

@discardableResult
func storeBlockFixtureVolumes(_ block: Block, in network: ChainNetwork) async throws -> [String] {
    let header = try VolumeImpl<Block>(node: block)
    let storer = BrokerStorer(broker: MemoryBroker())
    try header.storeRecursively(storer: storer)
    let volumes = storer.collectVolumes(root: header.rawCID)
    if !volumes.isEmpty {
        try await network.storeVolumesDurably(volumes)
    }
    return storer.storedRoots
}

// MARK: - WASM Policy Helpers

func wasmPolicyFixture(requiringSubstring needle: String, allowOnMatch: Bool = true) throws -> Data {
    let needleBytes = Array(needle.utf8)
    let escapedNeedle = needleBytes.map { String(format: "\\%02x", $0) }.joined()
    let matchResult = allowOnMatch ? 1 : 0
    let missResult = allowOnMatch ? 0 : 1
    let wat = """
    (module
      (memory (export "memory") 1)
      (data (i32.const 16) "\(escapedNeedle)")
      (global $heap (mut i32) (i32.const 1024))
      (func (export "lattice_alloc") (param $len i32) (result i32)
        (local $ptr i32)
        global.get $heap
        local.set $ptr
        global.get $heap
        local.get $len
        i32.add
        global.set $heap
        local.get $ptr)
      (func $contains (param $ptr i32) (param $len i32) (result i32)
        (local $i i32)
        (local $j i32)
        local.get $len
        i32.const \(needleBytes.count)
        i32.lt_u
        if
          i32.const 0
          return
        end
        (block $not_found
          (loop $outer
            local.get $i
            local.get $len
            i32.const \(needleBytes.count)
            i32.sub
            i32.gt_u
            br_if $not_found
            i32.const 0
            local.set $j
            (block $mismatch
              (loop $inner
                local.get $j
                i32.const \(needleBytes.count)
                i32.eq
                if
                  i32.const \(matchResult)
                  return
                end
                local.get $ptr
                local.get $i
                i32.add
                local.get $j
                i32.add
                i32.load8_u
                i32.const 16
                local.get $j
                i32.add
                i32.load8_u
                i32.ne
                br_if $mismatch
                local.get $j
                i32.const 1
                i32.add
                local.set $j
                br $inner))
            local.get $i
            i32.const 1
            i32.add
            local.set $i
            br $outer))
        i32.const \(missResult))
      (export "lattice_validate_transaction" (func $contains))
      (export "lattice_validate_action" (func $contains))
    )
    """
    return Data(try wat2wasm(wat))
}

func wasmPolicyRef(requiringSubstring needle: String, scope: WasmPolicyRef.Scope) throws -> (ref: WasmPolicyRef, entries: [(String, Data)]) {
    let module = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: try wasmPolicyFixture(requiringSubstring: needle)))
    let storer = BufferedStorer()
    try module.storeRecursively(storer: storer)
    return (WasmPolicyRef(moduleCID: module.rawCID, scope: scope), storer.entryList)
}

func wasmPolicyRef(rejectingSubstring needle: String, scope: WasmPolicyRef.Scope) throws -> (ref: WasmPolicyRef, entries: [(String, Data)]) {
    let module = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: try wasmPolicyFixture(requiringSubstring: needle, allowOnMatch: false)))
    let storer = BufferedStorer()
    try module.storeRecursively(storer: storer)
    return (WasmPolicyRef(moduleCID: module.rawCID, scope: scope), storer.entryList)
}

// MARK: - Transaction Helpers

func sign(_ body: TransactionBody, _ kp: (privateKey: String, publicKey: String)) -> Transaction {
    // known-valid local node; CID cannot fail
    let h = try! HeaderImpl<TransactionBody>(node: body)
    let sig = TransactionSigning.sign(bodyHeader: h, privateKeyHex: kp.privateKey)!
    return Transaction(signatures: [kp.publicKey: sig], body: h)
}

func signPreparedTransaction(bodyCID: String, bodyDataHex: String, privateKey: String) -> String {
    guard let bodyData = Data(hex: bodyDataHex),
          let body = TransactionBody(data: bodyData),
          let signature = TransactionSigning.sign(body: body, bodyCID: bodyCID, privateKeyHex: privateKey) else {
        fatalError("failed to sign prepared transaction body")
    }
    return signature
}

func addr(_ pubKey: String) -> String {
    try! HeaderImpl<PublicKey>(node: PublicKey(key: pubKey)).rawCID
}

// MARK: - Time

func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

// MARK: - Deterministic Mining

extension LatticeNode {
    fileprivate func nextNexusMiningTimestampForTests() async -> Int64? {
        let nexusDir = genesisConfig.directory
        guard let chain = await chain(for: nexusDir),
              let network = network(for: nexusDir) else { return nil }
        guard let tip = await chain.getHighestBlock() else { return nil }
        let stub = VolumeImpl<Block>(rawCID: tip.blockHash, node: nil, encryptionInfo: nil)
        guard let tipBlock = try? await stub.resolve(fetcher: network.ivyFetcher).node else { return nil }
        let step = Int64(max(UInt64(1), genesisConfig.spec.targetBlockTime))
        return tipBlock.timestamp + step
    }
}

/// Mine exactly `count` blocks on the target chain. Starts the nexus miner
/// (which drives merged mining for child chains) and polls until the target
/// chain advances by `count` blocks. Returns immediately when done —
/// no unnecessary sleeping or target climbing.
func mineBlocks(
    _ count: Int,
    on node: LatticeNode,
    chain directory: String = "Nexus"
) async throws {
    let getHeight: () async -> UInt64 = {
        guard let chain = await node.chain(for: directory) else { return 0 }
        return await chain.getHighestBlockHeight()
    }
    let startHeight = await getHeight()
    let targetHeight = startHeight + UInt64(count)
    let deadline = Date().addingTimeInterval(30)
    // Drive the block producer directly (one block at a time) — no continuous
    // mining loop. Producing a Nexus block also advances any subscribed
    // in-process child chains via merged mining.
    while await getHeight() < targetHeight {
        if Date() > deadline {
            throw XCTestError(.timeoutWhileWaiting, userInfo: [NSLocalizedDescriptionKey: "mineBlocks timed out waiting for \(count) block(s) on \(directory)"])
        }
        let timestamp = await node.nextNexusMiningTimestampForTests()
        _ = await node.produceAndSubmitBlock(timestampOverride: timestamp)
    }
    // Wait for any in-flight detached block processing tasks
    try await Task.sleep(for: .milliseconds(100))
}

/// Mine with multiple nodes simultaneously until the monitored node reaches
/// `count` new blocks. Use for multi-miner convergence/competition tests.
func mineConcurrent(
    _ count: Int,
    miners: [LatticeNode],
    monitor: LatticeNode? = nil
) async throws {
    let target = monitor ?? miners[0]
    let getHeight: () async -> UInt64 = {
        guard let chain = await target.chain(for: "Nexus") else { return 0 }
        return await chain.getHighestBlockHeight()
    }
    let startHeight = await getHeight()
    let targetHeight = startHeight + UInt64(count)
    let deadline = Date().addingTimeInterval(60)
    while await getHeight() < targetHeight {
        if Date() > deadline {
            throw XCTestError(.timeoutWhileWaiting, userInfo: [NSLocalizedDescriptionKey: "mineConcurrent timed out waiting for \(count) block(s)"])
        }
        // Produce one block from each miner concurrently this round, mimicking
        // competing miners without a continuous loop.
        await withTaskGroup(of: Void.self) { group in
            for miner in miners {
                group.addTask {
                    let timestamp = await miner.nextNexusMiningTimestampForTests()
                    _ = await miner.produceAndSubmitBlock(timestampOverride: timestamp)
                }
            }
            await group.waitForAll()
        }
    }
    try await Task.sleep(for: .milliseconds(100))
}

// MARK: - RPC Admin Auth 

/// admin/state-changing RPC endpoints require a cookie credential
/// regardless of bind address. Tests that drive deploy/template/candidate/
/// register-rpc over HTTP must install a cookie on the server and present its
/// token. This builds the server with a unique cookie and returns both so the
/// caller can thread `cookie.token` into admin requests.
func makeAdminRPCServer(
    node: LatticeNode,
    port: UInt16,
    bindAddress: String = "127.0.0.1",
    allowedOrigin: String = "*"
) throws -> (server: RPCServer, token: String) {
    let cookiePath = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".cookie")
    let cookie = try CookieAuth.generate(at: cookiePath)
    let server = RPCServer(node: node, port: port, bindAddress: bindAddress, allowedOrigin: allowedOrigin, auth: cookie)
    return (server, cookie.token)
}

func waitForRPCServer<T: BinaryInteger>(port: T, timeout: TimeInterval = 2) async throws {
    let url = URL(string: "http://127.0.0.1:\(port)/health")!
    let deadline = Date().addingTimeInterval(timeout)
    var lastError: Error?
    while Date() < deadline {
        do {
            _ = try await URLSession.shared.data(from: url)
            return
        } catch {
            lastError = error
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    throw XCTestError(
        .timeoutWhileWaiting,
        userInfo: [NSLocalizedDescriptionKey: "RPC server on port \(port) did not start: \(String(describing: lastError))"]
    )
}

// MARK: - Port Allocation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Returns a TCP port that the OS has just confirmed is free.
///
/// Real-node tests consume the port value *before* binding (to build peer
/// endpoints like `pubKey@127.0.0.1:<port>`), so we cannot bind-to-0 inside the
/// node and read the port back. Instead we ask the kernel for an ephemeral port
/// here: open a socket, bind to 127.0.0.1:0 (kernel assigns a free port),
/// read it back, then close. Returning a kernel-chosen ephemeral port avoids the
/// EADDRINUSE flakes the old monotonic-counter allocator produced under
/// cross-test / TIME_WAIT collisions, because each call gets a port the kernel
/// currently considers available rather than a blindly-incremented guess.
///
/// There is a small TOCTOU window between close here and the node's later bind,
/// but the kernel will not immediately re-hand-out the same ephemeral port to a
/// concurrent `nextTestPort()` call, so collisions are effectively eliminated in
/// practice. SO_REUSEADDR is *not* set on the probe so the kernel does not return
/// a port still parked in TIME_WAIT.
func nextTestPort() -> UInt16 {
    func probe() -> UInt16? {
        #if canImport(Glibc) || canImport(Darwin)
        #if canImport(Glibc)
        let sockType = Int32(SOCK_STREAM.rawValue)
        #else
        let sockType = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, sockType, 0)
        if fd < 0 { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // kernel picks a free ephemeral port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult != 0 { return nil }

        var assigned = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        if nameResult != 0 { return nil }
        let port = UInt16(bigEndian: assigned.sin_port)
        return port == 0 ? nil : port
        #else
        return nil
        #endif
    }

    for _ in 0..<10 {
        if let port = probe() { return port }
    }
    // Fallback: a randomized high port if the probe somehow fails on this
    // platform. Randomization (vs. a shared monotonic counter) keeps parallel
    // test processes from colliding on the same start value.
    return UInt16.random(in: 40000...60000)
}
