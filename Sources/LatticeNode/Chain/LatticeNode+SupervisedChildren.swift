import Foundation
import Lattice
import cashew
import LatticeNodeRPCFuzzSupport  // GenesisHexCodec/GenesisHexEntry (shared genesis-hex codec)
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession/URLRequest live here on Linux
#endif

// Contract 4 / Item 2 (supervised child lifecycle as a continuous reconciler).
// The child lifecycle is a durable state machine, reconciled on a loop — not a
// one-shot launcher:
//
//   DEPLOYED ─spawn─▶ RUNNING ─cookie+auth─▶ AUTHENTICATED ─register─▶ REGISTERED
//      ▲                  │                                                │
//      │            wedged > grace                          unregister-rpc │
//      │            (force restart)                                        ▼
//      └──────── re-deploy (clears detached) ◀──────────────────────── DETACHED
//
// The reconcile loop re-evaluates every non-detached deployed child each interval,
// so a child that is slow to bind RPC, hung, or that died after registration is
// eventually driven back to REGISTERED (or explicitly logged DEGRADED) without an
// operator. On a parent crash/restart a child may still be alive holding its ports,
// so each pass PROBES before spawning and adopts a live child rather than spawning a
// duplicate into occupied ports.
extension LatticeNode {

    static let supervisedReconcileIntervalSeconds: UInt64 = 30
    /// How long a supervisor-tracked child may answer no RPC before we treat it as
    /// wedged (hung / never bound its RPC) and force a restart, rather than waiting
    /// forever on the supervisor — which only restarts on process *exit*.
    static let supervisedHealthGraceSeconds: TimeInterval = 90

    /// Outcome of a single reconcile pass for one child (for logging/cadence/tests).
    enum SupervisedChildState: Equatable {
        case detached       // operator-detached; intentionally not managed
        case registered     // alive, authenticated, RPC registered for delivery
        case booting        // tracked/launched, RPC not yet answering (within grace)
        case degraded       // alive but no cookie authenticates — manual recovery
        case recovering     // (re)spawned this pass; will register on a later pass
        case resolving      // followed child whose genesis isn't resolved/available yet; retry next sweep
    }

    /// Result of probing a child's authenticated `/chain/auth-check`.
    enum ChildProbeResult {
        case aliveAuthValid   // 200: child alive AND accepts the presented token
        case aliveAuthStale   // answered HTTP but rejected the token (401/403/other)
        case dead             // connection refused / timeout / no HTTP response
    }

