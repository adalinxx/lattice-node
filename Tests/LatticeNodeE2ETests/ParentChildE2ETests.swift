import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Crypto
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Lattice
import LatticeLightClient
import LatticeMinerCore
import LatticeNode
import Ivy
import UInt256
import XCTest
import cashew

@MainActor
final class ParentChildE2ETests: XCTestCase {
    func testChildBootstrapsFromRestartedParentAndAdvancesInLiveRound() async throws {
        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        defer {
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let binary = try E2EBinary.latticeNode()
        let coordinator = try E2EBinary.latticeMiningCoordinator()
        let miner = try E2EBinary.latticeMiner()
        let parentIdentity = try workspace.makeIdentity(named: "nexus")
        let parentPeerKey = try PeerKey(parentIdentity.publicKey)
        let childIdentity = try workspace.makeIdentity(named: "child")
        let ports = try E2EPorts.allocate(count: 6)

        let parent = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "nexus",
                chainPath: "Nexus",
                storage: workspace.url.appendingPathComponent("nexus", isDirectory: true),
                identity: parentIdentity,
                overlayPort: ports[0],
                factPort: ports[1],
                rpcPort: ports[2]
            ),
            logDirectory: workspace.logs
        )
        let child = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "child",
                chainPath: "Nexus/Payments",
                storage: workspace.url.appendingPathComponent("child", isDirectory: true),
                identity: childIdentity,
                overlayPort: ports[3],
                factPort: ports[4],
                rpcPort: ports[5],
                parent: .init(
                    publicKey: parentPeerKey.hex,
                    factPort: ports[1]
                )
            ),
            logDirectory: workspace.logs
        )
        cluster.add(parent)
        cluster.add(child)

        // A child may start before either its parent or its directory exists.
        // It owns no local genesis and remains awaiting its direct parent.
        try child.start()
        let awaitingParent = try await child.waitForStatus { status in
            status.phase == .awaitingGenesis && status.tipCID == nil
        }
        XCTAssertEqual(awaitingParent.chainPath, ["Nexus", "Payments"])
        XCTAssertEqual(awaitingParent.nexusGenesisCID, NexusGenesis.expectedBlockHash)

        try parent.start()
        let initialParent = try await parent.waitForStatus { status in
            status.phase == .active && status.chainPath == ["Nexus"]
        }
        XCTAssertEqual(initialParent.nexusGenesisCID, NexusGenesis.expectedBlockHash)
        XCTAssertEqual(initialParent.tipCID, NexusGenesis.expectedBlockHash)
        XCTAssertEqual(initialParent.height, 0)

        // The child is already connected or retrying its configured parent,
        // but an unissued directory grants it no hierarchy role or genesis.
        let awaitingDirectory = try await child.waitForStatus { status in
            status.phase == .awaitingGenesis && status.tipCID == nil
        }
        XCTAssertEqual(awaitingDirectory.chainPath, ["Nexus", "Payments"])

        let intent = try await childIntent(
            on: parent,
            directory: "Payments",
            timestamp: 1
        )
        XCTAssertEqual(intent.chainPath, ["Nexus", "Payments"])

        try await submitLegacyGenesisAnchor(
            on: parent,
            intent: intent,
            chainPath: ["Nexus"]
        )

        // Intent and anchor are not a child carrier. The child must still
        // await the separately accepted parent block and its direct proof.
        let awaitingCarrier = try await child.waitForStatus { status in
            status.phase == .awaitingGenesis && status.tipCID == nil
        }
        XCTAssertEqual(awaitingCarrier.chainPath, ["Nexus", "Payments"])

        let firstWork = try await mine(parent, mode: .deployment)
        XCTAssertTrue(firstWork.accepted)

        let activated = try await child.waitForStatus { status in
            status.phase == .active && status.tipCID == intent.genesisCID
        }
        XCTAssertEqual(activated.nexusGenesisCID, NexusGenesis.expectedBlockHash)
        XCTAssertEqual(activated.chainPath, ["Nexus", "Payments"])
        XCTAssertEqual(activated.height, 0)

        // This exercises the public child ingress → child mempool → parent
        // template → proof → child admission path with the legacy body-CID
        // signature format still accepted by the node.
        let childTransaction = try legacySignedTransaction(
            chainPath: ["Nexus", "Payments"]
        )
        let _: SubmitTransactionResponse = try await child.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: childTransaction)
        )
        let queued = try await child.waitForStatus { $0.mempoolCount == 1 }
        XCTAssertEqual(queued.mempoolCount, 1)

        // The anchor block proves bootstrap. A second root round through the
        // shipped coordinator and process worker proves the live
        // parent-child candidate/proof loop, not just intent deployment.
        let secondWork = try await mineWithCoordinator(
            parent,
            coordinator: coordinator,
            miner: miner
        )
        XCTAssertEqual(secondWork.result, "submitted")
        XCTAssertTrue(secondWork.accepted)
        XCTAssertEqual(secondWork.disposition, "canonicalized")
        let progressed = try await child.waitForStatus { status in
            status.phase == .active
                && status.tipCID != intent.genesisCID
                && (status.height ?? 0) > (activated.height ?? 0)
                && status.mempoolCount == 0
        }
        XCTAssertNotEqual(progressed.tipCID, intent.genesisCID)
        let progressedTip = try XCTUnwrap(progressed.tipCID)
        let progressedHeight = try XCTUnwrap(progressed.height)
        let progressedParentTip = try XCTUnwrap(secondWork.tipCID)
        _ = try await parent.waitForStatus { status in
            status.phase == .active && status.tipCID == progressedParentTip
        }

        // The accepted parent carrier and direct proof survive a parent
        // process restart while the live child retains its own projection.
        try await parent.stop()
        try parent.start()
        let restoredParent = try await parent.waitForStatus { status in
            status.phase == .active && status.tipCID == progressedParentTip
        }
        XCTAssertEqual(restoredParent.tipCID, progressedParentTip)
        let preservedChild = try await child.waitForStatus { status in
            status.phase == .active
                && status.tipCID == progressedTip
                && status.height == progressedHeight
        }
        XCTAssertEqual(preservedChild.height, progressedHeight)

        // A child restores its own accepted forest; it does not need the
        // parent to re-bootstrap its genesis after a local process restart.
        try await child.stop()
        try child.start()
        let restoredChild = try await child.waitForStatus { status in
            status.phase == .active && status.tipCID == progressedTip
        }
        XCTAssertEqual(restoredChild.height, progressedHeight)

        // Parent and child reconnect independently after their process
        // restarts, so allow bounded physical root rounds for the next live
        // child candidate rather than assuming one scheduler turn.
        var reprogressed: ChainServiceStatusResponse?
        for _ in 0..<5 {
            let work = try await mine(parent)
            XCTAssertTrue(work.accepted)
            guard let status = try? await child.waitForStatus(
                timeout: .seconds(2),
                where: { status in
                    status.phase == .active && (status.height ?? 0) > progressedHeight
                }
            ) else { continue }
            reprogressed = status
            break
        }
        let finalChild = try XCTUnwrap(reprogressed)
        XCTAssertNotEqual(finalChild.tipCID, progressedTip)

        try await cluster.stopAll()
        passed = true
    }

    func testPublicPolicyChildDeploysAndEnforcesWasmWithoutLosingLiveness()
        async throws {
        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        defer {
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let binary = try E2EBinary.latticeNode()
        let parentIdentity = try workspace.makeIdentity(named: "policy-parent")
        let childIdentity = try workspace.makeIdentity(named: "policy-child")
        let parentKey = try PeerKey(parentIdentity.publicKey)
        let ports = try E2EPorts.allocate(count: 6)
        let parent = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "policy-parent",
                chainPath: "Nexus",
                storage: workspace.url.appendingPathComponent("policy-parent"),
                identity: parentIdentity,
                overlayPort: ports[0],
                factPort: ports[1],
                rpcPort: ports[2]
            ),
            logDirectory: workspace.logs
        )
        let child = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "policy-child",
                chainPath: "Nexus/Policy",
                storage: workspace.url.appendingPathComponent("policy-child"),
                identity: childIdentity,
                overlayPort: ports[3],
                factPort: ports[4],
                rpcPort: ports[5],
                parent: .init(publicKey: parentKey.hex, factPort: ports[1])
            ),
            logDirectory: workspace.logs
        )
        cluster.add(parent)
        cluster.add(child)
        try parent.start()
        try child.start()
        _ = try await parent.waitForStatus { $0.phase == .active }
        _ = try await child.waitForStatus { $0.phase == .awaitingGenesis }

        let module = WasmPolicyModule(bytes: try XCTUnwrap(Data(
            base64Encoded: "AGFzbQEAAAABDAJgAX8Bf2ACf38BfwMDAgABBQMBAAEGBwF/AUGACAsHUwQGbWVtb3J5AgANbGF0dGljZV9hbGxvYwAAHGxhdHRpY2VfdmFsaWRhdGVfdHJhbnNhY3Rpb24AARdsYXR0aWNlX3ZhbGlkYXRlX2FjdGlvbgABCnICEQEBfyMAIQEjACAAaiQAIAELXgECfyABQQ9JBEBBAA8LAkADQCACIAFBD2tLDQFBACEDAkADQCADQQ9GBEBBAQ8LIAAgAmogA2otAABBECADai0AAEcNASADQQFqIQMMAAsLIAJBAWohAgwACwtBAAsLFQEAQRALD3BvbGljeS1zZW50aW5lbA=="
        )))
        let moduleCID = try WasmPolicyModuleHeader(node: module).rawCID
        XCTAssertEqual(
            moduleCID,
            "bafyreif6fnqbpy6xnnigwmx3fpb7vx3sygjlqx65lnu4onqgww4ba3y7zy"
        )
        let intent: ChildDeployIntentResponse = try await parent.post(
            "/v1/children/intents",
            body: ChildDeployIntentRequest(
                directory: "Policy",
                spec: ChainSpec(
                    maxNumberOfTransactionsPerBlock: 100,
                    maxStateGrowth: 100_000,
                    premine: 0,
                    targetBlockTime: 1_000,
                    initialReward: 10,
                    halvingInterval: 100,
                    wasmPolicies: [WasmPolicyRef(
                        moduleCID: moduleCID,
                        scope: .action
                    )]
                ),
                genesisTransactions: [],
                policyModules: [module],
                target: .max,
                timestamp: 1
            )
        )
        try await parent.stop()
        try parent.start()
        _ = try await parent.waitForStatus {
            $0.phase == .active && $0.pendingChildIntents == 1
        }
        try await submitGenesisAnchor(
            on: parent,
            intent: intent,
            chainPath: ["Nexus"]
        )
        let deployment = try await mine(parent, mode: .deployment)
        XCTAssertTrue(deployment.accepted)
        _ = try await child.waitForStatus {
            $0.phase == .active && $0.tipCID == intent.genesisCID
        }

        let signer = CryptoUtils.generateKeyPair()
        let firstAllowed = try signedTransaction(
            key: signer,
            chainPath: ["Nexus", "Policy"],
            actions: [Action(
                key: "policy-sentinel/first",
                oldValue: nil,
                newValue: "accepted"
            )],
            nonce: 0
        )
        let _: SubmitTransactionResponse = try await child.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: firstAllowed)
        )
        _ = try await child.waitForStatus { $0.mempoolCount == 1 }
        let firstWork = try await mine(parent)
        XCTAssertTrue(firstWork.accepted)
        let firstAccepted = try await child.waitForStatus {
            $0.height == 1 && $0.mempoolCount == 0
        }

        let rejected = try signedTransaction(
            key: signer,
            chainPath: ["Nexus", "Policy"],
            actions: [Action(
                key: "forbidden",
                oldValue: nil,
                newValue: "rejected"
            )],
            nonce: 1
        )
        do {
            let _: SubmitTransactionResponse = try await child.post(
                "/v1/transactions",
                body: SubmitTransactionRequest(transaction: rejected)
            )
            XCTFail("policy-rejected transaction was accepted")
        } catch let error as E2EHTTPError {
            XCTAssertEqual(error.status, 400)
        }
        let afterRejection = try await child.waitForStatus { _ in true }
        XCTAssertEqual(afterRejection.tipCID, firstAccepted.tipCID)
        XCTAssertEqual(afterRejection.height, firstAccepted.height)
        XCTAssertEqual(afterRejection.mempoolCount, 0)

        let secondAllowed = try signedTransaction(
            key: signer,
            chainPath: ["Nexus", "Policy"],
            actions: [Action(
                key: "policy-sentinel/second",
                oldValue: nil,
                newValue: "accepted"
            )],
            nonce: 1
        )
        let _: SubmitTransactionResponse = try await child.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: secondAllowed)
        )
        _ = try await child.waitForStatus { $0.mempoolCount == 1 }
        let secondWork = try await mine(parent)
        XCTAssertTrue(secondWork.accepted)
        _ = try await child.waitForStatus {
            $0.height == 2 && $0.mempoolCount == 0
        }

        try await cluster.stopAll()
        passed = true
    }

    func testPortableContinuityWaitsForLiveParentWorkBeforeConsensus() async throws {
        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        defer {
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let binary = try E2EBinary.latticeNode()
        let parentIdentity = try workspace.makeIdentity(
            named: "portable-parent",
            seed: 1
        )
        let parentKey = try PeerKey(parentIdentity.publicKey)
        let sourceIdentity = try workspace.makeIdentity(
            named: "portable-source",
            seed: 2
        )
        let lateIdentity = try workspace.makeIdentity(
            named: "portable-late",
            seed: 3
        )
        let impostorIdentity = try workspace.makeIdentity(
            named: "portable-impostor",
            seed: 4
        )
        let ports = try E2EPorts.allocate(count: 12)
        let parentPeer = try overlayPeer(identity: parentIdentity, port: ports[0])
        let parent = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "portable-parent",
                chainPath: "Nexus",
                storage: workspace.url.appendingPathComponent("portable-parent"),
                identity: parentIdentity,
                overlayPort: ports[0],
                factPort: ports[1],
                rpcPort: ports[2]
            ),
            logDirectory: workspace.logs
        )
        let source = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "portable-source",
                chainPath: "Nexus/Payments",
                storage: workspace.url.appendingPathComponent("portable-source"),
                identity: sourceIdentity,
                overlayPort: ports[3],
                factPort: ports[4],
                rpcPort: ports[5],
                parent: .init(publicKey: parentKey.hex, factPort: ports[1])
            ),
            logDirectory: workspace.logs
        )
        let late = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "portable-late",
                chainPath: "Nexus/Payments",
                storage: workspace.url.appendingPathComponent("portable-late"),
                identity: lateIdentity,
                overlayPort: ports[6],
                factPort: ports[7],
                rpcPort: ports[8],
                overlayPeers: [try overlayPeer(
                    identity: sourceIdentity,
                    port: ports[3]
                )],
                parent: .init(publicKey: parentKey.hex, factPort: ports[1])
            ),
            logDirectory: workspace.logs
        )
        let impostor = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "portable-impostor",
                chainPath: "Nexus",
                storage: workspace.url.appendingPathComponent("portable-impostor"),
                identity: impostorIdentity,
                overlayPort: ports[9],
                factPort: ports[10],
                rpcPort: ports[11],
                overlayPeers: [parentPeer]
            ),
            logDirectory: workspace.logs
        )
        let wrongParent = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "portable-wrong-parent",
                chainPath: "Nexus",
                storage: workspace.url.appendingPathComponent("portable-impostor"),
                identity: impostorIdentity,
                overlayPort: ports[9],
                factPort: ports[1],
                rpcPort: ports[11]
            ),
            logDirectory: workspace.logs
        )
        cluster.add(parent)
        cluster.add(source)
        cluster.add(late)
        cluster.add(impostor)
        cluster.add(wrongParent)
        XCTAssertNotEqual(parentKey.hex, wrongParent.processPublicKey)

        try parent.start()
        try source.start()
        _ = try await parent.waitForStatus { $0.phase == .active }
        let intent = try await childIntent(
            on: parent,
            directory: "Payments",
            timestamp: 1
        )
        try await submitLegacyGenesisAnchor(
            on: parent,
            intent: intent,
            chainPath: ["Nexus"]
        )
        let deployed = try await mine(parent, mode: .deployment)
        XCTAssertTrue(deployed.accepted)
        _ = try await source.waitForStatus {
            $0.phase == .active && $0.tipCID == intent.genesisCID
        }

        let transaction = try legacySignedTransaction(
            chainPath: ["Nexus", "Payments"],
            keySeed: 4
        )
        let _: SubmitTransactionResponse = try await source.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: transaction)
        )
        _ = try await source.waitForStatus { $0.mempoolCount == 1 }
        var sourceTip: ChainServiceStatusResponse?
        for _ in 0..<5 {
            let work = try await mine(parent)
            XCTAssertTrue(work.accepted)
            guard let progressed = try? await source.waitForStatus(
                timeout: .seconds(2),
                where: { ($0.height ?? 0) > 0 }
            ) else { continue }
            sourceTip = progressed
            break
        }
        let expectedTip = try XCTUnwrap(sourceTip)

        // Give the later wrong-key parent the exact accepted Nexus history.
        // Its persisted facts are therefore sufficient; only its process
        // identity differs from the authority pinned by child genesis.
        try impostor.start()
        let parentTip = try await parent.waitForStatus { $0.height ?? 0 > 0 }
        _ = try await waitForTip(impostor, try XCTUnwrap(parentTip.tipCID))
        try await impostor.stop()

        // Historical parent-signed attachments remain portable across the
        // same-chain overlay, but neither an existing child nor a late joiner
        // may treat them as a current view of parent state. A live process on
        // the configured fact port is insufficient when its identity is not
        // the parent authority pinned by child genesis.
        try await parent.stop()
        try wrongParent.start()
        _ = try await wrongParent.waitForStatus { $0.phase == .active }
        try await source.stop()
        try source.start()
        let staleSource = try await source.waitForStatus {
            $0.phase == .awaitingParent && $0.tipCID == expectedTip.tipCID
        }
        XCTAssertEqual(staleSource.height, expectedTip.height)

        try late.start()
        let staleLate = try await late.waitForStatus(timeout: .seconds(20)) {
            $0.phase == .awaitingParent && $0.tipCID == expectedTip.tipCID
        }
        XCTAssertEqual(staleLate.height, expectedTip.height)

        // The deterministic hierarchy-role and parent-fact gate tests prove
        // the identity rejection itself. This bounded shipped-process check
        // adds operational evidence that neither child activates while a
        // synchronized wrong-key process occupies the exact parent port.
        let wrongParentWork = try await mine(wrongParent)
        XCTAssertTrue(wrongParentWork.accepted)
        let observationDeadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < observationDeadline {
            for (node, baseline) in [(source, staleSource), (late, staleLate)] {
                let stillStale = try await node.waitForStatus(
                    timeout: .seconds(1)
                ) { _ in true }
                XCTAssertEqual(stillStale.phase, .awaitingParent)
                XCTAssertEqual(stillStale.tipCID, expectedTip.tipCID)
                XCTAssertEqual(stillStale.height, expectedTip.height)
                XCTAssertEqual(
                    stillStale.parentWorkRevision,
                    baseline.parentWorkRevision
                )
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        for node in [source, late] {
            do {
                let _: MiningTemplateResponse = try await node.post(
                    "/v1/mining/templates",
                    body: MiningTemplateRequest(mode: .normal)
                )
                XCTFail("child issued mining work without its configured parent")
            } catch let error as E2EHTTPError {
                XCTAssertEqual(error.status, 503)
            }
        }

        // The configured parent completes a fresh inherited-work snapshot.
        // Only that live completion makes the already verified tip
        // operational on both same-chain peers.
        try await wrongParent.stop()
        try parent.start()
        _ = try await parent.waitForStatus { $0.phase == .active }
        _ = try await source.waitForStatus(timeout: .seconds(20)) {
            $0.phase == .active && $0.tipCID == expectedTip.tipCID
        }
        let recovered = try await late.waitForStatus(timeout: .seconds(20)) {
            $0.phase == .active && $0.tipCID == expectedTip.tipCID
        }
        XCTAssertEqual(recovered.height, expectedTip.height)

        // Accepted history is locally durable, but reopening it while the
        // parent is offline still exposes only a stale last-known tip.
        try await parent.stop()
        try await late.stop()
        try await source.stop()
        try late.start()
        let reopenedStale = try await late.waitForStatus(timeout: .seconds(10)) {
            $0.phase == .awaitingParent && $0.tipCID == expectedTip.tipCID
        }
        XCTAssertEqual(reopenedStale.height, expectedTip.height)

        try parent.start()
        _ = try await parent.waitForStatus { $0.phase == .active }
        let reopened = try await late.waitForStatus(timeout: .seconds(20)) {
            $0.phase == .active && $0.tipCID == expectedTip.tipCID
        }
        XCTAssertEqual(reopened.height, expectedTip.height)

        try await cluster.stopAll()
        passed = true
    }

    func testNestedLateJoinReplaysThroughRestartedIntermediateParent() async throws {
        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        defer {
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let binary = try E2EBinary.latticeNode()
        let nexusIdentity = try workspace.makeIdentity(named: "nexus")
        let nexusPeerKey = try PeerKey(nexusIdentity.publicKey)
        let paymentsIdentity = try workspace.makeIdentity(named: "payments")
        let paymentsPeerKey = try PeerKey(paymentsIdentity.publicKey)
        let receiptsIdentity = try workspace.makeIdentity(named: "receipts")
        let ports = try E2EPorts.allocate(count: 9)

        let nexus = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "nexus",
                chainPath: "Nexus",
                storage: workspace.url.appendingPathComponent("nexus", isDirectory: true),
                identity: nexusIdentity,
                overlayPort: ports[0],
                factPort: ports[1],
                rpcPort: ports[2]
            ),
            logDirectory: workspace.logs
        )
        let payments = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "payments",
                chainPath: "Nexus/Payments",
                storage: workspace.url.appendingPathComponent("payments", isDirectory: true),
                identity: paymentsIdentity,
                overlayPort: ports[3],
                factPort: ports[4],
                rpcPort: ports[5],
                parent: .init(publicKey: nexusPeerKey.hex, factPort: ports[1])
            ),
            logDirectory: workspace.logs
        )
        let receipts = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "receipts",
                chainPath: "Nexus/Payments/Receipts",
                storage: workspace.url.appendingPathComponent("receipts", isDirectory: true),
                identity: receiptsIdentity,
                overlayPort: ports[6],
                factPort: ports[7],
                rpcPort: ports[8],
                parent: .init(publicKey: paymentsPeerKey.hex, factPort: ports[4])
            ),
            logDirectory: workspace.logs
        )
        cluster.add(nexus)
        cluster.add(payments)
        cluster.add(receipts)

        try nexus.start()
        let nexusGenesis = try await nexus.waitForStatus { status in
            status.phase == .active && status.tipCID == NexusGenesis.expectedBlockHash
        }
        XCTAssertEqual(nexusGenesis.chainPath, ["Nexus"])
        XCTAssertEqual(nexusGenesis.height, 0)

        let paymentsIntent = try await childIntent(
            on: nexus,
            directory: "Payments",
            timestamp: 1
        )
        try await submitLegacyGenesisAnchor(
            on: nexus,
            intent: paymentsIntent,
            chainPath: ["Nexus"]
        )
        let paymentsAnchorWork = try await mine(nexus, mode: .deployment)
        XCTAssertTrue(paymentsAnchorWork.accepted)

        try payments.start()
        let paymentsGenesis = try await payments.waitForStatus { status in
            status.phase == .active && status.tipCID == paymentsIntent.genesisCID
        }
        XCTAssertEqual(paymentsGenesis.chainPath, ["Nexus", "Payments"])
        XCTAssertEqual(paymentsGenesis.nexusGenesisCID, NexusGenesis.expectedBlockHash)
        XCTAssertEqual(paymentsGenesis.height, 0)

        let receiptsIntent = try await childIntent(
            on: payments,
            directory: "Receipts",
            timestamp: 2
        )
        try await submitLegacyGenesisAnchor(
            on: payments,
            intent: receiptsIntent,
            chainPath: ["Nexus", "Payments"]
        )

        // Nexus mines one physical root; Payments supplies its contextual
        // candidate, which commits the direct Receipts genesis beneath it.
        let receiptsAnchorWork = try await mine(nexus, mode: .deployment)
        XCTAssertTrue(receiptsAnchorWork.accepted)
        let nexusWithReceipts = try await nexus.waitForStatus { status in
            status.phase == .active && status.tipCID == receiptsAnchorWork.tipCID
        }
        let nexusHeight = try XCTUnwrap(nexusWithReceipts.height)
        let paymentsWithReceipts = try await payments.waitForStatus { status in
            status.phase == .active
                && status.tipCID != paymentsIntent.genesisCID
                && (status.height ?? 0) > 0
                && status.mempoolCount == 0
        }
        let paymentsTip = try XCTUnwrap(paymentsWithReceipts.tipCID)
        let paymentsHeight = try XCTUnwrap(paymentsWithReceipts.height)

        // Neither ancestor is available while the newest child starts. It must
        // wait rather than manufacture a genesis from the root tree.
        try await payments.stop()
        try await nexus.stop()
        try receipts.start()
        let awaitingReceipts = try await receipts.waitForStatus { status in
            status.phase == .awaitingGenesis && status.tipCID == nil
        }
        XCTAssertEqual(awaitingReceipts.chainPath, ["Nexus", "Payments", "Receipts"])
        XCTAssertEqual(awaitingReceipts.nexusGenesisCID, NexusGenesis.expectedBlockHash)

        // Durable history lets both descendants recover their tips, but each
        // remains non-consensus-ready until its configured parent has a live
        // inherited-work session.
        try payments.start()
        let restoredPayments = try await payments.waitForStatus { status in
            status.phase == .awaitingParent && status.tipCID == paymentsTip
        }
        XCTAssertEqual(restoredPayments.height, paymentsHeight)
        let receiptsGenesis = try await receipts.waitForStatus { status in
            status.phase == .awaitingParent
                && status.tipCID == receiptsIntent.genesisCID
        }
        XCTAssertEqual(receiptsGenesis.height, 0)
        XCTAssertEqual(receiptsGenesis.nexusGenesisCID, NexusGenesis.expectedBlockHash)
        for node in [payments, receipts] {
            do {
                let _: MiningTemplateResponse = try await node.post(
                    "/v1/mining/templates",
                    body: MiningTemplateRequest(mode: .normal)
                )
                XCTFail("descendant issued mining work without its live parent")
            } catch let error as E2EHTTPError {
                XCTAssertEqual(error.status, 503)
            }
        }

        // A subsequent Nexus root cascades through Payments and then its
        // direct child; neither parent chooses the descendant's tip. The
        // private parent session reconnects asynchronously after Nexus comes
        // back, so require progress within bounded physical rounds rather than
        // coupling this correctness check to the first scheduler turn.
        try nexus.start()
        let restoredNexus = try await nexus.waitForStatus { status in
            status.phase == .active && status.tipCID == receiptsAnchorWork.tipCID
        }
        XCTAssertEqual(restoredNexus.height, nexusHeight)
        _ = try await payments.waitForStatus(timeout: .seconds(20)) {
            $0.phase == .active && $0.tipCID == paymentsTip
        }
        _ = try await receipts.waitForStatus(timeout: .seconds(20)) {
            $0.phase == .active && $0.tipCID == receiptsIntent.genesisCID
        }

        // Public ingress at the second hop travels through the direct parent
        // and is included by a later physical Nexus root.
        let receiptsTransaction = try legacySignedTransaction(
            chainPath: ["Nexus", "Payments", "Receipts"]
        )
        let submittedReceipts: SubmitTransactionResponse = try await receipts.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: receiptsTransaction)
        )
        let receiptsTransactionVolume = try VolumeImpl<Transaction>(
            node: receiptsTransaction
        )
        XCTAssertEqual(
            submittedReceipts.transactionCID,
            receiptsTransactionVolume.rawCID
        )
        let queuedReceipts = try await receipts.waitForStatus { $0.mempoolCount == 1 }
        XCTAssertEqual(queuedReceipts.mempoolCount, 1)
        var progressedPayments: ChainServiceStatusResponse?
        var progressedReceipts: ChainServiceStatusResponse?
        for _ in 0..<5 {
            let work = try await mine(nexus)
            XCTAssertTrue(work.accepted)
            guard work.accepted,
                  let paymentsStatus = try? await payments.waitForStatus(
                    timeout: .seconds(2),
                    where: { status in
                        status.phase == .active && (status.height ?? 0) > paymentsHeight
                    }
                  ),
                  let receiptsStatus = try? await receipts.waitForStatus(
                    timeout: .seconds(2),
                    where: { status in
                        status.phase == .active
                            && status.tipCID != receiptsIntent.genesisCID
                            && (status.height ?? 0) > (receiptsGenesis.height ?? 0)
                            && status.mempoolCount == 0
                    }
                  )
            else { continue }
            progressedPayments = paymentsStatus
            progressedReceipts = receiptsStatus
            break
        }
        let finalPayments = try XCTUnwrap(progressedPayments)
        let finalReceipts = try XCTUnwrap(progressedReceipts)
        XCTAssertNotEqual(finalPayments.tipCID, paymentsTip)
        XCTAssertNotEqual(finalReceipts.tipCID, receiptsIntent.genesisCID)
        let expectedReceiptsTransactions = try MerkleDictionaryImpl<
            VolumeImpl<Transaction>
        >().inserting(key: "0", value: receiptsTransactionVolume)
        let expectedTransactionsCID = try HeaderImpl(
            node: expectedReceiptsTransactions
        ).rawCID
        var cursor = try XCTUnwrap(finalReceipts.tipCID)
        var inclusionCount = 0
        for _ in 0..<(try XCTUnwrap(finalReceipts.height)) {
            if cursor == receiptsIntent.genesisCID { break }
            let block = try JSONDecoder().decode(
                Block.self,
                from: try await receipts.get("/v1/blocks/\(cursor)")
            )
            if block.transactions.rawCID == expectedTransactionsCID {
                inclusionCount += 1
            }
            cursor = try XCTUnwrap(block.parent?.rawCID)
        }
        XCTAssertEqual(cursor, receiptsIntent.genesisCID)
        XCTAssertEqual(inclusionCount, 1)

        try await cluster.stopAll()
        passed = true
    }

    func testNestedHardGenesisConstrainsRootSearchAndActivates() async throws {
        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        defer {
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let binary = try E2EBinary.latticeNode()
        let nexusIdentity = try workspace.makeIdentity(named: "nexus")
        let paymentsIdentity = try workspace.makeIdentity(named: "payments")
        let receiptsIdentity = try workspace.makeIdentity(named: "receipts")
        let nexusKey = try PeerKey(nexusIdentity.publicKey)
        let paymentsKey = try PeerKey(paymentsIdentity.publicKey)
        let ports = try E2EPorts.allocate(count: 9)
        let nexus = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "nexus",
            identity: nexusIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let payments = childNode(
            binary: binary,
            workspace: workspace,
            name: "payments",
            directory: "Payments",
            identity: paymentsIdentity,
            parentPublicKey: nexusKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[3],
            factPort: ports[4],
            rpcPort: ports[5]
        )
        let receipts = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "receipts",
                chainPath: "Nexus/Payments/Receipts",
                storage: workspace.url.appendingPathComponent(
                    "receipts",
                    isDirectory: true
                ),
                identity: receiptsIdentity,
                overlayPort: ports[6],
                factPort: ports[7],
                rpcPort: ports[8],
                parent: .init(
                    publicKey: paymentsKey.hex,
                    factPort: ports[4]
                )
            ),
            logDirectory: workspace.logs
        )
        cluster.add(nexus)
        cluster.add(payments)
        cluster.add(receipts)

        try nexus.start()
        try payments.start()
        _ = try await waitForNexus(nexus)
        let paymentsIntent = try await childIntent(
            on: nexus,
            directory: "Payments",
            timestamp: 1
        )
        try await submitGenesisAnchor(
            on: nexus,
            intent: paymentsIntent,
            chainPath: ["Nexus"]
        )
        let paymentsWork = try await mine(nexus, mode: .deployment)
        XCTAssertTrue(paymentsWork.accepted)
        _ = try await payments.waitForStatus {
            $0.phase == .active && $0.tipCID == paymentsIntent.genesisCID
        }

        try receipts.start()
        let hardTarget = UInt256.max / UInt256(16)
        let receiptsIntent = try await childIntent(
            on: payments,
            directory: "Receipts",
            timestamp: 2,
            target: hardTarget
        )
        try await submitGenesisAnchor(
            on: payments,
            intent: receiptsIntent,
            chainPath: ["Nexus", "Payments"]
        )

        var template: MiningTemplateResponse?
        for _ in 0..<20 {
            let next: MiningTemplateResponse = try await nexus.post(
                "/v1/mining/templates",
                body: MiningTemplateRequest(mode: .deployment)
            )
            if next.searchTarget == hardTarget {
                template = next
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let constrained = try XCTUnwrap(template)
        XCTAssertEqual(constrained.searchTarget, hardTarget)
        let rootBeforeMiss = try await nexus.waitForStatus { _ in true }
        let midstate = ProofOfWork.midstate(for: constrained.block)

        var miss: UInt64 = 0
        while ProofOfWork.hash(midstate: midstate, nonce: miss) <= hardTarget {
            miss += 1
        }
        do {
            let _: SubmitWorkResponse = try await nexus.post(
                "/v1/mining/work",
                body: SubmitWorkRequest(
                    workID: constrained.workID,
                    nonce: miss
                )
            )
            XCTFail("work missing a pending genesis target was accepted")
        } catch let error as E2EHTTPError {
            XCTAssertNotEqual(error.status, 0)
        }
        let unchanged = try await nexus.waitForStatus { _ in true }
        XCTAssertEqual(unchanged.tipCID, rootBeforeMiss.tipCID)
        XCTAssertEqual(unchanged.height, rootBeforeMiss.height)
        let stillPending = try await payments.waitForStatus { $0.mempoolCount == 1 }
        XCTAssertEqual(stillPending.mempoolCount, 1)

        var hit: UInt64 = 0
        while ProofOfWork.hash(midstate: midstate, nonce: hit) > hardTarget {
            hit += 1
        }
        let accepted: SubmitWorkResponse = try await nexus.post(
            "/v1/mining/work",
            body: SubmitWorkRequest(workID: constrained.workID, nonce: hit)
        )
        XCTAssertTrue(accepted.accepted)
        XCTAssertEqual(accepted.publishedChildProofs.map(\.directory), ["Payments"])
        _ = try await payments.waitForStatus {
            $0.phase == .active && $0.mempoolCount == 0 && ($0.height ?? 0) > 0
        }
        let activated = try await receipts.waitForStatus {
            $0.phase == .active && $0.tipCID == receiptsIntent.genesisCID
        }
        XCTAssertEqual(activated.height, 0)

        try await cluster.stopAll()
        passed = true
    }

    func testIntermediateTargetMissStillCarriesGrandchildWork() async throws {
        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        defer {
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let binary = try E2EBinary.latticeNode()
        let miner = try E2EBinary.latticeMiner()
        let nexusIdentity = try workspace.makeIdentity(named: "nexus")
        let paymentsIdentity = try workspace.makeIdentity(named: "payments")
        let receiptsIdentity = try workspace.makeIdentity(named: "receipts")
        let nexusKey = try PeerKey(nexusIdentity.publicKey)
        let paymentsKey = try PeerKey(paymentsIdentity.publicKey)
        let ports = try E2EPorts.allocate(count: 9)
        let nexus = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "nexus",
            identity: nexusIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let payments = childNode(
            binary: binary,
            workspace: workspace,
            name: "payments",
            directory: "Payments",
            identity: paymentsIdentity,
            parentPublicKey: nexusKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[3],
            factPort: ports[4],
            rpcPort: ports[5]
        )
        let receipts = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "receipts",
                chainPath: "Nexus/Payments/Receipts",
                storage: workspace.url.appendingPathComponent(
                    "receipts",
                    isDirectory: true
                ),
                identity: receiptsIdentity,
                overlayPort: ports[6],
                factPort: ports[7],
                rpcPort: ports[8],
                parent: .init(
                    publicKey: paymentsKey.hex,
                    factPort: ports[4]
                )
            ),
            logDirectory: workspace.logs
        )
        cluster.add(nexus)
        cluster.add(payments)
        cluster.add(receipts)

        try nexus.start()
        try payments.start()
        try receipts.start()
        _ = try await waitForNexus(nexus)

        let genesisTimestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let hardTarget = UInt256.max / UInt256(16)
        let paymentsIntent = try await childIntent(
            on: nexus,
            directory: "Payments",
            timestamp: genesisTimestamp,
            target: hardTarget
        )
        try await submitGenesisAnchor(
            on: nexus,
            intent: paymentsIntent,
            chainPath: ["Nexus"]
        )
        let paymentsTemplate: MiningTemplateResponse = try await nexus.post(
            "/v1/mining/templates",
            body: MiningTemplateRequest(mode: .deployment)
        )
        XCTAssertEqual(paymentsTemplate.searchTarget, hardTarget)
        let paymentsMidstate = ProofOfWork.midstate(for: paymentsTemplate.block)
        var paymentsNonce: UInt64 = 0
        while ProofOfWork.hash(midstate: paymentsMidstate, nonce: paymentsNonce)
                > hardTarget {
            paymentsNonce += 1
        }
        let paymentsDeployment: SubmitWorkResponse = try await nexus.post(
            "/v1/mining/work",
            body: SubmitWorkRequest(
                workID: paymentsTemplate.workID,
                nonce: paymentsNonce
            )
        )
        XCTAssertTrue(paymentsDeployment.accepted)
        _ = try await payments.waitForStatus {
            $0.phase == .active && $0.tipCID == paymentsIntent.genesisCID
        }

        let receiptsIntent = try await childIntent(
            on: payments,
            directory: "Receipts",
            timestamp: genesisTimestamp + 1
        )
        try await submitGenesisAnchor(
            on: payments,
            intent: receiptsIntent,
            chainPath: ["Nexus", "Payments"]
        )
        var receiptsDeployment: SubmitWorkResponse?
        for _ in 0..<20 {
            let template: MiningTemplateResponse = try await nexus.post(
                "/v1/mining/templates",
                body: MiningTemplateRequest(mode: .deployment)
            )
            guard template.searchTarget == hardTarget else {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            let midstate = ProofOfWork.midstate(for: template.block)
            var nonce: UInt64 = 0
            while ProofOfWork.hash(midstate: midstate, nonce: nonce) > hardTarget {
                nonce += 1
            }
            receiptsDeployment = try await nexus.post(
                "/v1/mining/work",
                body: SubmitWorkRequest(workID: template.workID, nonce: nonce)
            )
            break
        }
        XCTAssertTrue(try XCTUnwrap(receiptsDeployment).accepted)
        let paymentsBeforeCarrier = try await payments.waitForStatus {
            $0.phase == .active && $0.mempoolCount == 0 && ($0.height ?? 0) > 0
        }
        let receiptsBeforeCarrier = try await receipts.waitForStatus {
            $0.phase == .active && $0.tipCID == receiptsIntent.genesisCID
        }
        let paymentsTip = try XCTUnwrap(paymentsBeforeCarrier.tipCID)
        let paymentsHeight = try XCTUnwrap(paymentsBeforeCarrier.height)

        let transaction = try legacySignedTransaction(
            chainPath: ["Nexus", "Payments", "Receipts"]
        )
        let _: SubmitTransactionResponse = try await receipts.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: transaction)
        )
        _ = try await receipts.waitForStatus { $0.mempoolCount == 1 }

        // Descendant blocks are content-addressed volumes, so the public root
        // template commits to them without expanding their private bytes. The
        // configured targets give this round an observable black-box result:
        // the shared hash misses Payments but is accepted by Receipts.
        let paymentsTipBlock = try JSONDecoder().decode(
            Block.self,
            from: try await payments.get("/v1/blocks/\(paymentsTip)")
        )
        let receiptsTip = try XCTUnwrap(receiptsBeforeCarrier.tipCID)
        let receiptsTipBlock = try JSONDecoder().decode(
            Block.self,
            from: try await receipts.get("/v1/blocks/\(receiptsTip)")
        )
        let paymentsCandidateTarget = paymentsTipBlock.nextTarget
        let receiptsCandidateTarget = receiptsTipBlock.nextTarget
        let selectedTemplate: MiningTemplateResponse = try await nexus.post(
            "/v1/mining/templates",
            body: MiningTemplateRequest()
        )
        let hitCeiling = min(
            selectedTemplate.block.target,
            receiptsCandidateTarget,
            selectedTemplate.searchTarget
        )
        XCTAssertLessThan(paymentsCandidateTarget, hitCeiling)
        let carrierMidstate = ProofOfWork.midstate(for: selectedTemplate.block)
        var carrierNonce: UInt64 = 0
        var rootHash = ProofOfWork.hash(
            midstate: carrierMidstate,
            nonce: carrierNonce
        )
        while rootHash <= paymentsCandidateTarget || rootHash > hitCeiling {
            carrierNonce += 1
            rootHash = ProofOfWork.hash(
                midstate: carrierMidstate,
                nonce: carrierNonce
            )
        }
        XCTAssertEqual(selectedTemplate.searchTarget, .max)
        XCTAssertGreaterThan(rootHash, paymentsCandidateTarget)
        XCTAssertLessThanOrEqual(rootHash, hitCeiling)

        // Search the exact public template through the shipped worker, then
        // submit that worker's nonce through the public node RPC.
        let carrierWork = try await mineWithWorker(
            nexus,
            template: selectedTemplate,
            nonce: carrierNonce,
            miner: miner
        )
        XCTAssertTrue(carrierWork.accepted)
        XCTAssertEqual(carrierWork.disposition, .canonicalized)
        XCTAssertEqual(carrierWork.publishedChildProofs.map(\.directory), ["Payments"])
        let receiptsAfterCarrier = try await receipts.waitForStatus {
            $0.phase == .active
                && $0.tipCID != receiptsBeforeCarrier.tipCID
                && $0.height == receiptsBeforeCarrier.height.map { $0 + 1 }
                && $0.mempoolCount == 0
        }
        XCTAssertNotEqual(receiptsAfterCarrier.tipCID, receiptsBeforeCarrier.tipCID)
        let unchangedPayments = try await payments.waitForStatus {
            $0.tipCID == paymentsTip && $0.height == paymentsHeight
        }
        XCTAssertEqual(unchangedPayments.tipCID, paymentsTip)
        XCTAssertEqual(unchangedPayments.height, paymentsHeight)

        try await cluster.stopAll()
        passed = true
    }

    func testSamePathTransactionRelaysAndSurvivesSubmittingReplicaRestart() async throws {
        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        defer {
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let binary = try E2EBinary.latticeNode()
        let nexusIdentity = try workspace.makeIdentity(named: "relay-nexus")
        let aIdentity = try workspace.makeIdentity(named: "relay-a")
        let bIdentity = try workspace.makeIdentity(named: "relay-b")
        let nexusKey = try PeerKey(nexusIdentity.publicKey)
        let ports = try E2EPorts.allocate(count: 9)
        let nexus = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "relay-nexus",
            identity: nexusIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let a = childNode(
            binary: binary,
            workspace: workspace,
            name: "relay-a",
            directory: "Payments",
            identity: aIdentity,
            parentPublicKey: nexusKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[3],
            factPort: ports[4],
            rpcPort: ports[5]
        )
        let b = childNode(
            binary: binary,
            workspace: workspace,
            name: "relay-b",
            directory: "Payments",
            identity: bIdentity,
            parentPublicKey: nexusKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[6],
            factPort: ports[7],
            rpcPort: ports[8]
        )
        a.setOverlayPeers([try overlayPeer(identity: bIdentity, port: ports[6])])
        b.setOverlayPeers([try overlayPeer(identity: aIdentity, port: ports[3])])
        cluster.add(nexus)
        cluster.add(a)
        cluster.add(b)

        try nexus.start()
        try a.start()
        try b.start()
        _ = try await waitForNexus(nexus)
        let intent = try await childIntent(
            on: nexus,
            directory: "Payments",
            timestamp: 1
        )
        try await submitGenesisAnchor(
            on: nexus,
            intent: intent,
            chainPath: ["Nexus"]
        )
        let deployment = try await mine(nexus, mode: .deployment)
        XCTAssertTrue(deployment.accepted)
        let aGenesis = try await a.waitForStatus {
            $0.phase == .active && $0.tipCID == intent.genesisCID
        }
        _ = try await b.waitForStatus {
            $0.phase == .active && $0.tipCID == intent.genesisCID
        }

        let transaction = try legacySignedTransaction(
            chainPath: ["Nexus", "Payments"],
            keySeed: 90
        )
        let submitted: SubmitTransactionResponse = try await a.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: transaction)
        )
        XCTAssertEqual(submitted.mempoolCount, 1)
        _ = try await b.waitForStatus { $0.mempoolCount == 1 }

        // B is now the only live child candidate source. The transaction can
        // reach consensus without the process that originally accepted it.
        try await a.stop()
        var progressedB: ChainServiceStatusResponse?
        for _ in 0..<5 {
            let work = try await mine(nexus)
            XCTAssertTrue(work.accepted)
            if let status = try? await b.waitForStatus(
                timeout: .seconds(2),
                where: {
                    $0.mempoolCount == 0
                        && ($0.height ?? 0) > (aGenesis.height ?? 0)
                }
            ) {
                progressedB = status
                break
            }
        }
        let included = try XCTUnwrap(progressedB)

        // A restores its durable local transaction, learns B's accepted block,
        // and removes the now-included transaction during reconciliation.
        try a.start()
        let convergedA = try await a.waitForStatus(timeout: .seconds(20)) {
            $0.phase == .active
                && $0.tipCID == included.tipCID
                && $0.height == included.height
                && $0.mempoolCount == 0
        }
        XCTAssertEqual(convergedA.tipCID, included.tipCID)

        try await cluster.stopAll()
        passed = true
    }

    func testMalformedOverlayPeerCannotBlockHonestTransactionProgress() async throws {
        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        defer {
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let binary = try E2EBinary.latticeNode()
        let aIdentity = try workspace.makeIdentity(named: "hostile-target")
        let bIdentity = try workspace.makeIdentity(named: "honest-peer")
        let ports = try E2EPorts.allocate(count: 7)
        let aPeer = try overlayPeer(identity: aIdentity, port: ports[0])
        let bPeer = try overlayPeer(identity: bIdentity, port: ports[3])
        let a = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "hostile-target",
            identity: aIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let b = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "honest-peer",
            identity: bIdentity,
            overlayPort: ports[3],
            factPort: ports[4],
            rpcPort: ports[5]
        )
        a.setOverlayPeers([bPeer])
        b.setOverlayPeers([aPeer])
        cluster.add(a)
        cluster.add(b)

        try a.start()
        try b.start()
        _ = try await waitForNexus(a)
        _ = try await waitForNexus(b)
        let hostile = try E2EOverlayObserver(
            port: ports[6],
            bootstrapPeer: aPeer,
            hello: ChainHello(
                nexusGenesisCID: NexusGenesis.expectedBlockHash,
                chainPath: ["Nexus"],
                minimumRootWorkHex: String(repeating: "0", count: 63) + "1"
            )
        )
        addTeardownBlock { await hostile.stop() }
        try await hostile.start()
        try await hostile.waitForConnection(to: aPeer.publicKey)

        // The schema is otherwise plausible, but trailing whitespace makes the
        // recognized node message noncanonical. A must isolate it to this peer.
        let hostileSend = await hostile.send(
            topic: "lattice.overlay.transaction.available.v1",
            payload: Data("{\"volumeRootCID\":\"unavailable\"} ".utf8)
        )
        guard case .enqueued = hostileSend else {
            return XCTFail("hostile message did not reach the authenticated session")
        }
        // A later canonical request on the same ordered Ivy session must be
        // answered. This is the causal marker that the malformed frame was
        // delivered and ignored without poisoning the authenticated session.
        let inventoryRequest = try canonicalJSON(InventoryRequest(
            requestID: 7,
            afterRootCID: nil
        ))
        let markerSend = await hostile.send(
            topic: "lattice.overlay.transaction.inventory.request.v1",
            payload: inventoryRequest
        )
        guard case .enqueued = markerSend else {
            return XCTFail("causal marker was not queued on the hostile session")
        }
        try await hostile.waitForMessage(
            topic: "lattice.overlay.transaction.inventory.response.v1"
        )

        let submitted: SubmitTransactionResponse = try await b.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: try legacySignedTransaction(
                chainPath: ["Nexus"],
                keySeed: 93
            ))
        )
        XCTAssertEqual(submitted.mempoolCount, 1)
        _ = try await a.waitForStatus { $0.mempoolCount == 1 }

        let mined = try await mineBlock(a)
        XCTAssertTrue(mined.response.accepted)
        _ = try await a.waitForStatus {
            $0.tipCID == mined.blockCID && $0.mempoolCount == 0
        }
        _ = try await b.waitForStatus {
            $0.tipCID == mined.blockCID && $0.mempoolCount == 0
        }

        await hostile.stop()
        try await cluster.stopAll()
        passed = true
    }

    func testParentOutageRevokesNestedReadinessButKeepsTransactionIngress()
        async throws
    {
        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        defer {
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let binary = try E2EBinary.latticeNode()
        let nexusIdentity = try workspace.makeIdentity(named: "cascade-nexus")
        let middleIdentity = try workspace.makeIdentity(named: "cascade-middle")
        let leafIdentity = try workspace.makeIdentity(named: "cascade-leaf")
        let nexusKey = try PeerKey(nexusIdentity.publicKey)
        let middleKey = try PeerKey(middleIdentity.publicKey)
        let ports = try E2EPorts.allocate(count: 9)
        let nexus = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "cascade-nexus",
            identity: nexusIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let middle = childNode(
            binary: binary,
            workspace: workspace,
            name: "cascade-middle",
            directory: "Payments",
            identity: middleIdentity,
            parentPublicKey: nexusKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[3],
            factPort: ports[4],
            rpcPort: ports[5]
        )
        let leaf = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "cascade-leaf",
                chainPath: "Nexus/Payments/Receipts",
                storage: workspace.url.appendingPathComponent("cascade-leaf"),
                identity: leafIdentity,
                overlayPort: ports[6],
                factPort: ports[7],
                rpcPort: ports[8],
                parent: .init(publicKey: middleKey.hex, factPort: ports[4])
            ),
            logDirectory: workspace.logs
        )
        cluster.add(nexus)
        cluster.add(middle)
        cluster.add(leaf)

        try nexus.start()
        try middle.start()
        _ = try await waitForNexus(nexus)
        let middleIntent = try await childIntent(
            on: nexus,
            directory: "Payments",
            timestamp: 1
        )
        try await submitGenesisAnchor(
            on: nexus,
            intent: middleIntent,
            chainPath: ["Nexus"]
        )
        let middleDeployment = try await mine(nexus, mode: .deployment)
        XCTAssertTrue(middleDeployment.accepted)
        _ = try await middle.waitForStatus {
            $0.phase == .active && $0.tipCID == middleIntent.genesisCID
        }

        let leafIntent = try await childIntent(
            on: middle,
            directory: "Receipts",
            timestamp: 2
        )
        try await submitGenesisAnchor(
            on: middle,
            intent: leafIntent,
            chainPath: ["Nexus", "Payments"]
        )
        let leafDeployment = try await mine(nexus, mode: .deployment)
        XCTAssertTrue(leafDeployment.accepted)
        try leaf.start()
        let readyMiddle = try await middle.waitForStatus {
            $0.phase == .active
                && $0.tipCID != middleIntent.genesisCID
                && ($0.height ?? 0) > 0
        }
        let readyLeaf = try await leaf.waitForStatus {
            $0.phase == .active && $0.tipCID == leafIntent.genesisCID
        }

        // Only the root process stops. The live descendants retain verified
        // history and RPC availability but lose actionable consensus in order.
        try await nexus.stop()
        let staleMiddle = try await middle.waitForStatus {
            $0.phase == .awaitingParent && $0.tipCID == readyMiddle.tipCID
        }
        let staleLeaf = try await leaf.waitForStatus {
            $0.phase == .awaitingParent && $0.tipCID == readyLeaf.tipCID
        }
        XCTAssertEqual(staleMiddle.height, readyMiddle.height)
        XCTAssertEqual(staleLeaf.height, readyLeaf.height)

        let middleSubmission: SubmitTransactionResponse = try await middle.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: try legacySignedTransaction(
                chainPath: ["Nexus", "Payments"],
                keySeed: 91
            ))
        )
        let leafSubmission: SubmitTransactionResponse = try await leaf.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: try legacySignedTransaction(
                chainPath: ["Nexus", "Payments", "Receipts"],
                keySeed: 92
            ))
        )
        XCTAssertEqual(middleSubmission.mempoolCount, 1)
        XCTAssertEqual(leafSubmission.mempoolCount, 1)

        for node in [middle, leaf] {
            do {
                let _: MiningTemplateResponse = try await node.post(
                    "/v1/mining/templates",
                    body: MiningTemplateRequest(mode: .normal)
                )
                XCTFail("descendant issued a template without live root authority")
            } catch let error as E2EHTTPError {
                XCTAssertEqual(error.status, 503)
            }
            do {
                let _: SubmitWorkResponse = try await node.post(
                    "/v1/mining/work",
                    body: SubmitWorkRequest(workID: "unavailable", nonce: 0)
                )
                XCTFail("descendant accepted work without live root authority")
            } catch let error as E2EHTTPError {
                XCTAssertEqual(error.status, 503)
            }
        }

        try nexus.start()
        _ = try await nexus.waitForStatus { $0.phase == .active }
        let recoveredMiddle = try await middle.waitForStatus(timeout: .seconds(20)) {
            $0.phase == .active && $0.mempoolCount == 1
        }
        let recoveredLeaf = try await leaf.waitForStatus(timeout: .seconds(20)) {
            $0.phase == .active && $0.mempoolCount == 1
        }
        XCTAssertEqual(recoveredMiddle.tipCID, staleMiddle.tipCID)
        XCTAssertEqual(recoveredLeaf.tipCID, staleLeaf.tipCID)

        try await cluster.stopAll()
        passed = true
    }

    func testSameChildPathReplicasFailOverAndConverge() async throws {
        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        defer {
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let binary = try E2EBinary.latticeNode()
        let nexusIdentity = try workspace.makeIdentity(named: "nexus")
        let aIdentity = try workspace.makeIdentity(named: "payments-a")
        let bIdentity = try workspace.makeIdentity(named: "payments-b")
        let nexusKey = try PeerKey(nexusIdentity.publicKey)
        let ports = try E2EPorts.allocate(count: 9)
        let nexus = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "nexus",
            identity: nexusIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let a = childNode(
            binary: binary,
            workspace: workspace,
            name: "payments-a",
            directory: "Payments",
            identity: aIdentity,
            parentPublicKey: nexusKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[3],
            factPort: ports[4],
            rpcPort: ports[5]
        )
        let b = childNode(
            binary: binary,
            workspace: workspace,
            name: "payments-b",
            directory: "Payments",
            identity: bIdentity,
            parentPublicKey: nexusKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[6],
            factPort: ports[7],
            rpcPort: ports[8]
        )
        a.setOverlayPeers([try overlayPeer(identity: bIdentity, port: ports[6])])
        b.setOverlayPeers([try overlayPeer(identity: aIdentity, port: ports[3])])
        cluster.add(nexus)
        cluster.add(a)
        cluster.add(b)

        try nexus.start()
        try a.start()
        try b.start()
        _ = try await waitForNexus(nexus)
        let intent = try await childIntent(
            on: nexus,
            directory: "Payments",
            timestamp: 1
        )
        try await submitGenesisAnchor(
            on: nexus,
            intent: intent,
            chainPath: ["Nexus"]
        )
        let deployment = try await mine(nexus, mode: .deployment)
        XCTAssertTrue(deployment.accepted)
        let aGenesis = try await a.waitForStatus {
            $0.phase == .active && $0.tipCID == intent.genesisCID
        }
        let bGenesis = try await b.waitForStatus {
            $0.phase == .active && $0.tipCID == intent.genesisCID
        }
        XCTAssertEqual(aGenesis.tipCID, bGenesis.tipCID)

        try await a.stop()
        let _: SubmitTransactionResponse = try await b.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: try legacySignedTransaction(
                chainPath: ["Nexus", "Payments"]
            ))
        )
        var bProgress: ChainServiceStatusResponse?
        for _ in 0..<5 {
            let work = try await mine(nexus)
            XCTAssertTrue(work.accepted)
            if let status = try? await b.waitForStatus(
                timeout: .seconds(2),
                where: {
                    $0.mempoolCount == 0
                        && ($0.height ?? 0) > (bGenesis.height ?? 0)
                }
            ) {
                bProgress = status
                break
            }
        }
        let firstTip = try XCTUnwrap(bProgress)

        try a.start()
        let caughtUpA = try await a.waitForStatus {
            $0.tipCID == firstTip.tipCID && $0.height == firstTip.height
        }
        XCTAssertEqual(caughtUpA.tipCID, firstTip.tipCID)

        try await b.stop()
        let _: SubmitTransactionResponse = try await a.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: try legacySignedTransaction(
                chainPath: ["Nexus", "Payments"]
            ))
        )
        var aProgress: ChainServiceStatusResponse?
        for _ in 0..<5 {
            let work = try await mine(nexus)
            XCTAssertTrue(work.accepted)
            if let status = try? await a.waitForStatus(
                timeout: .seconds(2),
                where: {
                    $0.mempoolCount == 0
                        && ($0.height ?? 0) > (firstTip.height ?? 0)
                }
            ) {
                aProgress = status
                break
            }
        }
        let secondTip = try XCTUnwrap(aProgress)

        try b.start()
        let caughtUpB = try await b.waitForStatus {
            $0.tipCID == secondTip.tipCID && $0.height == secondTip.height
        }
        XCTAssertEqual(caughtUpB.tipCID, secondTip.tipCID)

        try await cluster.stopAll()
        passed = true
    }

    func testPureParentDescendantsDoNotReweightChildAfterPartitionHeal()
        async throws
    {
        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        defer {
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let binary = try E2EBinary.latticeNode()
        let parentIdentity = try workspace.makeIdentity(named: "parent")
        let forkIdentity = try workspace.makeIdentity(named: "canonical-fork")
        let sideIdentity = try workspace.makeIdentity(named: "side-fork")
        let childIdentity = try workspace.makeIdentity(named: "payments")
        let laggingIdentity = try workspace.makeIdentity(named: "payments-lagging")
        let parentKey = try PeerKey(parentIdentity.publicKey)
        let ports = try E2EPorts.allocate(count: 16)
        let parentPeer = try overlayPeer(identity: parentIdentity, port: ports[0])
        let parent = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "parent",
            identity: parentIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let fork = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "canonical-fork",
            identity: forkIdentity,
            overlayPort: ports[3],
            factPort: ports[4],
            rpcPort: ports[5]
        )
        let side = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "side-fork",
            identity: sideIdentity,
            overlayPort: ports[6],
            factPort: ports[7],
            rpcPort: ports[8]
        )
        let child = childNode(
            binary: binary,
            workspace: workspace,
            name: "payments",
            directory: "Payments",
            identity: childIdentity,
            parentPublicKey: parentKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[9],
            factPort: ports[10],
            rpcPort: ports[11]
        )
        let lagging = childNode(
            binary: binary,
            workspace: workspace,
            name: "payments-lagging",
            directory: "Payments",
            identity: laggingIdentity,
            parentPublicKey: parentKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[12],
            factPort: ports[13],
            rpcPort: ports[14]
        )
        cluster.add(parent)
        cluster.add(fork)
        cluster.add(side)
        cluster.add(child)
        cluster.add(lagging)

        try parent.start()
        try fork.start()
        try child.start()
        try lagging.start()
        _ = try await waitForNexus(parent)
        _ = try await waitForNexus(fork)
        _ = try await child.waitForStatus {
            $0.phase == .awaitingGenesis && $0.tipCID == nil
        }
        _ = try await lagging.waitForStatus {
            $0.phase == .awaitingGenesis && $0.tipCID == nil
        }

        // Q is a three-grind Nexus branch prepared behind a real partition.
        // None of its prefix work covers a Payments block.
        let q1 = try await mineBlock(fork)
        let q2 = try await mineBlock(fork)
        let q3 = try await mineBlock(fork)
        XCTAssertEqual(
            q1.template.block.parent?.rawCID,
            NexusGenesis.expectedBlockHash
        )
        XCTAssertEqual(q2.template.block.parent?.rawCID, q1.blockCID)
        XCTAssertEqual(q3.template.block.parent?.rawCID, q2.blockCID)

        // P1 introduces child genesis A on the competing Nexus branch. The
        // child activates from accepted evidence, not a parent tip command.
        let aIntent = try await childIntent(
            on: parent,
            directory: "Payments",
            timestamp: 1
        )
        try await submitGenesisAnchor(
            on: parent,
            intent: aIntent,
            chainPath: ["Nexus"]
        )
        let p1 = try await mineBlock(parent, mode: .deployment)
        XCTAssertTrue(p1.response.accepted)
        XCTAssertEqual(
            p1.template.block.parent?.rawCID,
            NexusGenesis.expectedBlockHash
        )
        _ = try await child.waitForStatus {
            $0.phase == .active && $0.tipCID == aIntent.genesisCID
        }
        _ = try await waitForTip(lagging, aIntent.genesisCID)

        // S retains the exact P1 branch before Q is revealed. It later adds
        // work below P1 while that Nexus branch is noncanonical.
        side.setOverlayPeers([
            try overlayPeer(identity: parentIdentity, port: ports[0])
        ])
        try side.start()
        _ = try await waitForTip(side, p1.blockCID)
        try await side.stop()
        side.setOverlayPeers([])

        // Healing Q changes only Nexus canonicity. The sole Payments root A
        // remains canonical because parent canonicity is not child weight.
        try await fork.stop()
        fork.setOverlayPeers([
            try overlayPeer(identity: parentIdentity, port: ports[0])
        ])
        try fork.start()
        _ = try await waitForTip(parent, q3.blockCID)
        _ = try await waitForTip(child, aIntent.genesisCID)
        _ = try await waitForTip(lagging, aIntent.genesisCID)
        try await fork.stop()

        // Q has no Payments entry, so it can introduce a distinct genesis B
        // for the same absolute child path. Freeze the live child only across
        // the parent candidate deadline so Q4 cannot also include A. The
        // process itself never restarts: its later A -> B move must come from
        // the live parent-work delta. Keep the lagging replica offline for the
        // independent reconnect/full-snapshot assertion.
        try child.suspend()
        try await lagging.stop()
        let bIntent = try await childIntent(
            on: parent,
            directory: "Payments",
            timestamp: 2,
            target: UInt256.max / UInt256(2)
        )
        XCTAssertNotEqual(aIntent.genesisCID, bIntent.genesisCID)
        try await submitGenesisAnchor(
            on: parent,
            intent: bIntent,
            chainPath: ["Nexus"]
        )
        let q4 = try await mineBlock(
            parent,
            mode: .deployment,
            requestTimeout: 60
        )
        XCTAssertEqual(q4.template.block.parent?.rawCID, q3.blockCID)
        try child.resume()

        let aInitialWork = WorkSum(max(
            workForTarget(p1.template.block.target),
            workForTarget(aIntent.genesisBlock.target)
        ))
        let bWork = WorkSum(max(
            workForTarget(q4.template.block.target),
            workForTarget(bIntent.genesisBlock.target)
        ))
        XCTAssertGreaterThan(bWork, aInitialWork)

        _ = try await waitForTip(child, bIntent.genesisCID)
        try lagging.start()
        _ = try await waitForTip(lagging, bIntent.genesisCID)
        try await lagging.stop()

        // P2 and P3 descend from A's carrier but do not directly commit to a
        // Payments block. Accepting them must not assign their grinds to A.
        try side.start()
        _ = try await waitForTip(side, p1.blockCID)
        let p2 = try await mineBlock(side)
        let p3 = try await mineBlock(side)
        XCTAssertEqual(p2.template.block.parent?.rawCID, p1.blockCID)
        XCTAssertEqual(p3.template.block.parent?.rawCID, p2.blockCID)
        try await side.stop()
        let observer = try E2EOverlayObserver(
            port: ports[15],
            bootstrapPeer: parentPeer,
            hello: ChainHello(
                nexusGenesisCID: NexusGenesis.expectedBlockHash,
                chainPath: ["Nexus"],
                minimumRootWorkHex: String(repeating: "0", count: 63) + "1"
            )
        )
        addTeardownBlock { await observer.stop() }
        try await observer.start()
        try await observer.waitForConnection(to: parentPeer.publicKey)
        let p3Announcements = await observer.announcementCount(of: p3.blockCID)
        side.setOverlayPeers([
            parentPeer
        ])
        try side.start()
        try await observer.waitForAnnouncement(
            of: p3.blockCID,
            after: p3Announcements
        )
        let acceptedParent = try await parent.waitForStatus { _ in true }
        let acceptedParentRevision = try XCTUnwrap(acceptedParent.revision)
        _ = try await child.waitForStatus {
            ($0.parentWorkRevision ?? 0) >= acceptedParentRevision
        }

        XCTAssertGreaterThan(bWork, aInitialWork)
        let pRootWork = WorkSum(workForTarget(p1.template.block.target))
            + WorkSum(workForTarget(p2.template.block.target))
            + WorkSum(workForTarget(p3.template.block.target))
        let qRootWork = WorkSum(workForTarget(q1.template.block.target))
            + WorkSum(workForTarget(q2.template.block.target))
            + WorkSum(workForTarget(q3.template.block.target))
            + WorkSum(workForTarget(q4.template.block.target))
        XCTAssertGreaterThan(qRootWork, pRootWork)

        _ = try await waitForTip(child, bIntent.genesisCID)
        try lagging.start()
        _ = try await waitForTip(lagging, bIntent.genesisCID)
        let unchangedParent = try await parent.waitForStatus { _ in true }
        XCTAssertEqual(unchangedParent.tipCID, q4.blockCID)
        XCTAssertNotEqual(unchangedParent.tipCID, p3.blockCID)
        await observer.stop()
        try await lagging.stop()

        // Recovery owns the same projection without either branch source.
        try await side.stop()
        child.forceTerminate()
        parent.forceTerminate()
        try parent.start()
        try child.start()
        _ = try await waitForTip(parent, q4.blockCID)
        _ = try await waitForTip(child, bIntent.genesisCID)

        try await cluster.stopAll()
        passed = true
    }

    func testPureAncestorDescendantsDoNotReweightNestedChildren()
        async throws
    {
        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        defer {
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let binary = try E2EBinary.latticeNode()
        let parentIdentity = try workspace.makeIdentity(named: "parent")
        let forkIdentity = try workspace.makeIdentity(named: "canonical-fork")
        let sideIdentity = try workspace.makeIdentity(named: "side-fork")
        let middleIdentity = try workspace.makeIdentity(named: "payments")
        let leafIdentity = try workspace.makeIdentity(named: "receipts")
        let lateLeafIdentity = try workspace.makeIdentity(named: "receipts-late")
        let parentKey = try PeerKey(parentIdentity.publicKey)
        let middleKey = try PeerKey(middleIdentity.publicKey)
        let ports = try E2EPorts.allocate(count: 19)
        let parentPeer = try overlayPeer(identity: parentIdentity, port: ports[0])
        let parent = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "parent",
            identity: parentIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let fork = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "canonical-fork",
            identity: forkIdentity,
            overlayPort: ports[3],
            factPort: ports[4],
            rpcPort: ports[5]
        )
        let side = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "side-fork",
            identity: sideIdentity,
            overlayPort: ports[6],
            factPort: ports[7],
            rpcPort: ports[8]
        )
        let middle = childNode(
            binary: binary,
            workspace: workspace,
            name: "payments",
            directory: "Payments",
            identity: middleIdentity,
            parentPublicKey: parentKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[9],
            factPort: ports[10],
            rpcPort: ports[11]
        )
        let leaf = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "receipts",
                chainPath: "Nexus/Payments/Receipts",
                storage: workspace.url.appendingPathComponent(
                    "receipts",
                    isDirectory: true
                ),
                identity: leafIdentity,
                overlayPort: ports[12],
                factPort: ports[13],
                rpcPort: ports[14],
                parent: .init(publicKey: middleKey.hex, factPort: ports[10])
            ),
            logDirectory: workspace.logs
        )
        let lateLeaf = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "receipts-late",
                chainPath: "Nexus/Payments/Receipts",
                storage: workspace.url.appendingPathComponent(
                    "receipts-late",
                    isDirectory: true
                ),
                identity: lateLeafIdentity,
                overlayPort: ports[15],
                factPort: ports[16],
                rpcPort: ports[17],
                parent: .init(publicKey: middleKey.hex, factPort: ports[10])
            ),
            logDirectory: workspace.logs
        )
        for node in [parent, fork, side, middle, leaf, lateLeaf] {
            cluster.add(node)
        }

        try parent.start()
        try fork.start()
        try middle.start()
        try leaf.start()
        _ = try await waitForNexus(parent)
        _ = try await waitForNexus(fork)
        _ = try await middle.waitForStatus { $0.phase == .awaitingGenesis }
        _ = try await leaf.waitForStatus { $0.phase == .awaitingGenesis }

        // Five ordinary blocks give Q enough root-only work to remain Nexus'
        // canonical branch after all four later P-side grinds arrive.
        var qTip = NexusGenesis.expectedBlockHash
        for _ in 0..<5 {
            let block = try await mineBlock(fork)
            XCTAssertEqual(block.template.block.parent?.rawCID, qTip)
            qTip = block.blockCID
        }

        // On P, Payments A contributes two work per physical root. Receipts A
        // contributes three on the second root while its middle branch starts
        // at four.
        let middleATarget = UInt256.max / UInt256(2)
        let leafATarget = UInt256.max / UInt256(3)
        XCTAssertEqual(workForTarget(middleATarget), UInt256(2))
        XCTAssertEqual(workForTarget(leafATarget), UInt256(3))
        let middleA = try await childIntent(
            on: parent,
            directory: "Payments",
            timestamp: 1,
            target: middleATarget
        )
        try await submitGenesisAnchor(
            on: parent,
            intent: middleA,
            chainPath: ["Nexus"]
        )
        let p1 = try await mineBlock(parent, mode: .deployment)
        _ = try await waitForTip(middle, middleA.genesisCID)

        let leafA = try await childIntent(
            on: middle,
            directory: "Receipts",
            timestamp: 2,
            target: leafATarget
        )
        try await submitGenesisAnchor(
            on: middle,
            intent: leafA,
            chainPath: ["Nexus", "Payments"]
        )
        let p2 = try await mineBlock(parent, mode: .deployment)
        XCTAssertEqual(p2.template.block.parent?.rawCID, p1.blockCID)
        _ = try await waitForTip(leaf, leafA.genesisCID)

        // Preserve P behind a real partition before Q is revealed.
        side.setOverlayPeers([parentPeer])
        try side.start()
        _ = try await waitForTip(side, p2.blockCID)
        try await side.stop()
        side.setOverlayPeers([])

        try await fork.stop()
        fork.setOverlayPeers([parentPeer])
        try fork.start()
        _ = try await waitForTip(parent, qTip)
        try await fork.stop()

        // Payments B contributes five on both of its physical roots. It
        // therefore becomes the middle tip with weight ten. Its Receipts base
        // sees only the second root and starts at six, ahead of Receipts A's
        // three.
        try await leaf.stop()
        try await middle.stop()
        let middleBTarget = UInt256.max / UInt256(5)
        XCTAssertEqual(workForTarget(middleBTarget), UInt256(5))
        let middleB = try await childIntent(
            on: parent,
            directory: "Payments",
            timestamp: 3,
            target: middleBTarget
        )
        try await submitGenesisAnchor(
            on: parent,
            intent: middleB,
            chainPath: ["Nexus"]
        )
        let qCarrier = try await mineBlock(parent, mode: .deployment)
        XCTAssertEqual(qCarrier.template.block.parent?.rawCID, qTip)

        try middle.start()
        _ = try await waitForTip(middle, middleB.genesisCID)
        try leaf.start()
        _ = try await waitForTip(leaf, leafA.genesisCID)
        let leafBTarget = UInt256.max / UInt256(6)
        XCTAssertEqual(workForTarget(leafBTarget), UInt256(6))
        let leafB = try await childIntent(
            on: middle,
            directory: "Receipts",
            timestamp: 4,
            target: leafBTarget
        )
        try await submitGenesisAnchor(
            on: middle,
            intent: leafB,
            chainPath: ["Nexus", "Payments"]
        )
        let qLeafCarrier = try await mineBlock(parent, mode: .deployment)
        XCTAssertEqual(qLeafCarrier.template.block.parent?.rawCID, qCarrier.blockCID)
        let middleBStatus = try await middle.waitForStatus {
            $0.tipCID != middleB.genesisCID && $0.height == 1
        }
        let middleBTip = try XCTUnwrap(middleBStatus.tipCID)
        _ = try await waitForTip(leaf, leafB.genesisCID)

        // Four pure Nexus descendants extend P but contain no direct Payments
        // or Receipts commitments. They must reweight neither descendant.
        try side.start()
        _ = try await waitForTip(side, p2.blockCID)
        var pTip = p2.blockCID
        for _ in 0..<4 {
            let block = try await mineBlock(side)
            XCTAssertEqual(block.template.block.parent?.rawCID, pTip)
            pTip = block.blockCID
        }
        try await side.stop()
        let observer = try E2EOverlayObserver(
            port: ports[18],
            bootstrapPeer: parentPeer,
            hello: ChainHello(
                nexusGenesisCID: NexusGenesis.expectedBlockHash,
                chainPath: ["Nexus"],
                minimumRootWorkHex: String(repeating: "0", count: 63) + "1"
            )
        )
        addTeardownBlock { await observer.stop() }
        try await observer.start()
        try await observer.waitForConnection(to: parentPeer.publicKey)
        let pTipAnnouncements = await observer.announcementCount(of: pTip)
        side.setOverlayPeers([parentPeer])
        try side.start()
        try await observer.waitForAnnouncement(
            of: pTip,
            after: pTipAnnouncements
        )
        let acceptedParent = try await parent.waitForStatus { _ in true }
        let acceptedParentRevision = try XCTUnwrap(acceptedParent.revision)
        _ = try await middle.waitForStatus {
            ($0.parentWorkRevision ?? 0) >= acceptedParentRevision
        }

        _ = try await waitForTip(leaf, leafB.genesisCID)
        let unchangedMiddle = try await middle.waitForStatus { _ in true }
        XCTAssertEqual(unchangedMiddle.tipCID, middleBTip)
        let unchangedParent = try await parent.waitForStatus { _ in true }
        XCTAssertEqual(unchangedParent.tipCID, qLeafCarrier.blockCID)
        XCTAssertNotEqual(unchangedParent.tipCID, pTip)
        await observer.stop()

        // A fresh leaf and crash-restarted hierarchy must independently derive
        // the same split decision from durable parent facts.
        try lateLeaf.start()
        _ = try await waitForTip(lateLeaf, leafB.genesisCID)
        try await side.stop()
        lateLeaf.forceTerminate()
        leaf.forceTerminate()
        middle.forceTerminate()
        parent.forceTerminate()
        try parent.start()
        try middle.start()
        try leaf.start()
        try lateLeaf.start()
        _ = try await waitForTip(parent, qLeafCarrier.blockCID)
        _ = try await waitForTip(middle, middleBTip)
        _ = try await waitForTip(leaf, leafB.genesisCID)
        _ = try await waitForTip(lateLeaf, leafB.genesisCID)

        try await cluster.stopAll()
        passed = true
    }

    func testStoppedDirectChildDoesNotBlockHealthySiblingRound() async throws {
        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        defer {
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let binary = try E2EBinary.latticeNode()
        let nexusIdentity = try workspace.makeIdentity(named: "nexus")
        let nexusPeerKey = try PeerKey(nexusIdentity.publicKey)
        let healthyIdentity = try workspace.makeIdentity(named: "healthy")
        let stoppedIdentity = try workspace.makeIdentity(named: "stopped")
        let ports = try E2EPorts.allocate(count: 9)

        let nexus = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "nexus",
            identity: nexusIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let healthy = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "healthy",
                chainPath: "Nexus/Healthy",
                storage: workspace.url.appendingPathComponent(
                    "healthy",
                    isDirectory: true
                ),
                identity: healthyIdentity,
                overlayPort: ports[3],
                factPort: ports[4],
                rpcPort: ports[5],
                parent: .init(publicKey: nexusPeerKey.hex, factPort: ports[1])
            ),
            logDirectory: workspace.logs
        )
        let stopped = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "stopped",
                chainPath: "Nexus/Stopped",
                storage: workspace.url.appendingPathComponent(
                    "stopped",
                    isDirectory: true
                ),
                identity: stoppedIdentity,
                overlayPort: ports[6],
                factPort: ports[7],
                rpcPort: ports[8],
                parent: .init(publicKey: nexusPeerKey.hex, factPort: ports[1])
            ),
            logDirectory: workspace.logs
        )
        cluster.add(nexus)
        cluster.add(healthy)
        cluster.add(stopped)

        try nexus.start()
        _ = try await waitForNexus(nexus)

        let healthyIntent = try await childIntent(
            on: nexus,
            directory: "Healthy",
            timestamp: 1
        )
        let stoppedIntent = try await childIntent(
            on: nexus,
            directory: "Stopped",
            timestamp: 2
        )
        let nexusAuthority = try XCTUnwrap(
            ParentWorkAuthorityKey(nexus.processPublicKey)
        )
        let anchor = try legacySignedTransaction(
            chainPath: ["Nexus"],
            genesisActions: [
                GenesisAction(
                    directory: healthyIntent.directory,
                    blockCID: healthyIntent.genesisCID,
                    parentWorkAuthorityKey: nexusAuthority
                ),
                GenesisAction(
                    directory: stoppedIntent.directory,
                    blockCID: stoppedIntent.genesisCID,
                    parentWorkAuthorityKey: nexusAuthority
                ),
            ]
        )
        let _: SubmitTransactionResponse = try await nexus.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: anchor)
        )
        let deployment = try await mine(nexus, mode: .deployment)
        XCTAssertTrue(deployment.accepted)

        try healthy.start()
        try stopped.start()
        let healthyGenesis = try await healthy.waitForStatus { status in
            status.phase == .active && status.tipCID == healthyIntent.genesisCID
        }
        let stoppedGenesis = try await stopped.waitForStatus { status in
            status.phase == .active && status.tipCID == stoppedIntent.genesisCID
        }
        XCTAssertEqual(healthyGenesis.height, 0)
        XCTAssertEqual(stoppedGenesis.height, 0)

        // Both real child daemons must first answer a live contextual request.
        // That distinguishes the later SIGSTOP from an unissued or merely
        // configured sibling.
        let _: SubmitTransactionResponse = try await healthy.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(
                transaction: try legacySignedTransaction(chainPath: ["Nexus", "Healthy"])
            )
        )
        var warmedHealthy: ChainServiceStatusResponse?
        var warmedStopped: ChainServiceStatusResponse?
        for _ in 0..<5 {
            let work = try await mine(nexus)
            XCTAssertTrue(work.accepted)
            guard
                let healthyStatus = try? await healthy.waitForStatus(
                    timeout: .seconds(2),
                    where: { status in
                        status.phase == .active
                            && (status.height ?? 0) > 0
                            && status.mempoolCount == 0
                    }
                ),
                let stoppedStatus = try? await stopped.waitForStatus(
                    timeout: .seconds(2),
                    where: { status in
                        status.phase == .active && (status.height ?? 0) > 0
                    }
                )
            else { continue }
            warmedHealthy = healthyStatus
            warmedStopped = stoppedStatus
            break
        }
        let healthyBeforeStop = try XCTUnwrap(warmedHealthy)
        let stoppedBeforeStop = try XCTUnwrap(warmedStopped)
        let healthyHeight = try XCTUnwrap(healthyBeforeStop.height)
        let stoppedTip = try XCTUnwrap(stoppedBeforeStop.tipCID)
        let stoppedHeight = try XCTUnwrap(stoppedBeforeStop.height)

        // SIGSTOP preserves the authenticated private-Ivy session but prevents
        // this direct child from replying. Nexus must omit it at its bounded
        // deadline and still carry the healthy sibling in the next root.
        try stopped.suspend()
        let _: SubmitTransactionResponse = try await healthy.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(
                transaction: try legacySignedTransaction(chainPath: ["Nexus", "Healthy"])
            )
        )
        _ = try await healthy.waitForStatus { $0.mempoolCount == 1 }
        let template: MiningTemplateResponse = try await nexus.post(
            "/v1/mining/templates",
            body: MiningTemplateRequest(),
            timeout: 20
        )
        let work: SubmitWorkResponse = try await nexus.post(
            "/v1/mining/work",
            body: SubmitWorkRequest(workID: template.workID, nonce: 0)
        )
        XCTAssertTrue(work.accepted)
        let healthyAfterStop = try await healthy.waitForStatus { status in
            status.phase == .active
                && (status.height ?? 0) > healthyHeight
                && status.mempoolCount == 0
        }
        XCTAssertNotEqual(healthyAfterStop.tipCID, healthyBeforeStop.tipCID)

        // The stopped child reopens its pre-stop durable projection. Its
        // hierarchy recovery remains independent from healthy sibling progress.
        stopped.forceTerminate()
        try stopped.start()
        let recoveredStopped = try await stopped.waitForStatus { status in
            status.phase == .active && status.tipCID == stoppedTip
        }
        XCTAssertEqual(recoveredStopped.height, stoppedHeight)

        try await cluster.stopAll()
        passed = true
    }

    func testFreshChildBootstrapsFromDurableParentSideBranchAfterReorg() async throws {
        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        defer {
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let binary = try E2EBinary.latticeNode()
        let parentIdentity = try workspace.makeIdentity(named: "parent")
        let parentPeerKey = try PeerKey(parentIdentity.publicKey)
        let forkIdentity = try workspace.makeIdentity(named: "fork")
        let childIdentity = try workspace.makeIdentity(named: "child")
        let ports = try E2EPorts.allocate(count: 9)
        let forkPeer = try overlayPeer(identity: forkIdentity, port: ports[3])

        let parent = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "parent",
            identity: parentIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let fork = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "fork",
            identity: forkIdentity,
            overlayPort: ports[3],
            factPort: ports[4],
            rpcPort: ports[5]
        )
        let child = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "child",
                chainPath: "Nexus/Payments",
                storage: workspace.url.appendingPathComponent("child", isDirectory: true),
                identity: childIdentity,
                overlayPort: ports[6],
                factPort: ports[7],
                rpcPort: ports[8],
                parent: .init(publicKey: parentPeerKey.hex, factPort: ports[1])
            ),
            logDirectory: workspace.logs
        )
        cluster.add(parent)
        cluster.add(fork)
        cluster.add(child)

        try parent.start()
        try fork.start()
        _ = try await waitForNexus(parent)
        _ = try await waitForNexus(fork)

        let intent = try await childIntent(
            on: parent,
            directory: "Payments",
            timestamp: 1
        )
        try await submitLegacyGenesisAnchor(
            on: parent,
            intent: intent,
            chainPath: ["Nexus"]
        )
        let parentCarrier = try await mineBlock(parent, mode: .deployment)
        XCTAssertTrue(parentCarrier.response.accepted)
        XCTAssertEqual(parentCarrier.response.tipCID, parentCarrier.blockCID)
        XCTAssertEqual(
            parentCarrier.template.block.parent?.rawCID,
            NexusGenesis.expectedBlockHash
        )

        // The fork is created independently before either process has an
        // overlay edge, so it has no route to a Payments candidate.
        let forkOne = try await mineBlock(fork)
        let forkTwo = try await mineBlock(fork)
        XCTAssertTrue(forkOne.response.accepted)
        XCTAssertTrue(forkTwo.response.accepted)
        XCTAssertEqual(forkOne.template.block.parent?.rawCID, NexusGenesis.expectedBlockHash)
        XCTAssertEqual(forkTwo.template.block.parent?.rawCID, forkOne.blockCID)
        _ = try await waitForTip(fork, forkTwo.blockCID)
        let parentWork = WorkSum(workForTarget(parentCarrier.template.block.target))
        let forkWork = WorkSum(workForTarget(forkOne.template.block.target))
            + WorkSum(workForTarget(forkTwo.template.block.target))
        XCTAssertGreaterThan(forkWork, parentWork)

        // The direct parent retains the accepted Payments proof even after its
        // canonical pointer moves to the independently mined fork.
        try await parent.stop()
        parent.setOverlayPeers([forkPeer])
        try parent.start()
        _ = try await waitForTip(parent, forkTwo.blockCID)
        try await fork.stop()
        parent.forceTerminate()
        parent.setOverlayPeers([])
        try parent.start()
        _ = try await waitForTip(parent, forkTwo.blockCID)

        // A new child has no overlay peer and the parent's canonical fork has
        // no Payments block. Activation can therefore only use the parent's
        // durable proof and genesis link for the accepted side branch above.
        try child.start()
        let activated = try await child.waitForStatus { status in
            status.phase == .active && status.tipCID == intent.genesisCID
        }
        XCTAssertEqual(activated.chainPath, ["Nexus", "Payments"])
        XCTAssertEqual(activated.nexusGenesisCID, NexusGenesis.expectedBlockHash)
        XCTAssertEqual(activated.height, 0)
        _ = try await waitForTip(parent, forkTwo.blockCID)

        try await parent.stop()
        child.forceTerminate()
        try child.start()
        let staleChild = try await child.waitForStatus { status in
            status.phase == .awaitingParent
                && status.tipCID == intent.genesisCID
        }
        XCTAssertEqual(staleChild.height, 0)
        do {
            let _: MiningTemplateResponse = try await child.post(
                "/v1/mining/templates",
                body: MiningTemplateRequest(mode: .normal)
            )
            XCTFail("child issued mining work without its live parent")
        } catch let error as E2EHTTPError {
            XCTAssertEqual(error.status, 503)
        }

        try parent.start()
        _ = try await parent.waitForStatus { $0.phase == .active }
        let recoveredChild = try await child.waitForStatus { status in
            status.phase == .active && status.tipCID == intent.genesisCID
        }
        XCTAssertEqual(recoveredChild.height, 0)

        try await cluster.stopAll()
        passed = true
    }

    func testSamePathReplicaReorgsTieFromLosingSegmentBase() async throws {
        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        defer {
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let binary = try E2EBinary.latticeNode()
        let aIdentity = try workspace.makeIdentity(named: "a")
        let bIdentity = try workspace.makeIdentity(named: "b")
        let cIdentity = try workspace.makeIdentity(named: "c")
        let dIdentity = try workspace.makeIdentity(named: "d")
        let ports = try E2EPorts.allocate(count: 13)
        let aPeer = try overlayPeer(identity: aIdentity, port: ports[0])
        let bPeer = try overlayPeer(identity: bIdentity, port: ports[3])
        let cPeer = try overlayPeer(identity: cIdentity, port: ports[6])
        let dPeer = try overlayPeer(identity: dIdentity, port: ports[9])

        let a = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "a",
            identity: aIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let b = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "b",
            identity: bIdentity,
            overlayPort: ports[3],
            factPort: ports[4],
            rpcPort: ports[5]
        )
        let c = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "c",
            identity: cIdentity,
            overlayPort: ports[6],
            factPort: ports[7],
            rpcPort: ports[8]
        )
        let d = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "d",
            identity: dIdentity,
            overlayPort: ports[9],
            factPort: ports[10],
            rpcPort: ports[11]
        )
        cluster.add(a)
        cluster.add(b)
        cluster.add(c)
        cluster.add(d)

        try a.start()
        try b.start()
        _ = try await waitForNexus(a)
        _ = try await waitForNexus(b)

        // Distinct signed transactions make the sibling segment bases distinct
        // without relying on wall-clock timing.
        let _: SubmitTransactionResponse = try await a.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(
                transaction: try legacySignedTransaction(chainPath: ["Nexus"])
            )
        )
        let _: SubmitTransactionResponse = try await b.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(
                transaction: try legacySignedTransaction(chainPath: ["Nexus"])
            )
        )
        let a1 = try await mineBlock(a)
        let b1 = try await mineBlock(b)
        XCTAssertTrue(a1.response.accepted)
        XCTAssertTrue(b1.response.accepted)
        XCTAssertEqual(a1.response.tipCID, a1.blockCID)
        XCTAssertEqual(b1.response.tipCID, b1.blockCID)
        XCTAssertEqual(a1.template.block.parent?.rawCID, NexusGenesis.expectedBlockHash)
        XCTAssertEqual(b1.template.block.parent?.rawCID, NexusGenesis.expectedBlockHash)
        XCTAssertNotEqual(a1.blockCID, b1.blockCID)
        XCTAssertEqual(a1.template.block.target, b1.template.block.target)
        XCTAssertEqual(
            WorkSum(workForTarget(a1.template.block.target)),
            WorkSum(workForTarget(b1.template.block.target))
        )

        // These one-block sibling CIDs are segment bases. The oracle is the
        // Lattice comparator itself, never textual CID ordering.
        let winnerCID = forkChoicePrefersSegmentBase(
            a1.blockCID,
            over: b1.blockCID
        ) ? a1.blockCID : b1.blockCID
        let loserCID = winnerCID == a1.blockCID ? b1.blockCID : a1.blockCID
        let winnerPeer = winnerCID == a1.blockCID ? aPeer : bPeer
        let loserPeer = loserCID == a1.blockCID ? aPeer : bPeer
        let winner = winnerCID == a1.blockCID ? a : b
        let loser = loserCID == a1.blockCID ? a : b

        // D seals the winner before it has any route to the loser. It stays
        // offline while C exercises the opposite arrival order below.
        d.setOverlayPeers([winnerPeer])
        try d.start()
        _ = try await waitForTip(d, winnerCID)
        try await d.stop()

        // C sees the losing branch first, then proves that its recovered
        // accepted loser survives after disconnecting from that source. The
        // winner can therefore be admitted into a live process that already
        // has the competing branch, without contaminating the loser source.
        c.setOverlayPeers([loserPeer])
        try c.start()
        _ = try await waitForTip(c, loserCID)
        try await c.stop()
        c.setOverlayPeers([])
        try c.start()
        _ = try await waitForTip(c, loserCID)
        try await winner.stop()
        winner.setOverlayPeers([cPeer])
        try winner.start()
        _ = try await waitForTip(c, winnerCID)

        // Stop every source that could now relay the loser through C. D opens
        // only its durable winner; its observer is ready before the original
        // loser comes back and initiates the sole new connection.
        try await winner.stop()
        try await loser.stop()
        d.setOverlayPeers([])
        try d.start()
        _ = try await waitForTip(d, winnerCID)
        let liveObserver = try E2EOverlayObserver(
            port: ports[12],
            bootstrapPeer: dPeer,
            hello: ChainHello(
                nexusGenesisCID: NexusGenesis.expectedBlockHash,
                chainPath: ["Nexus"],
                minimumRootWorkHex: String(repeating: "0", count: 63) + "1"
            )
        )
        addTeardownBlock { await liveObserver.stop() }
        try await liveObserver.start()
        try await liveObserver.waitForConnection(to: dPeer.publicKey)
        try await liveObserver.waitForAnnouncement(of: winnerCID)

        // This is now D's first possible route to the loser. A fresh
        // D-originated announcement is emitted only after durable admission.
        let loserAnnouncements = await liveObserver.announcementCount(of: loserCID)
        XCTAssertEqual(loserAnnouncements, 0)
        loser.setOverlayPeers([dPeer])
        try loser.start()
        try await liveObserver.waitForAnnouncement(
            of: loserCID,
            after: loserAnnouncements
        )
        let reverseArrival = try await d.waitForStatus { _ in true }
        XCTAssertEqual(reverseArrival.tipCID, winnerCID)
        await liveObserver.stop()

        // D's inbound synchronization above proves reverse arrival, but does
        // not require D to become an advertiser to that source. Reconnect the
        // original winning replica directly to the loser to exercise the
        // losing node's canonical-delta/mempool reconciliation.
        winner.setOverlayPeers([loserPeer])
        try winner.start()
        _ = try await waitForTip(winner, winnerCID)
        _ = try await loser.waitForStatus {
            $0.tipCID == winnerCID && $0.mempoolCount == 1
        }
        try await winner.stop()

        // Once every source is gone, each process must recover the selected
        // projection from disk. A transaction revalidated from disconnected
        // canonical history is a bounded durable reorg candidate, so the
        // losing node restores it without either branch source.
        try await loser.stop()
        loser.setOverlayPeers([])
        try loser.start()
        _ = try await loser.waitForStatus {
            $0.tipCID == winnerCID && $0.mempoolCount == 1
        }
        try await loser.stop()
        c.forceTerminate()
        d.forceTerminate()
        c.setOverlayPeers([])
        d.setOverlayPeers([])
        try c.start()
        try d.start()
        _ = try await waitForTip(c, winnerCID)
        _ = try await waitForTip(d, winnerCID)

        try await cluster.stopAll()
        passed = true
    }

    func testSeededNexusReplicasReconcileAcrossRestartAndLateJoin() async throws {
        let seedText = ProcessInfo.processInfo.environment["LATTICE_E2E_SEED"]
            ?? "1592614637"
        let seed = try XCTUnwrap(
            UInt64(seedText),
            "LATTICE_E2E_SEED must be an unsigned integer"
        )
        print("LATTICE_E2E_SEED=\(seed)")
        let roundText = ProcessInfo.processInfo.environment["LATTICE_E2E_ROUNDS"]
            ?? "8"
        let roundCount = try XCTUnwrap(
            Int(roundText).flatMap { (1...155).contains($0) ? $0 : nil },
            "LATTICE_E2E_ROUNDS must be between 1 and 155"
        )
        print("LATTICE_E2E_ROUNDS=\(roundCount)")

        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        defer {
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let binary = try E2EBinary.latticeNode()
        let identities = try [
            workspace.makeIdentity(named: "seeded-a"),
            workspace.makeIdentity(named: "seeded-b"),
            workspace.makeIdentity(named: "seeded-late"),
        ]
        let ports = try E2EPorts.allocate(count: 9)
        let peers = try [
            overlayPeer(identity: identities[0], port: ports[0]),
            overlayPeer(identity: identities[1], port: ports[3]),
        ]
        let replicas = (0..<3).map { index in
            nexusNode(
                binary: binary,
                workspace: workspace,
                name: ["seeded-a", "seeded-b", "seeded-late"][index],
                identity: identities[index],
                overlayPort: ports[index * 3],
                factPort: ports[index * 3 + 1],
                rpcPort: ports[index * 3 + 2]
            )
        }
        replicas[0].setOverlayPeers([peers[1]])
        replicas[1].setOverlayPeers([peers[0]])
        replicas[2].setOverlayPeers(peers)
        cluster.add(replicas[0])
        cluster.add(replicas[1])
        cluster.add(replicas[2])

        try replicas[0].start()
        try replicas[1].start()
        _ = try await waitForNexus(replicas[0])
        _ = try await waitForNexus(replicas[1])

        var generator = E2ESeededGenerator(seed: seed)
        let lateJoinRound = roundCount == 1
            ? 0
            : 1 + generator.next(upperBound: roundCount - 1)
        var started = [0, 1]
        var expectedTip = NexusGenesis.expectedBlockHash
        var expectedHeight: UInt64 = 0

        for round in 0..<roundCount {
            if round == lateJoinRound {
                try replicas[2].start()
                started.append(2)
                _ = try await replicas[2].waitForStatus {
                    $0.tipCID == expectedTip
                        && $0.height == expectedHeight
                        && $0.mempoolCount == 0
                }
            }

            let submitter = started[generator.next(upperBound: started.count)]
            let transaction = try legacySignedTransaction(
                chainPath: ["Nexus"],
                keySeed: UInt8(round + 101)
            )
            let transactionCID = try VolumeImpl<Transaction>(
                node: transaction
            ).rawCID
            let submitted: SubmitTransactionResponse = try await replicas[submitter].post(
                "/v1/transactions",
                body: SubmitTransactionRequest(transaction: transaction)
            )
            XCTAssertEqual(submitted.transactionCID, transactionCID)
            XCTAssertEqual(submitted.mempoolCount, 1)
            for index in started {
                _ = try await replicas[index].waitForStatus { $0.mempoolCount == 1 }
            }

            // Rotate every failure mode in every seed; the seed chooses the
            // affected replica and the producer, not whether an edge is seen.
            let failure = (round + Int(seed & 3)) % 4
            let failed = failure == 0
                ? nil
                : started[generator.next(upperBound: started.count)]
            if let failed {
                switch failure {
                case 1:
                    try await replicas[failed].stop()
                case 2:
                    replicas[failed].forceTerminate()
                default:
                    try replicas[failed].suspend()
                }
            }
            let responsive = started.filter { $0 != failed }
            let producer = responsive[generator.next(upperBound: responsive.count)]
            let failedLabel = failed.map(String.init) ?? "none"
            print(
                "seeded round=\(round) submitter=\(submitter) "
                    + "failure=\(failure) failed=\(failedLabel) "
                    + "producer=\(producer)"
            )

            let block = try await mineBlock(replicas[producer])
            XCTAssertTrue(block.response.accepted)
            XCTAssertEqual(block.template.block.parent?.rawCID, expectedTip)
            let transactionVolume = try VolumeImpl<Transaction>(node: transaction)
            let expectedTransactions = try MerkleDictionaryImpl<VolumeImpl<Transaction>>()
                .inserting(key: "0", value: transactionVolume)
            XCTAssertEqual(
                block.template.block.transactions.rawCID,
                try HeaderImpl(node: expectedTransactions).rawCID
            )
            expectedTip = block.blockCID
            expectedHeight += 1
            for index in responsive {
                _ = try await replicas[index].waitForStatus {
                    $0.tipCID == expectedTip
                        && $0.height == expectedHeight
                        && $0.mempoolCount == 0
                }
            }

            if let failed {
                if failure == 3 {
                    try replicas[failed].resume()
                } else {
                    try replicas[failed].start()
                }
            }
            for index in started {
                _ = try await replicas[index].waitForStatus {
                    $0.tipCID == expectedTip
                        && $0.height == expectedHeight
                        && $0.mempoolCount == 0
                }
            }
        }

        try await cluster.stopAll()
        passed = true
    }

    func testSamePathReplicaRelaysHigherWorkAcrossRestartAndLateJoin() async throws {
        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        defer {
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let binary = try E2EBinary.latticeNode()
        let aIdentity = try workspace.makeIdentity(named: "a")
        let bIdentity = try workspace.makeIdentity(named: "b")
        let cIdentity = try workspace.makeIdentity(named: "c")
        let dIdentity = try workspace.makeIdentity(named: "d")
        let ports = try E2EPorts.allocate(count: 12)
        let aPeer = try overlayPeer(identity: aIdentity, port: ports[0])
        let bPeer = try overlayPeer(identity: bIdentity, port: ports[3])
        let cPeer = try overlayPeer(identity: cIdentity, port: ports[6])

        let a = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "a",
            identity: aIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let b = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "b",
            identity: bIdentity,
            overlayPort: ports[3],
            factPort: ports[4],
            rpcPort: ports[5]
        )
        let c = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "c",
            identity: cIdentity,
            overlayPort: ports[6],
            factPort: ports[7],
            rpcPort: ports[8]
        )
        let d = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "d",
            identity: dIdentity,
            overlayPort: ports[9],
            factPort: ports[10],
            rpcPort: ports[11]
        )
        cluster.add(a)
        cluster.add(b)
        cluster.add(c)
        cluster.add(d)

        try a.start()
        try b.start()
        _ = try await waitForNexus(a)
        _ = try await waitForNexus(b)

        let _: SubmitTransactionResponse = try await a.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(
                transaction: try legacySignedTransaction(chainPath: ["Nexus"])
            )
        )
        let _: SubmitTransactionResponse = try await b.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(
                transaction: try legacySignedTransaction(chainPath: ["Nexus"])
            )
        )
        let a1 = try await mineBlock(a)
        let b1 = try await mineBlock(b)
        let b2 = try await mineBlock(b)
        XCTAssertTrue(a1.response.accepted)
        XCTAssertTrue(b1.response.accepted)
        XCTAssertTrue(b2.response.accepted)
        XCTAssertEqual(a1.response.tipCID, a1.blockCID)
        XCTAssertEqual(b2.response.tipCID, b2.blockCID)
        XCTAssertEqual(a1.template.block.parent?.rawCID, NexusGenesis.expectedBlockHash)
        XCTAssertEqual(b1.template.block.parent?.rawCID, NexusGenesis.expectedBlockHash)
        XCTAssertEqual(b2.template.block.parent?.rawCID, b1.blockCID)
        XCTAssertNotEqual(a1.blockCID, b1.blockCID)
        XCTAssertNotEqual(b1.blockCID, b2.blockCID)

        // This is the exact root-only case: each distinct accepted root block
        // contributes workForTarget(target) under its own block-CID grind.
        let aWork = WorkSum(workForTarget(a1.template.block.target))
        let bWork = WorkSum(workForTarget(b1.template.block.target))
            + WorkSum(workForTarget(b2.template.block.target))
        XCTAssertGreaterThan(workForTarget(b2.template.block.target), .zero)
        XCTAssertGreaterThan(bWork, aWork)

        // C learns B's previously withheld branch while A has no peer edge to
        // either B or C. Kill all three, then recover A without a peer: it
        // must first restore its divergent branch from disk.
        c.setOverlayPeers([bPeer])
        try c.start()
        _ = try await waitForTip(c, b2.blockCID)
        b.forceTerminate()
        c.forceTerminate()
        a.forceTerminate()
        a.setOverlayPeers([])
        try a.start()
        _ = try await waitForTip(a, a1.blockCID)
        try await a.stop()

        // C reopens its durable branch with no bootstrap peers. Start C before
        // A attaches its only peer so this test isolates node-level durable
        // relay and reorg behavior from Ivy's independently tested retry
        // schedule. A can only learn B's branch through C's overlay content.
        c.setOverlayPeers([])
        try c.start()
        _ = try await waitForTip(c, b2.blockCID)
        a.setOverlayPeers([cPeer])
        try a.start()
        _ = try await waitForTip(a, b2.blockCID)

        // Remove the bridge as well. A must recover the learned branch from
        // disk after a crash before fresh D can obtain it only from A.
        a.forceTerminate()
        c.forceTerminate()
        try a.start()
        _ = try await waitForTip(a, b2.blockCID)
        d.setOverlayPeers([aPeer])
        try d.start()
        _ = try await waitForTip(d, b2.blockCID)

        try await cluster.stopAll()
        passed = true
    }

    func testVariableRateExchangeSurvivesAdversarialChildPool() async throws {
        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        defer {
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let binary = try E2EBinary.latticeNode()
        let parentIdentity = try workspace.makeIdentity(named: "nexus")
        let childIdentity = try workspace.makeIdentity(named: "market")
        let lateIdentity = try workspace.makeIdentity(named: "market-late")
        let parentPeerKey = try PeerKey(parentIdentity.publicKey)
        let ports = try E2EPorts.allocate(count: 9)
        let childPeer = try overlayPeer(identity: childIdentity, port: ports[3])
        let parent = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "nexus",
                chainPath: "Nexus",
                storage: workspace.url.appendingPathComponent("nexus", isDirectory: true),
                identity: parentIdentity,
                overlayPort: ports[0],
                factPort: ports[1],
                rpcPort: ports[2]
            ),
            logDirectory: workspace.logs
        )
        let child = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "market",
                chainPath: "Nexus/Market",
                storage: workspace.url.appendingPathComponent("market", isDirectory: true),
                identity: childIdentity,
                overlayPort: ports[3],
                factPort: ports[4],
                rpcPort: ports[5],
                parent: .init(publicKey: parentPeerKey.hex, factPort: ports[1])
            ),
            logDirectory: workspace.logs
        )
        let late = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "market-late",
                chainPath: "Nexus/Market",
                storage: workspace.url.appendingPathComponent(
                    "market-late",
                    isDirectory: true
                ),
                identity: lateIdentity,
                overlayPort: ports[6],
                factPort: ports[7],
                rpcPort: ports[8],
                overlayPeers: [childPeer],
                parent: .init(publicKey: parentPeerKey.hex, factPort: ports[1])
            ),
            logDirectory: workspace.logs
        )
        cluster.add(parent)
        cluster.add(child)
        cluster.add(late)

        try parent.start()
        try child.start()
        _ = try await waitForNexus(parent)
        _ = try await child.waitForStatus {
            $0.phase == .awaitingGenesis && $0.tipCID == nil
        }

        let seller = CryptoUtils.generateKeyPair()
        let buyer = CryptoUtils.generateKeyPair()
        let attacker = CryptoUtils.generateKeyPair()
        let witness = CryptoUtils.generateKeyPair()
        let sink = CryptoUtils.generateKeyPair()
        let sellerAddress = CryptoUtils.createAddress(from: seller.publicKey)
        let buyerAddress = CryptoUtils.createAddress(from: buyer.publicKey)
        let attackerAddress = CryptoUtils.createAddress(from: attacker.publicKey)
        let witnessAddress = CryptoUtils.createAddress(from: witness.publicKey)
        let sinkAddress = CryptoUtils.createAddress(from: sink.publicKey)
        let childPath = ["Nexus", "Market"]
        let depositA: UInt64 = 100
        let demandA: UInt64 = 250
        let nonceA: UInt128 = 7
        let depositB: UInt64 = 50
        let demandB: UInt64 = 125
        let nonceB: UInt128 = 8

        let childGenesisTransaction = try signedTransaction(
            key: seller,
            chainPath: childPath,
            accountActions: [AccountAction(owner: sellerAddress, delta: 1_000)],
            nonce: 0
        )
        let intent: ChildDeployIntentResponse = try await parent.post(
            "/v1/children/intents",
            body: ChildDeployIntentRequest(
                directory: "Market",
                spec: ChainSpec(
                    maxNumberOfTransactionsPerBlock: 100,
                    maxStateGrowth: 100_000,
                    premine: 1_000,
                    targetBlockTime: 1_000,
                    initialReward: 10,
                    halvingInterval: 100
                ),
                genesisTransactions: [childGenesisTransaction],
                target: .max,
                timestamp: 1
            )
        )
        try await submitGenesisAnchor(
            on: parent,
            intent: intent,
            chainPath: ["Nexus"]
        )
        let buyerReward = try signedTransaction(
            key: buyer,
            chainPath: ["Nexus"],
            accountActions: [AccountAction(
                owner: buyerAddress,
                delta: Int64(demandA + demandB)
            )],
            nonce: 0
        )
        let deployment = try await mineBlock(
            parent,
            rewards: [MiningReward(chainPath: ["Nexus"], transaction: buyerReward)],
            mode: .deployment
        )
        XCTAssertTrue(deployment.response.accepted)
        _ = try await child.waitForStatus {
            $0.phase == .active && $0.tipCID == intent.genesisCID
        }

        let deposit = try signedTransaction(
            key: seller,
            chainPath: childPath,
            accountActions: [AccountAction(
                owner: sellerAddress,
                delta: -Int64(depositA + depositB)
            )],
            depositActions: [
                DepositAction(
                    nonce: nonceA,
                    demander: sellerAddress,
                    amountDemanded: demandA,
                    amountDeposited: depositA
                ),
                DepositAction(
                    nonce: nonceB,
                    demander: sellerAddress,
                    amountDemanded: demandB,
                    amountDeposited: depositB
                ),
            ],
            nonce: 1
        )
        let _: SubmitTransactionResponse = try await child.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: deposit)
        )
        _ = try await child.waitForStatus { $0.mempoolCount == 1 }
        var depositedStatus: ChainServiceStatusResponse?
        for _ in 0..<5 {
            let work = try await mine(parent)
            XCTAssertTrue(work.accepted)
            if let status = try? await child.waitForStatus(
                timeout: .seconds(2),
                where: { $0.phase == .active && $0.mempoolCount == 0 && ($0.height ?? 0) > 0 }
            ) {
                depositedStatus = status
                break
            }
        }
        let childAfterDeposit = try XCTUnwrap(
            depositedStatus,
            "child deposit did not enter a parent-carried block"
        )

        let receipt = try signedTransaction(
            key: buyer,
            chainPath: ["Nexus"],
            receiptActions: [
                ReceiptAction(
                    withdrawer: buyerAddress,
                    nonce: nonceA,
                    demander: sellerAddress,
                    amountDemanded: demandA,
                    directory: "Market"
                ),
                ReceiptAction(
                    withdrawer: buyerAddress,
                    nonce: nonceB,
                    demander: sellerAddress,
                    amountDemanded: demandB,
                    directory: "Market"
                ),
            ],
            nonce: 1
        )
        let _: SubmitTransactionResponse = try await parent.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: receipt)
        )

        let wrongWithdrawer = try signedTransaction(
            key: attacker,
            chainPath: childPath,
            accountActions: [AccountAction(
                owner: attackerAddress,
                delta: Int64(depositA)
            )],
            withdrawalActions: [WithdrawalAction(
                withdrawer: attackerAddress,
                nonce: nonceA,
                demander: sellerAddress,
                amountDemanded: demandA,
                amountWithdrawn: depositA
            )],
            nonce: 0
        )
        let replay = try signedTransaction(
            key: buyer,
            chainPath: childPath,
            accountActions: [AccountAction(
                owner: buyerAddress,
                delta: Int64(depositA)
            )],
            withdrawalActions: [WithdrawalAction(
                withdrawer: buyerAddress,
                nonce: nonceA,
                demander: sellerAddress,
                amountDemanded: demandA,
                amountWithdrawn: depositA
            )],
            nonce: 0
        )
        let overclaim = try signedTransaction(
            key: buyer,
            chainPath: childPath,
            accountActions: [AccountAction(
                owner: buyerAddress,
                delta: Int64(depositB + 1)
            )],
            withdrawalActions: [WithdrawalAction(
                withdrawer: buyerAddress,
                nonce: nonceB,
                demander: sellerAddress,
                amountDemanded: demandB,
                amountWithdrawn: depositB + 1
            )],
            nonce: 1
        )
        let desired = try signedTransaction(
            key: buyer,
            chainPath: childPath,
            accountActions: [
                AccountAction(owner: buyerAddress, delta: Int64(depositA - 3)),
                AccountAction(owner: witnessAddress, delta: 1),
            ],
            withdrawalActions: [WithdrawalAction(
                withdrawer: buyerAddress,
                nonce: nonceA,
                demander: sellerAddress,
                amountDemanded: demandA,
                amountWithdrawn: depositA
            )],
            fee: 2,
            nonce: 0
        )
        for transaction in [wrongWithdrawer, replay, overclaim, desired] {
            let _: SubmitTransactionResponse = try await child.post(
                "/v1/transactions",
                body: SubmitTransactionRequest(transaction: transaction)
            )
        }
        // The higher-fee desired claim replaces the same-signer/same-nonce
        // replay; the two independently invalid claims remain queued.
        _ = try await child.waitForStatus { $0.mempoolCount == 3 }

        // These claims arrive before the carrier commits its receipts. The
        // child must still publish an empty candidate and retain all three.
        let receiptWork = try await mine(parent)
        XCTAssertTrue(receiptWork.accepted)
        XCTAssertEqual(receiptWork.publishedChildProofs.map(\.directory), ["Market"])
        _ = try await parent.waitForStatus { $0.mempoolCount == 0 }
        let delayed = try await child.waitForStatus {
            $0.mempoolCount == 3
                && $0.tipCID != childAfterDeposit.tipCID
                && $0.height == childAfterDeposit.height.map { $0 + 1 }
        }

        // The fee-ranked desired claim must replace the replay and survive the
        // two other non-cooperative alternatives submitted first.
        let withdrawalWork = try await mine(parent)
        XCTAssertTrue(withdrawalWork.accepted)
        XCTAssertEqual(withdrawalWork.publishedChildProofs.map(\.directory), ["Market"])
        let withdrawn = try await child.waitForStatus {
            $0.mempoolCount == 2
                && $0.tipCID != delayed.tipCID
                && $0.height == delayed.height.map { $0 + 1 }
        }

        let beforeReplayData = try await child.get(
            "/v1/accounts/\(buyerAddress)/proof"
        )
        let beforeReplay = try JSONDecoder().decode(
            LightClientProof.self,
            from: beforeReplayData
        )
        let beforeReplayBlockCID = await LightClientProtocol.verify(beforeReplay)
        XCTAssertEqual(
            beforeReplayBlockCID,
            withdrawn.tipCID
        )
        XCTAssertEqual(beforeReplay.balance, depositA - 3)

        // A fresh same-path replica must acquire the withdrawal's complete
        // cross-chain state through production protocols, then remain able to
        // serve as the only live child process.
        try late.start()
        _ = try await late.waitForStatus {
            $0.phase == .active
                && $0.tipCID == withdrawn.tipCID
                && $0.height == withdrawn.height
        }
        let lateProofData = try await late.get(
            "/v1/accounts/\(buyerAddress)/proof"
        )
        let lateProof = try JSONDecoder().decode(
            LightClientProof.self,
            from: lateProofData
        )
        let lateProofBlockCID = await LightClientProtocol.verify(lateProof)
        XCTAssertEqual(
            lateProofBlockCID,
            withdrawn.tipCID
        )
        XCTAssertEqual(lateProof.balance, beforeReplay.balance)
        XCTAssertEqual(lateProof.nonce, beforeReplay.nonce)
        try await child.stop()

        // This is a true replay: the first withdrawal is already canonical,
        // so the deposit's permanent spent marker must reject a fresh-nonce
        // claim submitted through the newly joined replica.
        let spentDepositReplay = try signedTransaction(
            key: buyer,
            chainPath: childPath,
            accountActions: [AccountAction(
                owner: buyerAddress,
                delta: Int64(depositA - 1)
            )],
            withdrawalActions: [WithdrawalAction(
                withdrawer: buyerAddress,
                nonce: nonceA,
                demander: sellerAddress,
                amountDemanded: demandA,
                amountWithdrawn: depositA
            )],
            fee: 1,
            nonce: 1
        )
        let _: SubmitTransactionResponse = try await late.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: spentDepositReplay)
        )
        let replayWork = try await mine(parent)
        XCTAssertTrue(replayWork.accepted)
        let replayRejected = try await late.waitForStatus {
            $0.height == withdrawn.height.map { $0 + 1 }
        }
        let afterReplayData = try await late.get(
            "/v1/accounts/\(buyerAddress)/proof"
        )
        let afterReplay = try JSONDecoder().decode(
            LightClientProof.self,
            from: afterReplayData
        )
        let afterReplayBlockCID = await LightClientProtocol.verify(afterReplay)
        XCTAssertEqual(
            afterReplayBlockCID,
            replayRejected.tipCID
        )
        XCTAssertEqual(afterReplay.balance, beforeReplay.balance)
        XCTAssertEqual(afterReplay.nonce, beforeReplay.nonce)

        // Spending the one-unit witness output proves the exact fee-ranked
        // claim committed, rather than the same-nonce competing claim.
        let witnessSpend = try signedTransaction(
            key: witness,
            chainPath: childPath,
            accountActions: [
                AccountAction(owner: witnessAddress, delta: -1),
                AccountAction(owner: sinkAddress, delta: 1),
            ],
            nonce: 0
        )
        let _: SubmitTransactionResponse = try await late.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: witnessSpend)
        )

        // The parent-side spend independently proves both receipts paid the
        // seller their full variable-rate demand.
        let spendNexusProceeds = try signedTransaction(
            key: seller,
            chainPath: ["Nexus"],
            accountActions: [
                AccountAction(owner: sellerAddress, delta: -Int64(demandA + demandB)),
                AccountAction(owner: sinkAddress, delta: Int64(demandA + demandB)),
            ],
            nonce: 0
        )
        let _: SubmitTransactionResponse = try await parent.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: spendNexusProceeds)
        )
        let spendWork = try await mine(parent)
        XCTAssertTrue(spendWork.accepted)
        XCTAssertEqual(spendWork.publishedChildProofs.map(\.directory), ["Market"])
        _ = try await parent.waitForStatus { $0.mempoolCount == 0 }
        let spent = try await late.waitForStatus {
            $0.height == replayRejected.height.map { $0 + 1 }
        }
        let lateSinkData = try await late.get(
            "/v1/accounts/\(sinkAddress)/proof"
        )
        let lateSink = try JSONDecoder().decode(
            LightClientProof.self,
            from: lateSinkData
        )
        let lateSinkBlockCID = await LightClientProtocol.verify(lateSink)
        XCTAssertEqual(
            lateSinkBlockCID,
            spent.tipCID
        )
        XCTAssertEqual(lateSink.balance, 1)

        // Persistent contextual junk neither becomes valid nor suppresses the
        // next empty child block.
        let livenessWork = try await mine(parent)
        XCTAssertTrue(livenessWork.accepted)
        XCTAssertEqual(livenessWork.publishedChildProofs.map(\.directory), ["Market"])
        let finalChild = try await late.waitForStatus {
            $0.height == spent.height.map { $0 + 1 }
        }

        try child.start()
        _ = try await child.waitForStatus {
            $0.phase == .active
                && $0.tipCID == finalChild.tipCID
                && $0.height == finalChild.height
        }
        let recoveredSinkData = try await child.get(
            "/v1/accounts/\(sinkAddress)/proof"
        )
        let recoveredSink = try JSONDecoder().decode(
            LightClientProof.self,
            from: recoveredSinkData
        )
        let recoveredSinkBlockCID = await LightClientProtocol.verify(recoveredSink)
        XCTAssertEqual(
            recoveredSinkBlockCID,
            finalChild.tipCID
        )
        XCTAssertEqual(recoveredSink.balance, lateSink.balance)

        try await cluster.stopAll()
        passed = true
    }

    func testTwoChildExchangeSurvivesHeavierNexusForkAfterSettlement() async throws {
        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        defer {
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let binary = try E2EBinary.latticeNode()
        let nexusIdentity = try workspace.makeIdentity(named: "nexus")
        let forkIdentity = try workspace.makeIdentity(named: "fork")
        let childAIdentity = try workspace.makeIdentity(named: "child-a")
        let childBIdentity = try workspace.makeIdentity(named: "child-b")
        let nexusPeerKey = try PeerKey(nexusIdentity.publicKey)
        let ports = try E2EPorts.allocate(count: 12)
        let nexusPeer = try overlayPeer(identity: nexusIdentity, port: ports[0])
        let nexus = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "nexus",
            identity: nexusIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let fork = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "fork",
            identity: forkIdentity,
            overlayPort: ports[9],
            factPort: ports[10],
            rpcPort: ports[11]
        )
        let childA = childNode(
            binary: binary,
            workspace: workspace,
            name: "child-a",
            directory: "ChildA",
            identity: childAIdentity,
            parentPublicKey: nexusPeerKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[3],
            factPort: ports[4],
            rpcPort: ports[5]
        )
        let childB = childNode(
            binary: binary,
            workspace: workspace,
            name: "child-b",
            directory: "ChildB",
            identity: childBIdentity,
            parentPublicKey: nexusPeerKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[6],
            factPort: ports[7],
            rpcPort: ports[8]
        )
        cluster.add(nexus)
        cluster.add(fork)
        cluster.add(childA)
        cluster.add(childB)

        try nexus.start()
        try childA.start()
        try childB.start()
        _ = try await waitForNexus(nexus)
        _ = try await childA.waitForStatus { $0.phase == .awaitingGenesis }
        _ = try await childB.waitForStatus { $0.phase == .awaitingGenesis }

        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let sink = CryptoUtils.generateKeyPair()
        let aliceAddress = CryptoUtils.createAddress(from: alice.publicKey)
        let bobAddress = CryptoUtils.createAddress(from: bob.publicKey)
        let sinkAddress = CryptoUtils.createAddress(from: sink.publicKey)
        let childAPath = ["Nexus", "ChildA"]
        let childBPath = ["Nexus", "ChildB"]
        let aliceDeposit: UInt64 = 100
        let bobDeposit: UInt64 = 200
        let aliceDemand: UInt64 = 200
        let bobDemand: UInt64 = 100
        let aliceExchangeNonce: UInt128 = 11
        let bobExchangeNonce: UInt128 = 22

        let childAIntent = try await fundedChildIntent(
            on: nexus,
            directory: "ChildA",
            owner: alice,
            premine: 1_000,
            timestamp: 1
        )
        let childBIntent = try await fundedChildIntent(
            on: nexus,
            directory: "ChildB",
            owner: bob,
            premine: 1_000,
            timestamp: 1
        )
        let nexusAuthority = try XCTUnwrap(
            ParentWorkAuthorityKey(nexus.processPublicKey)
        )
        let siblingAnchor = try legacySignedTransaction(
            chainPath: ["Nexus"],
            genesisActions: [
                GenesisAction(
                    directory: childAIntent.directory,
                    blockCID: childAIntent.genesisCID,
                    parentWorkAuthorityKey: nexusAuthority
                ),
                GenesisAction(
                    directory: childBIntent.directory,
                    blockCID: childBIntent.genesisCID,
                    parentWorkAuthorityKey: nexusAuthority
                ),
            ]
        )
        let _: SubmitTransactionResponse = try await nexus.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: siblingAnchor)
        )

        // Give both settlement signers nonce zero in the deployment block.
        // Bob receives only the net Nexus amount needed by the co-signed swap.
        let aliceNonce = try signedTransaction(
            key: alice,
            chainPath: ["Nexus"],
            nonce: 0
        )
        let _: SubmitTransactionResponse = try await nexus.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: aliceNonce)
        )
        let bobFunding = try signedTransaction(
            key: bob,
            chainPath: ["Nexus"],
            accountActions: [AccountAction(owner: bobAddress, delta: 100)],
            nonce: 0
        )
        let deployment = try await mineBlock(
            nexus,
            rewards: [MiningReward(chainPath: ["Nexus"], transaction: bobFunding)],
            mode: .deployment
        )
        XCTAssertTrue(deployment.response.accepted)
        _ = try await childA.waitForStatus {
            $0.phase == .active && $0.tipCID == childAIntent.genesisCID
        }
        _ = try await childB.waitForStatus {
            $0.phase == .active && $0.tipCID == childBIntent.genesisCID
        }

        let aliceLocksA = try signedTransaction(
            key: alice,
            chainPath: childAPath,
            accountActions: [AccountAction(owner: aliceAddress, delta: -Int64(aliceDeposit))],
            depositActions: [DepositAction(
                nonce: aliceExchangeNonce,
                demander: aliceAddress,
                amountDemanded: aliceDemand,
                amountDeposited: aliceDeposit
            )],
            nonce: 1
        )
        let bobLocksB = try signedTransaction(
            key: bob,
            chainPath: childBPath,
            accountActions: [AccountAction(owner: bobAddress, delta: -Int64(bobDeposit))],
            depositActions: [DepositAction(
                nonce: bobExchangeNonce,
                demander: bobAddress,
                amountDemanded: bobDemand,
                amountDeposited: bobDeposit
            )],
            nonce: 1
        )
        let _: SubmitTransactionResponse = try await childA.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: aliceLocksA)
        )
        let _: SubmitTransactionResponse = try await childB.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: bobLocksB)
        )
        var depositedA: ChainServiceStatusResponse?
        var depositedB: ChainServiceStatusResponse?
        for _ in 0..<5 {
            let work = try await mine(nexus)
            XCTAssertTrue(work.accepted)
            let a = try? await childA.waitForStatus(
                timeout: .seconds(2),
                where: { $0.mempoolCount == 0 && ($0.height ?? 0) > 0 }
            )
            let b = try? await childB.waitForStatus(
                timeout: .seconds(2),
                where: { $0.mempoolCount == 0 && ($0.height ?? 0) > 0 }
            )
            if a != nil && b != nil {
                depositedA = a
                depositedB = b
                break
            }
        }
        let childAAfterDeposit = try XCTUnwrap(depositedA)
        let childBAfterDeposit = try XCTUnwrap(depositedB)
        let branchStatus = try await nexus.waitForStatus { $0.mempoolCount == 0 }
        let branchPoint = try XCTUnwrap(branchStatus.tipCID)

        // Fork from the last parent state shared by both deposits, then remove
        // every network edge before either branch commits settlement state.
        fork.setOverlayPeers([nexusPeer])
        try fork.start()
        _ = try await waitForTip(fork, branchPoint)
        try await fork.stop()
        fork.setOverlayPeers([])
        try fork.start()
        _ = try await waitForTip(fork, branchPoint)

        let settlement = try signedTransaction(
            keys: [alice, bob],
            chainPath: ["Nexus"],
            receiptActions: [
                ReceiptAction(
                    withdrawer: bobAddress,
                    nonce: aliceExchangeNonce,
                    demander: aliceAddress,
                    amountDemanded: aliceDemand,
                    directory: "ChildA"
                ),
                ReceiptAction(
                    withdrawer: aliceAddress,
                    nonce: bobExchangeNonce,
                    demander: bobAddress,
                    amountDemanded: bobDemand,
                    directory: "ChildB"
                ),
            ],
            nonce: 1
        )
        let bobClaimsA = try signedTransaction(
            key: bob,
            chainPath: childAPath,
            accountActions: [AccountAction(owner: bobAddress, delta: Int64(aliceDeposit))],
            withdrawalActions: [WithdrawalAction(
                withdrawer: bobAddress,
                nonce: aliceExchangeNonce,
                demander: aliceAddress,
                amountDemanded: aliceDemand,
                amountWithdrawn: aliceDeposit
            )],
            nonce: 0
        )
        let aliceClaimsB = try signedTransaction(
            key: alice,
            chainPath: childBPath,
            accountActions: [AccountAction(owner: aliceAddress, delta: Int64(bobDeposit))],
            withdrawalActions: [WithdrawalAction(
                withdrawer: aliceAddress,
                nonce: bobExchangeNonce,
                demander: bobAddress,
                amountDemanded: bobDemand,
                amountWithdrawn: bobDeposit
            )],
            nonce: 0
        )
        let _: SubmitTransactionResponse = try await nexus.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: settlement)
        )
        let _: SubmitTransactionResponse = try await childA.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: bobClaimsA)
        )
        let _: SubmitTransactionResponse = try await childB.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: aliceClaimsB)
        )

        // A child binds to the carrier's entering parent state. The root that
        // commits these receipts therefore advances both children with empty
        // blocks while leaving their premature withdrawals queued.
        let settlementBlock = try await mineBlock(nexus)
        XCTAssertTrue(settlementBlock.response.accepted)
        XCTAssertEqual(
            Set(settlementBlock.response.publishedChildProofs.map(\.directory)),
            ["ChildA", "ChildB"]
        )
        _ = try await nexus.waitForStatus { $0.mempoolCount == 0 }
        let delayedA = try await childA.waitForStatus {
            $0.mempoolCount == 1
                && $0.tipCID != childAAfterDeposit.tipCID
                && $0.height == childAAfterDeposit.height.map { $0 + 1 }
        }
        let delayedB = try await childB.waitForStatus {
            $0.mempoolCount == 1
                && $0.tipCID != childBAfterDeposit.tipCID
                && $0.height == childBAfterDeposit.height.map { $0 + 1 }
        }

        let withdrawalBlock = try await mineBlock(nexus)
        XCTAssertTrue(withdrawalBlock.response.accepted)
        XCTAssertEqual(
            Set(withdrawalBlock.response.publishedChildProofs.map(\.directory)),
            ["ChildA", "ChildB"]
        )
        let withdrawnA = try await childA.waitForStatus {
            $0.mempoolCount == 0
                && $0.height == delayedA.height.map { $0 + 1 }
        }
        let withdrawnB = try await childB.waitForStatus {
            $0.mempoolCount == 0
                && $0.height == delayedB.height.map { $0 + 1 }
        }

        // The isolated branch consumes the same two signer nonces without the
        // receipts, so reconciliation cannot simply replay the settlement.
        let conflictingNonce = try signedTransaction(
            keys: [alice, bob],
            chainPath: ["Nexus"],
            nonce: 1
        )
        let _: SubmitTransactionResponse = try await fork.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: conflictingNonce)
        )
        _ = try await fork.waitForStatus { $0.mempoolCount == 1 }
        var forkTip = try await mineBlock(fork)
        XCTAssertTrue(forkTip.response.accepted)
        XCTAssertEqual(forkTip.template.block.parent?.rawCID, branchPoint)
        _ = try await fork.waitForStatus { $0.mempoolCount == 0 }

        let settledBranchWork = WorkSum(workForTarget(settlementBlock.template.block.target))
            + WorkSum(workForTarget(withdrawalBlock.template.block.target))
        var forkWork = WorkSum(workForTarget(forkTip.template.block.target))
        while forkWork <= settledBranchWork {
            let extensionBlock = try await mineBlock(fork)
            XCTAssertTrue(extensionBlock.response.accepted)
            XCTAssertEqual(extensionBlock.template.block.parent?.rawCID, forkTip.blockCID)
            forkTip = extensionBlock
            forkWork = forkWork
                + WorkSum(workForTarget(extensionBlock.template.block.target))
        }
        XCTAssertGreaterThan(forkWork, settledBranchWork)

        // Healing changes only the Nexus canonical pointer. Both child blocks
        // already proved the receipt state on the now-side settlement branch.
        try await fork.stop()
        fork.setOverlayPeers([nexusPeer])
        try fork.start()
        _ = try await waitForTip(nexus, forkTip.blockCID)
        let withdrawnATip = try XCTUnwrap(withdrawnA.tipCID)
        let withdrawnBTip = try XCTUnwrap(withdrawnB.tipCID)
        _ = try await waitForTip(childA, withdrawnATip)
        _ = try await waitForTip(childB, withdrawnBTip)
        try await fork.stop()

        // Recovery must preserve child state proved by a now-noncanonical
        // parent branch. Canonical parent pointers are not proof inputs.
        try await childB.stop()
        try await childA.stop()
        try await nexus.stop()
        try nexus.start()
        try childA.start()
        try childB.start()
        _ = try await waitForTip(nexus, forkTip.blockCID)
        let recoveredA = try await waitForTip(childA, withdrawnATip)
        let recoveredB = try await waitForTip(childB, withdrawnBTip)
        XCTAssertEqual(recoveredA.height, withdrawnA.height)
        XCTAssertEqual(recoveredB.height, withdrawnB.height)

        let bobSpendsA = try signedTransaction(
            key: bob,
            chainPath: childAPath,
            accountActions: [
                AccountAction(owner: bobAddress, delta: -Int64(aliceDeposit)),
                AccountAction(owner: sinkAddress, delta: Int64(aliceDeposit)),
            ],
            nonce: 1
        )
        let aliceSpendsB = try signedTransaction(
            key: alice,
            chainPath: childBPath,
            accountActions: [
                AccountAction(owner: aliceAddress, delta: -Int64(bobDeposit)),
                AccountAction(owner: sinkAddress, delta: Int64(bobDeposit)),
            ],
            nonce: 1
        )
        let _: SubmitTransactionResponse = try await childA.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: bobSpendsA)
        )
        let _: SubmitTransactionResponse = try await childB.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: aliceSpendsB)
        )
        var spentA: ChainServiceStatusResponse?
        var spentB: ChainServiceStatusResponse?
        var expectedParent = forkTip.blockCID
        for _ in 0..<5 {
            let work = try await mineBlock(nexus)
            XCTAssertTrue(work.response.accepted)
            XCTAssertEqual(work.template.block.parent?.rawCID, expectedParent)
            expectedParent = work.blockCID
            let a = try? await childA.waitForStatus(
                timeout: .seconds(2),
                where: {
                    $0.mempoolCount == 0
                        && $0.height == withdrawnA.height.map { $0 + 1 }
                }
            )
            let b = try? await childB.waitForStatus(
                timeout: .seconds(2),
                where: {
                    $0.mempoolCount == 0
                        && $0.height == withdrawnB.height.map { $0 + 1 }
                }
            )
            if let a, let b {
                spentA = a
                spentB = b
                break
            }
        }
        let spentAStatus = try XCTUnwrap(spentA)
        let spentBStatus = try XCTUnwrap(spentB)
        let spentATip = try XCTUnwrap(spentAStatus.tipCID)
        let spentBTip = try XCTUnwrap(spentBStatus.tipCID)
        XCTAssertNotEqual(spentATip, withdrawnATip)
        XCTAssertNotEqual(spentBTip, withdrawnBTip)

        try await cluster.stopAll()
        passed = true
    }

    func testAbruptCrashReopensDurableMempoolAndAcceptedTip() async throws {
        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        defer {
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let binary = try E2EBinary.latticeNode()
        let identity = try workspace.makeIdentity(named: "nexus")
        let ports = try E2EPorts.allocate(count: 3)
        let node = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "nexus",
            identity: identity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        cluster.add(node)

        try node.start()
        _ = try await waitForNexus(node)
        let transaction = try legacySignedTransaction(chainPath: ["Nexus"])
        let _: SubmitTransactionResponse = try await node.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: transaction)
        )
        _ = try await node.waitForStatus { $0.mempoolCount == 1 }

        node.forceTerminate()
        try node.start()
        _ = try await node.waitForStatus {
            $0.phase == .active
                && $0.tipCID == NexusGenesis.expectedBlockHash
                && $0.mempoolCount == 1
        }

        let mined = try await mineBlock(node)
        XCTAssertTrue(mined.response.accepted)
        _ = try await node.waitForStatus {
            $0.tipCID == mined.blockCID && $0.mempoolCount == 0
        }

        node.forceTerminate()
        try node.start()
        let recovered = try await waitForTip(node, mined.blockCID)
        XCTAssertEqual(recovered.height, 1)
        XCTAssertEqual(recovered.mempoolCount, 0)

        try await cluster.stopAll()
        passed = true
    }

    func testAcceptedReadsAndProofVerifierSurviveNodeRestart() async throws {
        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        defer {
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let nodeBinary = try E2EBinary.latticeNode()
        let coordinator = try E2EBinary.latticeMiningCoordinator()
        let miner = try E2EBinary.latticeMiner()
        let verifier = try E2EBinary.latticeProofVerifier()
        let identity = try workspace.makeIdentity(named: "read-proof")
        let ports = try E2EPorts.allocate(count: 3)
        let node = nexusNode(
            binary: nodeBinary,
            workspace: workspace,
            name: "read-proof",
            identity: identity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        cluster.add(node)

        try node.start()
        _ = try await waitForNexus(node)

        let sender = CryptoUtils.generateKeyPair()
        let recipient = CryptoUtils.generateKeyPair()
        let senderAddress = CryptoUtils.createAddress(from: sender.publicKey)
        let recipientAddress = CryptoUtils.createAddress(from: recipient.publicKey)
        let funding = try signedTransaction(
            key: sender,
            chainPath: ["Nexus"],
            accountActions: [AccountAction(owner: senderAddress, delta: 100)],
            nonce: 0
        )
        let funded = try await mineWithCoordinator(
            node,
            coordinator: coordinator,
            miner: miner,
            rewards: [MiningReward(chainPath: ["Nexus"], transaction: funding)]
        )
        XCTAssertTrue(funded.accepted)
        _ = try await node.waitForStatus { $0.height == 1 }

        let transaction = try signedTransaction(
            key: sender,
            chainPath: ["Nexus"],
            accountActions: [
                AccountAction(owner: senderAddress, delta: -40),
                AccountAction(owner: recipientAddress, delta: 40),
            ],
            nonce: 1
        )
        let submitted: SubmitTransactionResponse = try await node.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: transaction)
        )
        _ = try await node.waitForStatus { $0.mempoolCount == 1 }
        let mined = try await mineWithCoordinator(
            node,
            coordinator: coordinator,
            miner: miner
        )
        XCTAssertTrue(mined.accepted)
        let blockCID = try XCTUnwrap(mined.tipCID)
        _ = try await node.waitForStatus {
            $0.tipCID == blockCID && $0.height == 2 && $0.mempoolCount == 0
        }

        func assertPublicReads() async throws {
            let blockData = try await node.get("/v1/blocks/\(blockCID)")
            let block = try JSONDecoder().decode(Block.self, from: blockData)
            XCTAssertEqual(try BlockHeader(node: block).rawCID, blockCID)

            let transactionData = try await node.get(
                "/v1/transactions/\(submitted.transactionCID)"
            )
            let content = try JSONDecoder().decode(
                ContentBoundTransaction.self,
                from: transactionData
            )
            XCTAssertEqual(
                try VolumeImpl<Transaction>(node: content.transaction()).rawCID,
                submitted.transactionCID
            )

            let proofData = try await node.get(
                "/v1/accounts/\(senderAddress)/proof"
            )
            let proof = try JSONDecoder().decode(LightClientProof.self, from: proofData)
            XCTAssertEqual(proof.balance, 60)
            XCTAssertEqual(proof.nonce, 1)
            XCTAssertEqual(try BlockHeader(node: proof.block).rawCID, blockCID)
            let verification = try await runProofVerifier(verifier, proof: proofData)
            XCTAssertEqual(verification, "valid \(blockCID)")
        }

        try await assertPublicReads()
        try await node.stop()
        try node.start()
        _ = try await waitForTip(node, blockCID)
        try await assertPublicReads()

        try await cluster.stopAll()
        passed = true
    }

    func testStoppedStoreBackupRestoresAndMismatchedHalfFailsClosed() async throws {
        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        defer {
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let binary = try E2EBinary.latticeNode()
        let originalIdentity = try workspace.makeIdentity(named: "original")
        let ports = try E2EPorts.allocate(count: 9)
        let originalStorage = workspace.url.appendingPathComponent(
            "original",
            isDirectory: true
        )
        let backupStorage = workspace.url.appendingPathComponent(
            "backup",
            isDirectory: true
        )
        let restoredStorage = workspace.url.appendingPathComponent(
            "restored",
            isDirectory: true
        )
        let mismatchedStorage = workspace.url.appendingPathComponent(
            "mismatched",
            isDirectory: true
        )
        let original = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "original",
            identity: originalIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        cluster.add(original)

        try original.start()
        _ = try await waitForNexus(original)
        let backedUp = try await mineBlock(original)
        XCTAssertTrue(backedUp.response.accepted)
        try await original.stop()
        try FileManager.default.copyItem(at: originalStorage, to: backupStorage)

        try original.start()
        _ = try await waitForTip(original, backedUp.blockCID)
        let advanced = try await mineBlock(original)
        XCTAssertTrue(advanced.response.accepted)
        XCTAssertEqual(advanced.template.block.parent?.rawCID, backedUp.blockCID)
        try await original.stop()

        try FileManager.default.copyItem(at: backupStorage, to: restoredStorage)
        try FileManager.default.createDirectory(
            at: mismatchedStorage,
            withIntermediateDirectories: true
        )
        for name in ["state.db", "state.db-shm", "state.db-wal"] {
            let source = originalStorage.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(
                    at: source,
                    to: mismatchedStorage.appendingPathComponent(name)
                )
            }
        }
        for name in ["volumes.db", "volumes.db-shm", "volumes.db-wal"] {
            let source = backupStorage.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(
                    at: source,
                    to: mismatchedStorage.appendingPathComponent(name)
                )
            }
        }

        let mismatched = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "mismatched",
                chainPath: "Nexus",
                storage: mismatchedStorage,
                identity: originalIdentity,
                overlayPort: ports[6],
                factPort: ports[7],
                rpcPort: ports[8]
            ),
            logDirectory: workspace.logs
        )
        cluster.add(mismatched)
        try mismatched.start()
        let mismatchStatus = try await mismatched.waitForExit()
        XCTAssertNotEqual(mismatchStatus, 0)
        XCTAssertTrue(try mismatched.latestStandardError().contains(
            "missingMaterializedVolume"
        ))

        let restored = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "restored",
                chainPath: "Nexus",
                storage: restoredStorage,
                identity: originalIdentity,
                overlayPort: ports[3],
                factPort: ports[4],
                rpcPort: ports[5]
            ),
            logDirectory: workspace.logs
        )
        cluster.add(restored)
        try restored.start()
        let recovered = try await waitForTip(restored, backedUp.blockCID)
        XCTAssertEqual(recovered.height, 1)
        let continued = try await mineBlock(restored)
        XCTAssertTrue(continued.response.accepted)
        XCTAssertEqual(continued.template.block.parent?.rawCID, backedUp.blockCID)
        let continuedStatus = try await waitForTip(restored, continued.blockCID)
        XCTAssertEqual(continuedStatus.height, 2)

        try await cluster.stopAll()
        passed = true
    }

    private func nexusNode(
        binary: URL,
        workspace: E2EWorkspace,
        name: String,
        identity: E2EIdentity,
        overlayPort: UInt16,
        factPort: UInt16,
        rpcPort: UInt16
    ) -> E2ENode {
        E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: name,
                chainPath: "Nexus",
                storage: workspace.url.appendingPathComponent(name, isDirectory: true),
                identity: identity,
                overlayPort: overlayPort,
                factPort: factPort,
                rpcPort: rpcPort
            ),
            logDirectory: workspace.logs
        )
    }

    private func childNode(
        binary: URL,
        workspace: E2EWorkspace,
        name: String,
        directory: String,
        identity: E2EIdentity,
        parentPublicKey: String,
        parentFactPort: UInt16,
        overlayPort: UInt16,
        factPort: UInt16,
        rpcPort: UInt16
    ) -> E2ENode {
        E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: name,
                chainPath: "Nexus/\(directory)",
                storage: workspace.url.appendingPathComponent(name, isDirectory: true),
                identity: identity,
                overlayPort: overlayPort,
                factPort: factPort,
                rpcPort: rpcPort,
                parent: .init(publicKey: parentPublicKey, factPort: parentFactPort)
            ),
            logDirectory: workspace.logs
        )
    }

    private func overlayPeer(
        identity: E2EIdentity,
        port: UInt16
    ) throws -> E2ENode.OverlayPeer {
        E2ENode.OverlayPeer(
            publicKey: try PeerKey(identity.publicKey).hex,
            port: port
        )
    }

    private func waitForNexus(
        _ node: E2ENode
    ) async throws -> ChainServiceStatusResponse {
        try await node.waitForStatus { status in
            status.phase == .active
                && status.chainPath == ["Nexus"]
                && status.tipCID == NexusGenesis.expectedBlockHash
        }
    }

    private func waitForTip(
        _ node: E2ENode,
        _ tipCID: String
    ) async throws -> ChainServiceStatusResponse {
        try await node.waitForStatus { status in
            status.phase == .active && status.tipCID == tipCID
        }
    }

    private func mine(
        _ parent: E2ENode,
        rewards: [MiningReward] = [],
        mode: MiningMode = .normal
    ) async throws -> SubmitWorkResponse {
        try await mineBlock(parent, rewards: rewards, mode: mode).response
    }

    private func mineBlock(
        _ parent: E2ENode,
        rewards: [MiningReward] = [],
        mode: MiningMode = .normal,
        requestTimeout: TimeInterval? = nil
    ) async throws -> E2EMinedBlock {
        let template: MiningTemplateResponse = try await parent.post(
            "/v1/mining/templates",
            body: MiningTemplateRequest(rewards: rewards, mode: mode),
            timeout: requestTimeout
        )
        let midstate = ProofOfWork.midstate(for: template.block)
        var nonce: UInt64 = 0
        while ProofOfWork.hash(midstate: midstate, nonce: nonce)
            > template.searchTarget
        {
            nonce += 1
        }
        let response: SubmitWorkResponse = try await parent.post(
            "/v1/mining/work",
            body: SubmitWorkRequest(workID: template.workID, nonce: nonce)
        )
        return E2EMinedBlock(
            template: template,
            response: response,
            blockCID: try BlockHeader(
                node: ProofOfWork.withNonce(template.block, nonce: nonce)
            ).rawCID
        )
    }

    private func mineWithCoordinator(
        _ parent: E2ENode,
        coordinator: URL,
        miner: URL,
        rewards: [MiningReward] = []
    ) async throws -> E2ECoordinatorResult {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = coordinator
        process.arguments = [
            "--node", parent.rpcURL.absoluteString,
            "--worker-executable", miner.path,
            "--workers", "1",
            "--once",
            "--batch-size", "1",
        ]
        var rewardsFile: URL?
        if !rewards.isEmpty {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(
                "lattice-e2e-rewards-\(UUID().uuidString).json"
            )
            try JSONEncoder().encode(
                MiningTemplateRequest(rewards: rewards)
            ).write(to: file, options: .atomic)
            process.arguments! += ["--rewards-file", file.path]
            rewardsFile = file
        }
        defer {
            if let rewardsFile {
                try? FileManager.default.removeItem(at: rewardsFile)
            }
        }
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(20)
        while process.isRunning && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !process.isRunning else {
            process.terminate()
            let terminationDeadline = clock.now + .seconds(5)
            while process.isRunning && clock.now < terminationDeadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw E2EHTTPError(
                status: 0,
                body: "mining coordinator did not finish within 20 seconds"
            )
        }

        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw E2EHTTPError(
                status: Int(process.terminationStatus),
                body: "mining coordinator failed: \(String(decoding: stderr, as: UTF8.self))"
            )
        }
        do {
            return try JSONDecoder().decode(E2ECoordinatorResult.self, from: stdout)
        } catch {
            throw E2EHTTPError(
                status: 0,
                body: "invalid mining coordinator output: \(String(decoding: stdout, as: UTF8.self)); stderr: \(String(decoding: stderr, as: UTF8.self)); error: \(error)"
            )
        }
    }

    private func mineWithWorker(
        _ parent: E2ENode,
        template: MiningTemplateResponse,
        nonce: UInt64,
        miner: URL
    ) async throws -> SubmitWorkResponse {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = miner
        process.arguments = [
            "--work-id", template.workID,
            "--block-hex", try XCTUnwrap(template.block.toData()).map {
                String(format: "%02x", $0)
            }.joined(),
            "--target", template.searchTarget.toHexString(),
            "--start-nonce", String(nonce),
            "--count", "1",
        ]
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(20)
        while process.isRunning && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !process.isRunning else {
            process.terminate()
            process.waitUntilExit()
            throw E2EHTTPError(status: 0, body: "miner did not finish within 20 seconds")
        }
        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw E2EHTTPError(
                status: Int(process.terminationStatus),
                body: "miner failed: \(String(decoding: stderr, as: UTF8.self))"
            )
        }
        let result = try JSONDecoder().decode(E2EWorkerResult.self, from: stdout)
        guard result.workId == template.workID,
              result.status == "found",
              result.nonce == nonce else {
            throw E2EHTTPError(
                status: 0,
                body: "miner did not solve exact work: \(String(decoding: stdout, as: UTF8.self))"
            )
        }
        return try await parent.post(
            "/v1/mining/work",
            body: SubmitWorkRequest(workID: template.workID, nonce: nonce)
        )
    }

    private func runProofVerifier(
        _ verifier: URL,
        proof: Data
    ) async throws -> String {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = verifier
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: proof)
        try input.fileHandleForWriting.close()

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while process.isRunning && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !process.isRunning else {
            process.terminate()
            process.waitUntilExit()
            throw E2EHTTPError(status: 0, body: "proof verifier timed out")
        }
        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw E2EHTTPError(
                status: Int(process.terminationStatus),
                body: "proof verifier failed: \(String(decoding: stderr, as: UTF8.self))"
            )
        }
        return String(decoding: stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func childIntent(
        on parent: E2ENode,
        directory: String,
        timestamp: Int64,
        target: UInt256 = .max
    ) async throws -> ChildDeployIntentResponse {
        try await parent.post(
            "/v1/children/intents",
            body: ChildDeployIntentRequest(
                directory: directory,
                spec: ChainSpec(
                    maxNumberOfTransactionsPerBlock: 100,
                    maxStateGrowth: 100_000,
                    premine: 0,
                    targetBlockTime: 1_000,
                    initialReward: 10,
                    halvingInterval: 100
                ),
                genesisTransactions: [],
                target: target,
                timestamp: timestamp
            )
        )
    }

    private func fundedChildIntent(
        on parent: E2ENode,
        directory: String,
        owner: (privateKey: String, publicKey: String),
        premine: UInt64,
        timestamp: Int64
    ) async throws -> ChildDeployIntentResponse {
        let path = ["Nexus", directory]
        let ownerAddress = CryptoUtils.createAddress(from: owner.publicKey)
        let premineTransaction = try signedTransaction(
            key: owner,
            chainPath: path,
            accountActions: [AccountAction(owner: ownerAddress, delta: Int64(premine))],
            nonce: 0
        )
        return try await parent.post(
            "/v1/children/intents",
            body: ChildDeployIntentRequest(
                directory: directory,
                spec: ChainSpec(
                    maxNumberOfTransactionsPerBlock: 100,
                    maxStateGrowth: 100_000,
                    premine: premine,
                    targetBlockTime: 1_000,
                    initialReward: 10,
                    halvingInterval: 100
                ),
                genesisTransactions: [premineTransaction],
                target: .max,
                timestamp: timestamp
            )
        )
    }

    private func submitLegacyGenesisAnchor(
        on parent: E2ENode,
        intent: ChildDeployIntentResponse,
        chainPath: [String]
    ) async throws {
        let authority = try XCTUnwrap(
            ParentWorkAuthorityKey(parent.processPublicKey)
        )
        let anchor = try legacySignedTransaction(
            chainPath: chainPath,
            genesisActions: [GenesisAction(
                directory: intent.directory,
                blockCID: intent.genesisCID,
                parentWorkAuthorityKey: authority
            )]
        )
        let _: SubmitTransactionResponse = try await parent.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: anchor)
        )
    }

    private func submitGenesisAnchor(
        on parent: E2ENode,
        intent: ChildDeployIntentResponse,
        chainPath: [String]
    ) async throws {
        let authority = try XCTUnwrap(
            ParentWorkAuthorityKey(parent.processPublicKey)
        )
        let anchor = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            chainPath: chainPath,
            genesisActions: [GenesisAction(
                directory: intent.directory,
                blockCID: intent.genesisCID,
                parentWorkAuthorityKey: authority
            )],
            nonce: 0
        )
        let _: SubmitTransactionResponse = try await parent.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: anchor)
        )
    }

    private func signedTransaction(
        key: (privateKey: String, publicKey: String),
        chainPath: [String],
        accountActions: [AccountAction] = [],
        actions: [Action] = [],
        depositActions: [DepositAction] = [],
        genesisActions: [GenesisAction] = [],
        receiptActions: [ReceiptAction] = [],
        withdrawalActions: [WithdrawalAction] = [],
        fee: UInt64 = 0,
        nonce: UInt64
    ) throws -> Transaction {
        try signedTransaction(
            keys: [key],
            chainPath: chainPath,
            accountActions: accountActions,
            actions: actions,
            depositActions: depositActions,
            genesisActions: genesisActions,
            receiptActions: receiptActions,
            withdrawalActions: withdrawalActions,
            fee: fee,
            nonce: nonce
        )
    }

    private func signedTransaction(
        keys: [(privateKey: String, publicKey: String)],
        chainPath: [String],
        accountActions: [AccountAction] = [],
        actions: [Action] = [],
        depositActions: [DepositAction] = [],
        genesisActions: [GenesisAction] = [],
        receiptActions: [ReceiptAction] = [],
        withdrawalActions: [WithdrawalAction] = [],
        fee: UInt64 = 0,
        nonce: UInt64
    ) throws -> Transaction {
        let body = TransactionBody(
            accountActions: accountActions,
            actions: actions,
            depositActions: depositActions,
            genesisActions: genesisActions,
            receiptActions: receiptActions,
            withdrawalActions: withdrawalActions,
            signers: keys.map { CryptoUtils.createAddress(from: $0.publicKey) },
            fee: fee,
            nonce: nonce,
            chainPath: chainPath
        )
        let header = try HeaderImpl(node: body)
        let signatures = try Dictionary(uniqueKeysWithValues: keys.map { key in
            let signature = try XCTUnwrap(TransactionSigning.sign(
                bodyHeader: header,
                privateKeyHex: key.privateKey
            ))
            return (key.publicKey, signature)
        })
        return Transaction(signatures: signatures, body: header)
    }

    private func legacySignedTransaction(
        chainPath: [String],
        genesisActions: [GenesisAction] = [],
        keySeed: UInt8? = nil
    ) throws -> Transaction {
        let key: (privateKey: String, publicKey: String)
        if let keySeed {
            let raw = Data(repeating: keySeed, count: 32)
            let privateKey = try Curve25519.Signing.PrivateKey(
                rawRepresentation: raw
            )
            key = (
                raw.map { String(format: "%02x", $0) }.joined(),
                "ed01" + privateKey.publicKey.rawRepresentation.map {
                    String(format: "%02x", $0)
                }.joined()
            )
        } else {
            key = CryptoUtils.generateKeyPair()
        }
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            genesisActions: genesisActions,
            receiptActions: [],
            withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)],
            fee: 0,
            nonce: 0,
            chainPath: chainPath
        )
        let header = try HeaderImpl(node: body)
        let signature = try XCTUnwrap(
            CryptoUtils.sign(message: header.rawCID, privateKeyHex: key.privateKey)
        )
        return Transaction(signatures: [key.publicKey: signature], body: header)
    }
}

