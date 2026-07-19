import Foundation
import Lattice
import UInt256
import XCTest
import cashew
@testable import LatticeNode

private actor MiningTestStore: Fetcher, Storer, VolumeStorer {
    private var entries: [String: Data] = [:]

    func fetch(rawCid: String) async throws -> Data {
        guard let data = entries[rawCid] else {
            throw FetcherError.notFound(rawCid)
        }
        return data
    }

    func store(entries newEntries: [String: Data]) async throws {
        entries.merge(newEntries) { existing, _ in existing }
    }

    func store(volume: SerializedVolume) async throws {
        entries.merge(volume.entries) { existing, _ in existing }
    }

    func insert(_ data: Data, for cid: String) {
        entries[cid] = data
    }

    func allEntries() -> [String: Data] { entries }
}

private struct UnavailableMiningFetcher: Fetcher {
    func fetch(rawCid: String) async throws -> Data {
        throw FetcherError.notFound(rawCid)
    }
}

final class MiningTemplateBookTests: XCTestCase {
    func testTemplateUsesSetupFloorAndRejectsDuplicateChildDirectories() async throws {
        let fixture = try await chainFixture()
        let floor = UInt256(4)
        let book = MiningTemplateBook(
            chainPath: ["Nexus"],
            minimumRootWork: floor
        )

        let template = try await book.build(
            previous: fixture.genesis,
            transactions: [],
            children: [],
            timestamp: 1,
            fetcher: fixture.store
        )
        XCTAssertEqual(template.searchTarget, UInt256.max / floor)

        let child = DirectChildCandidate(
            directory: "Payments",
            block: fixture.genesis,
            searchTarget: UInt256.max,
            acquisitionEntries: try await acquisitionEntries(
                for: fixture.genesis,
                fetcher: fixture.store
            )
        )
        await XCTAssertThrowsErrorAsync(
            try await book.build(
                previous: fixture.genesis,
                transactions: [],
                children: [child, child],
                timestamp: 1,
                fetcher: fixture.store
            )
        ) { error in
            XCTAssertEqual(error as? MiningTemplateError, .duplicateChildDirectory)
        }
    }

    func testStateInvalidTransactionDoesNotSuppressWork() async throws {
        let fixture = try await chainFixture()
        let recipient = CryptoUtils.createAddress(
            from: CryptoUtils.generateKeyPair().publicKey
        )
        let valid = try signedTransaction(
            key: fixture.key,
            accountActions: [
                AccountAction(owner: fixture.owner, delta: -2),
                AccountAction(owner: recipient, delta: 1),
            ],
            fee: 1,
            nonce: 1
        )
        let stale = try signedTransaction(
            key: fixture.key,
            accountActions: [
                AccountAction(owner: fixture.owner, delta: -2_000),
                AccountAction(owner: recipient, delta: 1_999),
            ],
            fee: 1,
            nonce: 2
        )

        let template = try await MiningTemplateBook(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1)
        ).build(
            previous: fixture.genesis,
            transactions: [valid, stale],
            children: [],
            timestamp: 1,
            fetcher: fixture.store
        )
        let transactions = try XCTUnwrap(template.block.transactions.node)
        let included = try transactions.allKeysAndValues().values.compactMap {
            $0.node?.body.rawCID
        }