    /// Probe a child RPC endpoint (stored API-base form, e.g. http://127.0.0.1:PORT/api).
    func probeChildEndpoint(_ endpoint: String, token: String?) async -> ChildProbeResult {
        guard let url = URL(string: endpoint + "/chain/auth-check") else { return .dead }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let session = RPCRoutes.childFanoutSession()
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .dead }
            switch http.statusCode {
            case 200: return .aliveAuthValid
            default: return .aliveAuthStale   // alive (answered HTTP) but token not accepted
            }
        } catch {
            return .dead
        }
    }

    /// Read a child's on-disk admin cookie (the token the running process accepts).
    private func readChildCookie(dataDir: String) -> String? {
        let path = URL(fileURLWithPath: dataDir).appendingPathComponent(".cookie")
        guard let token = try? String(contentsOf: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        return token
    }

    /// One reconcile pass for a single child. Idempotent and quick: it probes, adopts a
    /// live child, force-restarts a wedged one past the health grace, or recovers a dead
    /// one. Returns the resulting state.
    @discardableResult
    func ensureSupervisedChild(_ metadata: DeployedChainMetadata) async -> SupervisedChildState {
        guard let supervisor = childSupervisor, let rpcBase = childRPCBasePort else { return .detached }

        let key = chainKey(forPath: metadata.chainPath)
        let dir = metadata.directory
        let parentPort = config.listenPort
        let childRPCPort = deterministicPort(basePort: rpcBase, directory: dir)
        let childPort = deterministicPort(basePort: parentPort, directory: dir)
        let endpoint = "http://127.0.0.1:\(childRPCPort)/api"
        let childDataDir = config.storagePath
            .appendingPathComponent("children").appendingPathComponent(dir).path
        let log = NodeLogger("supervisor")

        // The passed-in metadata is a reconcile SNAPSHOT and may be stale: an operator
        // `chain detach` can land while this pass is suspended on a probe/spawn/stop await,
        // setting detached and stopping the process. So the source of truth for "is this
        // child still managed?" is the LIVE dict, re-read after every await and before
        // every side effect — never the snapshot's own `detached`.
        func stillManaged() -> Bool { (deployedChildChains[key].map { !$0.detached }) ?? false }
        guard stillManaged() else { return .detached }

        let supervisorTracksLive = await supervisor.isRunning(dir)
        let persistedToken = registeredRPCAuthToken(chainPath: metadata.chainPath)
        let probe = await probeChildEndpoint(endpoint, token: persistedToken)
        // Detach may have landed during the probe — honor it before any side effect.
        guard stillManaged() else { supervisedRPCDownSince.removeValue(forKey: key); return .detached }

        switch probe {
        case .aliveAuthValid:
            // Live and our persisted token works — (re)register, clear any wedged timer.
            supervisedRPCDownSince.removeValue(forKey: key)
            registerRPCEndpoint(chainPath: metadata.chainPath, endpoint: endpoint, authToken: persistedToken)
            return .registered
        case .aliveAuthStale:
            // Alive on the port but our token is stale — the child rotated its cookie.
            // Adopt the on-disk cookie if it authenticates; never spawn into the live port.
            supervisedRPCDownSince.removeValue(forKey: key)
            if let fresh = readChildCookie(dataDir: childDataDir),
               await probeChildEndpoint(endpoint, token: fresh) == .aliveAuthValid {
                guard stillManaged() else { return .detached }   // detach during the re-probe
                registerRPCEndpoint(chainPath: metadata.chainPath, endpoint: endpoint, authToken: fresh)
                log.info("adopted live supervised child '\(dir)' with rotated cookie at \(endpoint)")
                return .registered
            }
            log.error("supervised child '\(dir)' is alive on \(endpoint) but no on-disk cookie authenticates (DEGRADED); manual recovery needed — not spawning into the occupied port")
            return .degraded
        case .dead:
            if supervisorTracksLive {
                // Tracked alive but RPC dead. The supervisor only restarts on process
                // EXIT, so a hung/slow-to-bind child would otherwise never recover.
                // Allow a health grace for RPC to come up, then force a restart.
                let now = Date()
                let downSince = supervisedRPCDownSince[key] ?? now
                supervisedRPCDownSince[key] = downSince
                if now.timeIntervalSince(downSince) < Self.supervisedHealthGraceSeconds {
                    log.info("supervised child '\(dir)' running but RPC not up yet (booting, within \(Int(Self.supervisedHealthGraceSeconds))s grace)")
                    return .booting
                }
                log.warn("supervised child '\(dir)' wedged (RPC dead > \(Int(Self.supervisedHealthGraceSeconds))s while process alive); forcing restart")
                await supervisor.stop(label: dir)
                guard stillManaged() else { supervisedRPCDownSince.removeValue(forKey: key); return .detached }
                supervisedRPCDownSince.removeValue(forKey: key)
                // fall through to a fresh spawn
            }
            // Provably dead (or just force-stopped) and the port is free — recover.
            supervisedRPCDownSince.removeValue(forKey: key)
            return await recoverDeadChild(metadata, key: key, dir: dir, childPort: childPort,
                                          childRPCPort: childRPCPort, endpoint: endpoint,
                                          childDataDir: childDataDir, supervisor: supervisor, log: log)
        }
    }

    /// Delete the stale cookie, spawn, and make a bounded attempt to register. If the
    /// child is slow to come up the reconcile loop registers it on a later pass.
    private func recoverDeadChild(
        _ metadata: DeployedChainMetadata, key: String, dir: String, childPort: UInt16, childRPCPort: UInt16,
        endpoint: String, childDataDir: String, supervisor: ChildProcessSupervisor, log: NodeLogger
    ) async -> SupervisedChildState {
        func stillManaged() -> Bool { (deployedChildChains[key].map { !$0.detached }) ?? false }
        // Re-check immediately before the destructive delete-cookie + spawn: a detach may
        // have landed since the caller's last check.
        guard stillManaged() else { return .detached }
        // A FOLLOWED child has no locally-built genesis — resolve it from the parent's on-chain
        // GenesisState + CAS before spawning (the spawn requires genesisHex). If the genesis
        // isn't available from pinners yet, stay in `resolving` and let the next sweep retry;
        // never spawn a child without its genesis. Deployed children already have genesisHex,
        // so this is skipped for them.
        var metadata = metadata
        if metadata.followed && metadata.genesisHex.isEmpty {
            guard let resolved = await resolveFollowedGenesis(metadata) else { return .resolving }
            guard stillManaged() else { return .detached }
            deployedChildChains[key] = resolved
            await persistDeployedChildChains()
            metadata = resolved
        }
        let cookiePath = URL(fileURLWithPath: childDataDir).appendingPathComponent(".cookie")
        try? FileManager.default.removeItem(at: cookiePath)
        let spec = ChildSpec(
            directory: dir, chainPath: metadata.chainPath,
            genesisHex: metadata.genesisHex,
            subscribeP2P: "\(config.publicKey)@127.0.0.1:\(config.listenPort)",
            bootstrapPeer: "\(config.publicKey)@127.0.0.1:\(config.listenPort)",
            port: childPort, rpcPort: childRPCPort,
            dataDir: childDataDir, inheritedArguments: childInheritedArguments
        )
        do {
            _ = try await supervisor.spawn(spec.launch(nodeExecutable: ChildProcessSupervisor.selfExecutableURL()))
            log.info("spawned supervised child '\(dir)' (p2p \(childPort), rpc \(childRPCPort))")
        } catch {
            log.error("supervised spawn of '\(dir)' failed: \(error)")
            return .recovering
        }
        // Detach may have raced the spawn — if so, stop the process we just launched so a
        // detached child is not left running, and do not register it.
        guard stillManaged() else {
            await supervisor.stop(label: dir)
            return .detached
        }
        // Bounded register attempt (~10s) for fresh-deploy snappiness; the reconcile
        // loop registers it later if the child is slower to bind RPC + write its cookie.
        for _ in 0..<40 {
            if Task.isCancelled { return .recovering }
            // Honor a detach landing mid-poll: stop the process and stop trying to register.
            guard stillManaged() else { await supervisor.stop(label: dir); return .detached }
            if let token = readChildCookie(dataDir: childDataDir),
               await probeChildEndpoint(endpoint, token: token) == .aliveAuthValid {
                guard stillManaged() else { await supervisor.stop(label: dir); return .detached }
                registerRPCEndpoint(chainPath: metadata.chainPath, endpoint: endpoint, authToken: token)
                log.info("registered supervised child '\(dir)' RPC \(endpoint) for mined-block delivery")
                return .registered
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        log.info("supervised child '\(dir)' spawned but not yet authenticated; reconcile loop will register it once its RPC is up")
        return .recovering
    }

    /// One reconcile sweep over every non-detached deployed child.
    func reconcileSupervisedChildren() async {
        guard childSupervisor != nil else { return }
        // Snapshot before the loop: ensureSupervisedChild suspends on network probes,
        // and a concurrent detach/deploy could mutate deployedChildChains mid-iteration.
        let snapshot = Array(deployedChildChains.values)
        for metadata in snapshot {
            await ensureSupervisedChild(metadata)
        }
    }

    /// Start the continuous reconcile loop (idempotent). Cancelled in `stop()`.
    func startSupervisedReconcileLoop() {
        guard childSupervisor != nil, supervisedReconcileTask == nil else { return }
        supervisedReconcileTask = Task { [self] in
            while !Task.isCancelled {
                await reconcileSupervisedChildren()
                try? await Task.sleep(nanoseconds: Self.supervisedReconcileIntervalSeconds * 1_000_000_000)
            }
        }
    }

    /// Contract 4: mark a deployed child detached (operator `unregister-rpc`), stop its
    /// supervised process, and drop its registration so nothing re-delivers to it.
    func detachSupervisedChild(chainPath: [String]) async {
        let key = chainKey(forPath: chainPath)
        if var metadata = deployedChildChains[key] {
            metadata.detached = true
            deployedChildChains[key] = metadata
            await persistDeployedChildChains()
        }
        supervisedRPCDownSince.removeValue(forKey: key)
        if let supervisor = childSupervisor, let dir = chainPath.last {
            await supervisor.stop(label: dir)
        }
        unregisterRPCEndpoint(chainPath: chainPath)
    }

    /// Declare that this node FOLLOWS (subscribes to) an existing, announced child chain.
    /// Records a followed-child stub (genesis empty); the reconcile loop resolves its genesis
    /// from the parent's on-chain GenesisState + CAS and spawns/syncs it. Idempotent, and
    /// clears a prior detach so re-following resumes management. No-op if not supervising.
    public func followChild(chainPath: [String]) async {
        guard childSupervisor != nil, chainPath.count >= 2, let directory = chainPath.last else { return }
        let key = chainKey(forPath: chainPath)
        let parentDir = chainPath[chainPath.count - 2]
        let existing = deployedChildChains[key]
        deployedChildChains[key] = DeployedChainMetadata(
            chainPath: chainPath, directory: directory, parentDirectory: parentDir,
            genesisHash: existing?.genesisHash ?? "", genesisHex: existing?.genesisHex ?? "",
            timestamp: existing?.timestamp ?? 0, detached: false, followed: true)
        await persistDeployedChildChains()
    }

    /// Resolve a followed child's genesis into a self-contained genesis-hex payload: read its
    /// genesis CID from the parent's on-chain GenesisState, fetch the genesis block + spec +
    /// WASM policy modules from CAS by CID (ivyFetcher does pinner discovery on a local miss),
    /// and encode with the shared `GenesisHexCodec`. Returns an updated metadata with
    /// genesisHash/genesisHex filled, or nil if the genesis isn't resolvable/available yet.
    private func resolveFollowedGenesis(_ metadata: DeployedChainMetadata) async -> DeployedChainMetadata? {
        guard let parentNetwork = network(forPath: Array(metadata.chainPath.dropLast())) else { return nil }
        guard let genesisCID = await announcedChildGenesisCID(chainPath: metadata.chainPath) else { return nil }
        guard let genesisData = try? await parentNetwork.ivyFetcher.fetch(rawCid: genesisCID),
              let genesisBlock = Block(data: genesisData) else { return nil }
        var entries: [GenesisHexEntry] = [GenesisHexEntry(cid: genesisCID, data: genesisData)]
        let specCID = genesisBlock.spec.rawCID
        var spec = genesisBlock.spec.node
        if spec == nil { spec = try? await genesisBlock.spec.resolve(fetcher: parentNetwork.ivyFetcher).node }
        if let specData = spec?.toData() { entries.append(GenesisHexEntry(cid: specCID, data: specData)) }
        if let spec {
            for policy in spec.wasmPolicies {
                let moduleHeader = WasmPolicyModuleHeader(rawCID: policy.moduleCID)
                guard let module = try? await moduleHeader.resolve(fetcher: parentNetwork.ivyFetcher).node,
                      let moduleData = module.toData() else { continue }
                entries.append(GenesisHexEntry(cid: policy.moduleCID, data: moduleData))
            }
        }
        let genesisHex = GenesisHexCodec.encodeEntries(entries).map { String(format: "%02x", $0) }.joined()
        return DeployedChainMetadata(
            chainPath: metadata.chainPath, directory: metadata.directory,
            parentDirectory: metadata.parentDirectory, genesisHash: genesisCID,
            genesisHex: genesisHex, timestamp: metadata.timestamp, detached: metadata.detached, followed: true)
    }
}