private struct E2EMinedBlock {
    let template: MiningTemplateResponse
    let response: SubmitWorkResponse
    let blockCID: String
}

private struct E2ECoordinatorResult: Decodable {
    let result: String
    let accepted: Bool
    let disposition: String
    let tipCID: String?
}

private struct E2EWorkerResult: Decodable {
    let workId: String
    let status: String
    let nonce: UInt64?
}

private struct E2ESeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next(upperBound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(state % UInt64(upperBound))
    }
}

private extension Ivy {
    func installObserver(delegate: IvyDelegate) {
        self.delegate = delegate
    }
}

/// A real Ivy peer used only when an E2E assertion needs a causal wire event.
/// It speaks the normal overlay hello, but deliberately serves no content.
private actor E2EOverlayObserver: IvyDelegate {
    private static let overlayHelloTopic = "lattice.overlay.hello.v1"
    private static let blockAnnouncementTopic = "lattice.overlay.block.v1"

    private struct BlockAnnouncement: Decodable {
        let blockCID: String
    }

    private let ivy: Ivy
    private let hello: Data
    private let port: UInt16
    private let expectedPeerKey: String
    private var connectedPeer: AuthenticatedPeer?
    private var connectionCounts: [String: Int] = [:]
    private var announcementCounts: [String: Int] = [:]
    private var messageCounts: [String: Int] = [:]

    init(port: UInt16, bootstrapPeer: E2ENode.OverlayPeer, hello: ChainHello) throws {
        self.port = port
        expectedPeerKey = bootstrapPeer.publicKey
        self.hello = try hello.encode()
        ivy = Ivy(config: IvyConfig(
            signingKey: Curve25519.Signing.PrivateKey(),
            listenPort: port,
            bootstrapPeers: [PeerEndpoint(
                publicKey: bootstrapPeer.publicKey,
                host: "127.0.0.1",
                port: bootstrapPeer.port
            )],
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .privateNetwork
        ))
    }

    func start() async throws {
        await MainActor.run { E2EPorts.release([port]) }
        do {
            await ivy.installObserver(delegate: self)
            try await ivy.start()
        } catch {
            try? await MainActor.run { try E2EPorts.reserve([port]) }
            throw error
        }
    }

    func stop() async {
        await ivy.stop()
        await MainActor.run { E2EPorts.release([port]) }
    }

    func waitForConnection(
        to publicKey: String,
        after count: Int = 0,
        timeout: Duration = .seconds(10)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if connectionCount(to: publicKey) > count { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        throw E2EHTTPError(
            status: 0,
            body: "timed out waiting for observer connection to \(publicKey)"
        )
    }

    func waitForAnnouncement(
        of blockCID: String,
        after count: Int = 0,
        timeout: Duration = .seconds(10)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if announcementCount(of: blockCID) > count { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        throw E2EHTTPError(
            status: 0,
            body: "timed out waiting for observer announcement of \(blockCID)"
        )
    }

    func waitForMessage(
        topic: String,
        after count: Int = 0,
        timeout: Duration = .seconds(10)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if messageCounts[topic, default: 0] > count { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        throw E2EHTTPError(
            status: 0,
            body: "timed out waiting for observer message on \(topic)"
        )
    }

    func ivy(_ ivy: Ivy, didConnect peer: AuthenticatedPeer) async {
        if peer.key.hex == expectedPeerKey {
            connectedPeer = peer
            connectionCounts[peer.key.hex, default: 0] += 1
        }
        _ = await ivy.sendMessage(
            to: peer.id,
            topic: Self.overlayHelloTopic,
            payload: hello
        )
    }

    func ivy(_ ivy: Ivy, didReceiveMessage message: PeerMessage, from peer: AuthenticatedPeer) async {
        if message.topic == Self.overlayHelloTopic {
            let hello = hello
            Task {
                _ = await ivy.sendMessage(
                    to: peer.id,
                    topic: Self.overlayHelloTopic,
                    payload: hello
                )
            }
            return
        }
        if peer.key.hex == expectedPeerKey {
            messageCounts[message.topic, default: 0] += 1
        }
        guard message.topic == Self.blockAnnouncementTopic,
              peer.key.hex == expectedPeerKey,
              let announcement = try? JSONDecoder().decode(
                BlockAnnouncement.self,
                from: message.payload
              ) else {
            return
        }
        announcementCounts[announcement.blockCID, default: 0] += 1
    }

    func connectionCount(to publicKey: String) -> Int {
        connectionCounts[publicKey, default: 0]
    }

    func announcementCount(of blockCID: String) -> Int {
        announcementCounts[blockCID, default: 0]
    }

    func send(topic: String, payload: Data) async -> SendMessageResult {
        guard let connectedPeer else { return .notConnected }
        return await ivy.sendMessage(
            to: connectedPeer,
            topic: topic,
            payload: payload
        )
    }
}

private struct InventoryRequest: Encodable {
    let requestID: UInt64
    let afterRootCID: String?
}

private func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

private struct E2EHTTPError: Error, LocalizedError {
    let status: Int
    let body: String

    var errorDescription: String? {
        "HTTP \(status): \(body)"
    }
}

@MainActor
private final class E2ENode {
    private static let requestTimeout: TimeInterval = 5

    struct Parent {
        let publicKey: String
        let factPort: UInt16
    }

    struct OverlayPeer {
        let publicKey: String
        let port: UInt16
    }

    struct Configuration {
        let name: String
        let chainPath: String
        let storage: URL
        let identity: E2EIdentity
        let overlayPort: UInt16
        let factPort: UInt16
        let rpcPort: UInt16
        let overlayPeers: [OverlayPeer]
        let parent: Parent?

        init(
            name: String,
            chainPath: String,
            storage: URL,
            identity: E2EIdentity,
            overlayPort: UInt16,
            factPort: UInt16,
            rpcPort: UInt16,
            overlayPeers: [OverlayPeer] = [],
            parent: Parent? = nil
        ) {
            self.name = name
            self.chainPath = chainPath
            self.storage = storage
            self.identity = identity
            self.overlayPort = overlayPort
            self.factPort = factPort
            self.rpcPort = rpcPort
            self.overlayPeers = overlayPeers
            self.parent = parent
        }
    }

    private let binary: URL
    private let configuration: Configuration
    private let logDirectory: URL
    private var overlayPeers: [OverlayPeer]
    private var process: Process?
    private var logHandles: [FileHandle] = []
    private var launchCount = 0

    init(binary: URL, configuration: Configuration, logDirectory: URL) {
        self.binary = binary
        self.configuration = configuration
        self.logDirectory = logDirectory
        overlayPeers = configuration.overlayPeers
    }

    var processPublicKey: String {
        try! PeerKey(configuration.identity.publicKey).hex
    }

    func setOverlayPeers(_ peers: [OverlayPeer]) {
        precondition(process?.isRunning != true, "stop a node before changing its peers")
        overlayPeers = peers
    }

    func start() throws {
        guard process?.isRunning != true else { return }
        launchCount += 1
        try FileManager.default.createDirectory(
            at: configuration.storage,
            withIntermediateDirectories: true
        )
        let stdout = try openLog(named: "\(configuration.name)-\(launchCount).stdout.log")
        let stderr = try openLog(named: "\(configuration.name)-\(launchCount).stderr.log")
        let next = Process()
        next.executableURL = binary
        next.arguments = launchArguments()
        next.standardOutput = stdout
        next.standardError = stderr
        do {
            E2EPorts.release(reservedPorts)
            try next.run()
        } catch {
            try? E2EPorts.reserve(reservedPorts)
            try? stdout.close()
            try? stderr.close()
            throw error
        }
        process = next
        logHandles = [stdout, stderr]
    }

    func stop() async throws {
        guard let process else { return }
        var forced = false
        if process.isRunning {
            process.terminate()
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(5)
            while process.isRunning && clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning {
                forced = true
                _ = kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        let reason = process.terminationReason
        let status = process.terminationStatus
        self.process = nil
        closeLogs()
        try E2EPorts.reserve(reservedPorts)
        guard !forced, reason == .exit, status == 0 else {
            throw E2EHTTPError(
                status: Int(status),
                body: "node did not shut down cleanly: \(configuration.name)"
            )
        }
    }

    func forceTerminate() {
        guard let process else {
            closeLogs()
            return
        }
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        self.process = nil
        closeLogs()
        try? E2EPorts.reserve(reservedPorts)
    }

    func waitForExit(timeout: Duration = .seconds(10)) async throws -> Int32 {
        guard let process else {
            throw E2EHTTPError(status: 0, body: "node is not running")
        }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while process.isRunning && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !process.isRunning else {
            throw E2EHTTPError(
                status: 0,
                body: "node did not exit: \(configuration.name)"
            )
        }
        process.waitUntilExit()
        let status = process.terminationStatus
        self.process = nil
        closeLogs()
        try E2EPorts.reserve(reservedPorts)
        return status
    }

    func latestStandardError() throws -> String {
        try String(
            contentsOf: logDirectory.appendingPathComponent(
                "\(configuration.name)-\(launchCount).stderr.log"
            ),
            encoding: .utf8
        )
    }

    func suspend() throws {
        guard let process, process.isRunning else {
            throw E2EHTTPError(
                status: 0,
                body: "cannot suspend a stopped node: \(configuration.name)"
            )
        }
        guard kill(process.processIdentifier, SIGSTOP) == 0 else {
            throw E2EHTTPError(
                status: 0,
                body: "could not suspend node: \(configuration.name)"
            )
        }
    }

    func resume() throws {
        guard let process, process.isRunning else {
            throw E2EHTTPError(
                status: 0,
                body: "cannot resume a stopped node: \(configuration.name)"
            )
        }
        guard kill(process.processIdentifier, SIGCONT) == 0 else {
            throw E2EHTTPError(
                status: 0,
                body: "could not resume node: \(configuration.name)"
            )
        }
    }

    func releaseReservedPorts() {
        E2EPorts.release(reservedPorts)
    }

    func waitForStatus(
        timeout: Duration = .seconds(30),
        where predicate: @escaping (ChainServiceStatusResponse) -> Bool
    ) async throws -> ChainServiceStatusResponse {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var lastError: Error?
        var lastStatus: ChainServiceStatusResponse?
        while clock.now < deadline {
            let requestRemaining = clock.now.duration(to: deadline).components
            let requestTimeout = max(
                0.001,
                min(
                    Self.requestTimeout,
                    TimeInterval(requestRemaining.seconds)
                        + TimeInterval(requestRemaining.attoseconds) / 1e18
                )
            )
            do {
                let status = try await status(timeout: requestTimeout)
                lastStatus = status
                if predicate(status) { return status }
            } catch {
                lastError = error
                if let process, !process.isRunning { break }
            }
            let sleepRemaining = clock.now.duration(to: deadline)
            if sleepRemaining > .zero {
                try? await Task.sleep(
                    for: min(sleepRemaining, .milliseconds(100))
                )
            }
        }
        let observed = lastStatus.map {
            "phase=\($0.phase.rawValue), tip=\($0.tipCID ?? "nil"), height=\($0.height.map(String.init) ?? "nil"), mempool=\($0.mempoolCount)"
        } ?? "no status response"
        let lastFailure = lastError.map { "; last error: \($0.localizedDescription)" } ?? ""
        let processFailure: String
        if let process, !process.isRunning {
            processFailure = "; process exited with status \(process.terminationStatus) (\(process.terminationReason))"
        } else {
            processFailure = ""
        }
        throw E2EHTTPError(
            status: 0,
            body: "timed out waiting for \(configuration.name) status; \(observed)\(lastFailure)\(processFailure)"
        )
    }

    func post<Request: Encodable, Response: Decodable>(
        _ path: String,
        body: Request,
        timeout: TimeInterval? = nil
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request, timeout: timeout)
    }

    func get(_ path: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "GET"
        return try await sendData(request)
    }

    var rpcURL: URL {
        baseURL
    }

    private func status(
        timeout: TimeInterval? = nil
    ) async throws -> ChainServiceStatusResponse {
        var request = URLRequest(url: baseURL.appending(path: "/v1/status"))
        request.httpMethod = "GET"
        return try await send(request, timeout: timeout)
    }

    private var baseURL: URL {
        URL(string: "http://127.0.0.1:\(configuration.rpcPort)")!
    }

    private var reservedPorts: [UInt16] {
        [
            configuration.overlayPort,
            configuration.factPort,
            configuration.rpcPort,
        ]
    }

    private func send<Response: Decodable>(
        _ request: URLRequest,
        timeout: TimeInterval? = nil
    ) async throws -> Response {
        let data = try await sendData(request, timeout: timeout)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func sendData(
        _ request: URLRequest,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        var request = request
        request.timeoutInterval = timeout ?? Self.requestTimeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw E2EHTTPError(
                status: status,
                body: "\(request.httpMethod ?? "HTTP") \(request.url?.path ?? "request"): "
                    + String(decoding: data, as: UTF8.self)
            )
        }
        return data
    }

    private func launchArguments() -> [String] {
        var arguments = [
            "--chain-path", configuration.chainPath,
            "--data-directory", configuration.storage.path,
            "--identity-key", configuration.identity.file.path,
            "--minimum-root-work", "1",
            "--listen-port", String(configuration.overlayPort),
            "--fact-listen-port", String(configuration.factPort),
            "--rpc-port", String(configuration.rpcPort),
        ]
        if let parent = configuration.parent {
            arguments += ["--parent", "\(parent.publicKey)@127.0.0.1:\(parent.factPort)"]
        }
        for peer in overlayPeers {
            arguments += ["--peer", "\(peer.publicKey)@127.0.0.1:\(peer.port)"]
        }
        return arguments
    }

    private func openLog(named name: String) throws -> FileHandle {
        let url = logDirectory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try FileHandle(forWritingTo: url)
    }

    private func closeLogs() {
        for handle in logHandles {
            try? handle.close()
        }
        logHandles.removeAll()
    }
}

@MainActor
private final class E2ECluster {
    private var nodes: [E2ENode] = []

    func add(_ node: E2ENode) {
        nodes.append(node)
    }

    func stopAll() async throws {
        for node in nodes.reversed() {
            try await node.stop()
            node.releaseReservedPorts()
        }
    }

    func forceTerminateAll() {
        for node in nodes.reversed() {
            node.forceTerminate()
            node.releaseReservedPorts()
        }
    }
}

private struct E2EIdentity {
    let privateKey: String
    let publicKey: String
    let file: URL
}

private final class E2EWorkspace {
    let url: URL
    let logs: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-node-e2e-\(UUID().uuidString)",
            isDirectory: true
        )
        logs = url.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    }

    func makeIdentity(named name: String, seed: UInt8? = nil) throws -> E2EIdentity {
        let pair: (privateKey: String, publicKey: String)
        if let seed {
            let raw = Data(repeating: seed, count: 32)
            let privateKey = try Curve25519.Signing.PrivateKey(
                rawRepresentation: raw
            )
            pair = (
                raw.map { String(format: "%02x", $0) }.joined(),
                try PeerKey(
                    rawRepresentation: privateKey.publicKey.rawRepresentation
                ).hex
            )
        } else {
            pair = CryptoUtils.generateKeyPair()
        }
        let file = url.appendingPathComponent("\(name).key")
        try Data((pair.privateKey + "\n").utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )
        return E2EIdentity(
            privateKey: pair.privateKey,
            publicKey: pair.publicKey,
            file: file
        )
    }

    func remove() throws {
        try FileManager.default.removeItem(at: url)
    }
}

private enum E2EBinary {
    static func latticeNode() throws -> URL {
        try executable(environment: "E2E_NODE_BIN", product: "lattice-node")
    }

    static func latticeMiningCoordinator() throws -> URL {
        try executable(
            environment: "E2E_COORDINATOR_BIN",
            product: "lattice-mining-coordinator"
        )
    }

    static func latticeMiner() throws -> URL {
        try executable(environment: "E2E_MINER_BIN", product: "lattice-miner")
    }

    static func latticeProofVerifier() throws -> URL {
        try executable(
            environment: "E2E_PROOF_VERIFIER_BIN",
            product: "lattice-proof-verifier"
        )
    }

    private static func executable(
        environment variable: String,
        product: String
    ) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment[variable], !configured.isEmpty {
            let binary = URL(fileURLWithPath: configured).standardizedFileURL
            guard FileManager.default.isExecutableFile(atPath: binary.path) else {
                throw E2EHTTPError(
                    status: 0,
                    body: "\(variable) is not executable: \(binary.path)"
                )
            }
            return binary
        }
        if let node = environment["E2E_NODE_BIN"], !node.isEmpty {
            let binary = URL(fileURLWithPath: node)
                .deletingLastPathComponent()
                .appendingPathComponent(product)
                .standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: binary.path) {
                return binary
            }
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        let binary = repository.appendingPathComponent(
            ".build/\(configuration)/\(product)"
        )
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw E2EHTTPError(
                status: 0,
                body: "build \(product) first or set \(variable) (looked for \(binary.path))"
            )
        }
        return binary
    }
}