        XCTAssertEqual(included, [valid.body.rawCID])
    }

    func testStateFetchFailureIsNotMisclassifiedAsStaleTransaction() async throws {
        let fixture = try await chainFixture()
        let transaction = try signedTransaction(
            key: fixture.key,
            accountActions: [AccountAction(owner: fixture.owner, delta: -1)],
            fee: 1,
            nonce: 1
        )

        await XCTAssertThrowsErrorAsync(
            try await MiningTemplateBook(
                chainPath: ["Nexus"],
                minimumRootWork: UInt256(1)
            ).build(
                previous: fixture.genesis.withUnresolvedPostState(),
                transactions: [transaction],
                children: [],
                timestamp: 1,
                fetcher: UnavailableMiningFetcher()
            )
        ) { error in
            XCTAssertTrue(error is FetcherError)
        }
    }

    func testTemplateNeverSearchesAndOnlyAppliesSubmittedNonce() async throws {
        let fixture = try await chainFixture()
        let book = MiningTemplateBook(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1)
        )
        let template = try await book.build(
            previous: fixture.genesis,
            transactions: [],
            children: [],
            timestamp: 1,
            fetcher: fixture.store
        )

        XCTAssertEqual(template.block.nonce, 0)
        XCTAssertEqual(template.workID, try BlockHeader(node: template.block).rawCID)
        let submitted = try await book.candidate(workID: template.workID, nonce: 42)
        XCTAssertEqual(submitted.nonce, 42)
    }

    func testPreviewCannotBeSubmittedOrEvictIssuedWork() async throws {
        let fixture = try await chainFixture()
        let book = MiningTemplateBook(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1),
            capacity: 1
        )
        let issued = try await book.build(
            previous: fixture.genesis,
            transactions: [],
            children: [],
            timestamp: 1,
            fetcher: fixture.store
        )
        let preview = try await book.preview(
            previous: fixture.genesis,
            transactions: [],
            children: [],
            timestamp: 2,
            fetcher: fixture.store
        )
        XCTAssertNotEqual(preview.workID, issued.workID)

        await XCTAssertThrowsErrorAsync(
            try await book.candidate(workID: preview.workID, nonce: 0)
        ) { error in
            XCTAssertEqual(error as? MiningTemplateError, .unknownWork)
        }
        let submitted = try await book.candidate(
            workID: issued.workID,
            nonce: 42
        )
        XCTAssertEqual(submitted.nonce, 42)
    }

    func testFirstLiveTemplateWinsWorkIDMetadataCollision() async throws {
        let fixture = try await chainFixture(target: UInt256(1))
        let book = MiningTemplateBook(
            chainPath: ["Nexus"],
            minimumRootWork: UInt256(1)
        )
        let entries = try await acquisitionEntries(
            for: fixture.genesis,
            fetcher: fixture.store
        )
        var conflictingEntries = entries
        conflictingEntries[fixture.genesis.postState.rawCID] = try await fixture.store.fetch(
            rawCid: fixture.genesis.postState.rawCID
        )
        XCTAssertNotEqual(conflictingEntries, entries)

        let firstChild = DirectChildCandidate(
            directory: "Payments",
            block: fixture.genesis,
            searchTarget: .max,
            acquisitionEntries: entries
        )
        let conflictingChild = DirectChildCandidate(
            directory: "Payments",
            block: fixture.genesis,
            searchTarget: .max / UInt256(2),
            acquisitionEntries: conflictingEntries
        )
        let first = try await book.build(
            previous: fixture.genesis,
            transactions: [],
            children: [firstChild],
            timestamp: 1,
            fetcher: fixture.store
        )
        let conflicting = try await book.preview(
            previous: fixture.genesis,
            transactions: [],
            children: [conflictingChild],
            timestamp: 1,
            fetcher: fixture.store
        )
        XCTAssertEqual(conflicting.workID, first.workID)

        let issued = await book.issue(conflicting)
        XCTAssertEqual(issued.searchTarget, first.searchTarget)
        XCTAssertEqual(
            issued.childCandidates.first?.acquisitionEntries,
            entries
        )

        let rebuilt = try await book.build(
            previous: fixture.genesis,
            transactions: [],
            children: [conflictingChild],
            timestamp: 1,
            fetcher: fixture.store
        )
        XCTAssertEqual(rebuilt.searchTarget, first.searchTarget)
        XCTAssertEqual(
            rebuilt.childCandidates.first?.acquisitionEntries,
            entries
        )

        await book.invalidateAll()
        let shortLived = MiningTemplate(
            workID: first.workID,
            block: first.block,
            searchTarget: first.searchTarget,
            chainPath: first.chainPath,
            expiresAt: ContinuousClock.now + .milliseconds(250),
            childCandidates: first.childCandidates
        )
        _ = await book.issue(shortLived)
        let reused = await book.issue(MiningTemplate(
            workID: conflicting.workID,
            block: conflicting.block,
            searchTarget: conflicting.searchTarget,
            chainPath: conflicting.chainPath,
            expiresAt: ContinuousClock.now + .seconds(30),
            childCandidates: conflicting.childCandidates
        ))
        let response = MiningTemplateResponse(
            template: reused,
            maximumLifetimeMilliseconds: 30_000
        )
        XCTAssertLessThanOrEqual(response.expiresInMilliseconds, 250)

        await book.invalidateAll()
        _ = await book.issue(MiningTemplate(
            workID: first.workID,
            block: first.block,
            searchTarget: first.searchTarget,
            chainPath: first.chainPath,
            expiresAt: ContinuousClock.now - .seconds(1),
            childCandidates: first.childCandidates
        ))
        let replacement = await book.issue(MiningTemplate(
            workID: conflicting.workID,
            block: conflicting.block,
            searchTarget: conflicting.searchTarget,
            chainPath: conflicting.chainPath,
            expiresAt: ContinuousClock.now + .seconds(30),
            childCandidates: conflicting.childCandidates
        ))
        XCTAssertEqual(replacement.searchTarget, conflicting.searchTarget)
        XCTAssertEqual(
            replacement.childCandidates.first?.acquisitionEntries,
            conflictingEntries
        )
    }

    private func chainFixture(
        target: UInt256 = .max
    ) async throws -> (
        genesis: Block,
        store: MiningTestStore,
        key: (privateKey: String, publicKey: String),
        owner: String
    ) {
        let store = MiningTestStore()
        let key = CryptoUtils.generateKeyPair()
        let owner = CryptoUtils.createAddress(from: key.publicKey)
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 10,
            targetBlockTime: 1_000,
            initialReward: 100,
            halvingInterval: 10_000
        )
        let premine = try signedTransaction(
            key: key,
            accountActions: [AccountAction(
                owner: owner,
                delta: Int64(spec.premineAmount())
            )],
            fee: 0,
            nonce: 0
        )
        let result = try await BlockBuilder.buildGenesisWithTransition(
            spec: spec,
            transactions: [premine],
            timestamp: 0,
            target: target,
            fetcher: store
        )
        try await BlockHeader(node: result.block).storeBlock(storer: store)
        try await result.block.postState.storeRecursively(storer: store)
        return (result.block, store, key, owner)
    }
}

final class TransactionPoolArchitectureTests: XCTestCase {
    func testCheapTrustBoundaryChecksRunBeforeCryptography() async throws {
        let store = MiningTestStore()
        let key = CryptoUtils.generateKeyPair()
        let wrongPathBody = transactionBody(
            key: key,
            accountActions: [AccountAction(
                owner: CryptoUtils.createAddress(from: key.publicKey),
                delta: -1
            )],
            fee: 1,
            nonce: 0,
            chainPath: ["Nexus", "Wrong"]
        )
        let wrongPath = Transaction(
            signatures: [key.publicKey: "not-a-signature"],
            body: try HeaderImpl(node: wrongPathBody)
        )
        let pool = TransactionPool(maxSignatures: 1)

        await XCTAssertThrowsErrorAsync(
            try await pool.submit(
                wrongPath,
                chainPath: ["Nexus"],
                spec: testSpec(),
                fetcher: store,
                storer: store
            )
        ) { error in
            XCTAssertEqual(error as? TransactionPoolError, .wrongChainPath)
        }

        let tooManySignatures = Transaction(
            signatures: ["a": "x", "b": "y"],
            body: try HeaderImpl(node: wrongPathBody)
        )
        await XCTAssertThrowsErrorAsync(
            try await pool.submit(
                tooManySignatures,
                chainPath: ["Nexus"],
                spec: testSpec(),
                fetcher: store,
                storer: store
            )
        ) { error in
            XCTAssertEqual(error as? TransactionPoolError, .tooLarge)
        }

        let detached = try HeaderImpl(node: wrongPathBody).removingNode()
        let oversizedSignature = Transaction(
            signatures: [String(repeating: "a", count: 257): "x"],
            body: detached
        )
        await XCTAssertThrowsErrorAsync(
            try await pool.submit(
                oversizedSignature,
                chainPath: ["Nexus"],
                spec: testSpec(),
                fetcher: UnavailableMiningFetcher(),
                storer: store
            )
        ) { error in
            XCTAssertEqual(error as? TransactionPoolError, .tooLarge)
        }

        let smallSpec = testSpec(maxBlockSize: 1_024)
        await store.insert(Data(repeating: 0, count: 1_025), for: detached.rawCID)
        await XCTAssertThrowsErrorAsync(
            try await pool.submit(
                Transaction(signatures: [:], body: detached),
                chainPath: ["Nexus"],
                spec: smallSpec,
                fetcher: store,
                storer: store
            )
        ) { error in
            XCTAssertEqual(error as? TransactionPoolError, .tooLarge)
        }
        let count = await pool.count
        XCTAssertEqual(count, 0)
    }