@MainActor
private enum E2EPorts {
    private static var reservations: [UInt16: Int32] = [:]

    static func allocate(count: Int) throws -> [UInt16] {
        var ports: [UInt16] = []
        do {
            while ports.count < count {
                let reservation = try reservePort(0)
                reservations[reservation.port] = reservation.descriptor
                ports.append(reservation.port)
            }
        } catch {
            release(ports)
            throw error
        }
        return ports.sorted()
    }

    static func reserve(_ ports: [UInt16]) throws {
        var added: [UInt16] = []
        do {
            for port in Set(ports) where reservations[port] == nil {
                let reservation = try reservePort(port)
                reservations[reservation.port] = reservation.descriptor
                added.append(reservation.port)
            }
        } catch {
            release(added)
            throw error
        }
    }

    static func release(_ ports: [UInt16]) {
        for port in Set(ports) {
            guard let descriptor = reservations.removeValue(forKey: port) else {
                continue
            }
            _ = close(descriptor)
        }
    }

    private static func reservePort(
        _ requestedPort: UInt16
    ) throws -> (port: UInt16, descriptor: Int32) {
        #if canImport(Darwin)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard descriptor >= 0 else {
            throw E2EHTTPError(status: 0, body: "could not allocate test port")
        }
        var reuseAddress: Int32 = 1
        let reuseResult = withUnsafePointer(to: &reuseAddress) {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        guard reuseResult == 0 else {
            _ = close(descriptor)
            throw E2EHTTPError(status: 0, body: "could not configure test port")
        }

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requestedPort.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            _ = close(descriptor)
            throw E2EHTTPError(status: 0, body: "could not bind test port")
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            _ = close(descriptor)
            throw E2EHTTPError(status: 0, body: "could not read test port")
        }
        return (UInt16(bigEndian: bound.sin_port), descriptor)
    }
}