    func testFeeRateOrderingUsesExactFullWidthProducts() async throws {
        let store = MiningTestStore()
        let pool = TransactionPool()
        let key = CryptoUtils.generateKeyPair()
        let owner = CryptoUtils.createAddress(from: key.publicKey)
        let mediumFee = UInt64(Int64.max)
        let highFee = mediumFee * 2
        let medium = try signedTransaction(
            key: key,
            accountActions: [AccountAction(owner: owner, delta: -Int64.max)],
            fee: mediumFee,
            nonce: 0
        )
        let high = try signedTransaction(
            key: key,
            accountActions: [
                AccountAction(owner: owner, delta: -Int64.max),
                AccountAction(owner: owner, delta: -Int64.max),
            ],
            fee: highFee,
            nonce: 1
        )
        let mediumSize = storedSize(of: medium)
        let highSize = storedSize(of: high)
        XCTAssertLessThan(highSize, mediumSize * 2)
        XCTAssertTrue(highFee.multipliedReportingOverflow(by: UInt64(mediumSize)).overflow)
        XCTAssertTrue(mediumFee.multipliedReportingOverflow(by: UInt64(highSize)).overflow)

        _ = try await pool.submit(
            medium,
            chainPath: ["Nexus"],
            spec: testSpec(),
            fetcher: store,
            storer: store
        )
        _ = try await pool.submit(
            high,
            chainPath: ["Nexus"],
            spec: testSpec(),
            fetcher: store,
            storer: store
        )

        let ordered = await pool.transactions(limit: 2).map(\.body.rawCID)
        XCTAssertEqual(ordered, [high.body.rawCID, medium.body.rawCID])
    }

    private func storedSize(of transaction: Transaction) -> Int {
        transaction.toData()!.count + transaction.body.node!.toData()!.count
    }
}

private func acquisitionEntries(
    for block: Block,
    fetcher: any Fetcher
) async throws -> [String: Data] {
    let collector = MiningTestStore()
    try await BlockHeader(node: block).storeBlock(
        fetcher: fetcher,
        storer: collector
    )
    return await collector.allEntries()
}

private func signedTransaction(
    key: (privateKey: String, publicKey: String),
    accountActions: [AccountAction],
    fee: UInt64,
    nonce: UInt64,
    chainPath: [String] = ["Nexus"]
) throws -> Transaction {
    let body = transactionBody(
        key: key,
        accountActions: accountActions,
        fee: fee,
        nonce: nonce,
        chainPath: chainPath
    )
    let header = try HeaderImpl(node: body)
    let signature = try XCTUnwrap(TransactionSigning.sign(
        bodyHeader: header,
        privateKeyHex: key.privateKey
    ))
    return Transaction(signatures: [key.publicKey: signature], body: header)
}

private func transactionBody(
    key: (privateKey: String, publicKey: String),
    accountActions: [AccountAction],
    fee: UInt64,
    nonce: UInt64,
    chainPath: [String]
) -> TransactionBody {
    TransactionBody(
        accountActions: accountActions,
        actions: [],
        depositActions: [],
        genesisActions: [],
        receiptActions: [],
        withdrawalActions: [],
        signers: [CryptoUtils.createAddress(from: key.publicKey)],
        fee: fee,
        nonce: nonce,
        chainPath: chainPath
    )
}

private func testSpec(maxBlockSize: Int = 1_000_000) -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        maxBlockSize: maxBlockSize,
        premine: 0,
        targetBlockTime: 1_000,
        initialReward: 100,
        halvingInterval: 10_000
    )
}

private extension Block {
    func withUnresolvedPostState() -> Block {
        Block(
            version: version,
            parent: parent,
            transactions: transactions,
            target: target,
            nextTarget: nextTarget,
            spec: spec,
            parentState: parentState,
            prevState: prevState,
            postState: postState.removingNode(),
            children: children,
            height: height,
            timestamp: timestamp,
            nonce: nonce
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {
        handler(error)
    }
}
