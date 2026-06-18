# SOTA Blockchain Testing Plan

Comprehensive test plan for lattice-node and Ivy. Inspired by Bitcoin Core (~40 p2p tests), CometBFT (e2e invariant suite), GossipSub (scoring/mesh tests), Ethereum Hive (protocol conformance), Jepsen (distributed systems correctness), and FoundationDB (deterministic simulation).

**Total: ~90 tests across 24 categories. Priority: P0 = catches real bugs / inflation / consensus splits. P1 = security. P2 = correctness / performance.**

Use this as a prompt to implement each section. All network tests use real TCP between nodes on localhost.

> **How to run:** See [`../SmokeTests/README.md`](../SmokeTests/README.md) for the executable smoke-test harness — the how-to-run companion to this plan.

---

## Test Infrastructure

Shared helpers (exist in `SmokeTests/scenarios`):
```swift
private func port() -> UInt16
private func makeNode(kp:port:dir:bootstrap:genesis:) async throws -> LatticeNode
private func genesis() -> GenesisConfig  // UInt256.max target = instant mining
private func spec() -> ChainSpec
```

Pattern: boot 2-3 real LatticeNode instances with real Ivy TCP, mine blocks, exercise the flow, verify invariants, stop all nodes.

---

## CATEGORY A: Difficulty Adjustment & Timewarp [P0] (3 tests)

These catch silent inflation bugs. Zero tests exist today.

### A1. testDifficultyAdjustmentBasic
- Mine one full adjustment window (120 blocks) with timestamps at half the target interval
- Verify `nextTarget` decreases (smaller target == harder)
- Repeat with double-spaced timestamps, verify it increases (larger target == easier)
- Compare against expected values from spec formula

### A2. testTimewarpAttackPrevention
- Build chain where last block of period N has timestamp = now + 2h (max allowed)
- First block of period N+1 has timestamp = last block of N-1
- Feed through block processing
- Verify the `target` does not rise (get easier) more than the expected max adjustment factor

### A3. testDifficultyNeverDropsToZero
- Build chain with blocks spaced days apart
- Call `calculateMinimumTarget` repeatedly
- Assert the `target` never reaches zero (a zero target would be impossible to satisfy)
- If no minimum exists in the code, this test reveals a missing safety check

---

## CATEGORY B: State Consistency [P0] (3 tests)

Catches consensus splits. Inspired by Jepsen's Tendermint findings.

### B1. testStateStoreRollbackConsistency
- Apply 10 `StateChangeset`s with known account changes
- Snapshot all balances at height 5
- Apply 5 more changesets
- Call `rollbackTo(height: 5)`
- Assert every account balance and nonce matches the snapshot exactly

### B2. testStateRootDeterminism
- Two nodes process the same blocks in the same order (single miner, sync to peer)
- Compare `block.postState.rawCID` at every height on both nodes
- Must be byte-identical — non-deterministic state roots cause consensus splits

### B3. testStateStoreAtomicityOnCrash
- Apply a changeset with 5 account updates
- Simulate crash by closing SQLite handle mid-transaction (before commit)
- Re-open database
- Verify no partial updates persisted (all-or-nothing)

---

## CATEGORY C: Eclipse Attack Resistance [P1] (2 tests)

### C1. testSubnetDiversityEnforcement
- Create 3 `PeerEndpoint`s with IPs in same /16 subnet (10.0.1.1, 10.0.1.2, 10.0.1.3)
- Call `shouldConnect` for each
- Verify the third returns false (maxPerSubnet=2)
- Add peer from different subnet (10.1.0.1), verify accepted

### C2. testEclipseWithAllSameSubnet
- Pass 100 candidates all in 192.168.0.0/16 to `selectDiversePeers` with maxNew=10
- Assert result count <= maxPerSubnet (2)

---

## CATEGORY D: Protocol Version / Fork Activation [P1] (2 tests)

### D1. testProtocolVersionIncompatibilityDisconnect
- Start two nodes, patch one to advertise unsupported version
- Verify the other refuses connection or ignores blocks
- Check `isCompatible(peerVersion:)` returns false

### D2. testForkActivationAtHeight
- Add test fork with `activationHeight: 100`
- Verify `activeForks(atHeight: 99)` does NOT include it
- Verify `activeForks(atHeight: 100)` includes it

---

## CATEGORY E: Transaction Pinning / Mempool Manipulation [P1] (3 tests)

### E1. testTransactionPinningViaLargeDescendant
- Submit tx A (low fee, nonce 0)
- Submit tx B (high fee, nonce 1, near MAX_TRANSACTION_SIZE)
- Try to RBF tx A
- Verify replacement succeeds (both A and B evicted)
- If it fails → pinning vulnerability found

### E2. testMempoolAccountLimitExhaustion
- Submit 64 txs from account A (fill maxPerAccount)
- Verify the 65th is rejected
- Submit tx from account B, verify accepted
- Total mempool count should be 65

### E3. testMempoolExpirationPruning
- Add 5 transactions
- Sleep past expiry duration
- Add 2 more (fresh)
- Call `pruneExpired`
- Verify first 5 removed, last 2 remain

---

## CATEGORY F: Selfish Mining Detection [P2] (1 test)

### F1. testOrphanBlockRateMonitoring
- Simulate peer sending 10 announcements where 6 are later orphaned
- Verify Tally penalizes this peer more than one with 1/10 orphan rate
- Note: may require adding orphan tracking to Tally

---

## CATEGORY G: Reorg Safety [P0] (3 tests)

### G1. testReorgDepthLimit
- Build two chains diverging 150 blocks back
- Reconnect nodes
- Verify node does NOT adopt the longer chain (exceeds maxReorgDepth=100)
- Verify node continues on original chain

### G2. testLocalFinalityGuardRejectsDeepReorg
- Set the node's local finality guard (`--finality-confirmations` = 6; and/or the `maxReorgDepth` bound)
- Mine 20 blocks
- Create an alternative chain forking at height 10 (below the local finality horizon)
- Attempt to feed the fork to the node
- Verify the node refuses to reorg below its **local** horizon — a **node-local policy/guard, not protocol consensus finality**. The consensus rule itself permits any-depth reorgs; a fork *within* the horizon carrying heavier `trueCumWork` still reorgs.

### G3. testReorgRecoversMempoolTransactions
- Mine blocks with 3 user transactions on chain A
- Create chain B (longer) without those 3 txs
- Trigger reorg to chain B
- Verify all 3 transactions return to mempool

---

## CATEGORY H: Parallel Block Fetcher [P2] (2 tests)

### H1. testParallelFetcherTimeoutRecovery
- Create mock Fetcher that never returns for one CID
- Call `fetchBlocks` with 100ms timeout
- Verify error thrown within 200ms (not hung)

### H2. testParallelFetcherCancellation
- Start `fetchBlocks` with 100 CIDs
- Cancel parent task after 10 complete
- Verify no more `storeFn` calls occur

---

## CATEGORY I: State Expiry [P1] (2 tests)

### I1. testExpireAndReviveAccount
- Create account with balance 1000, expire it
- Verify `getBalance` returns nil
- Revive with correct proof data, verify balance restored
- Try revive with garbage proof, verify failure

### I2. testExpiredAccountCannotTransact
- Create account, expire it
- Submit transaction debiting from expired address
- Verify validator rejects with `balanceMismatch`

---

## CATEGORY J: Chaos / Liveness Under Degradation [P1] (2 tests)

### J1. testMiningContinuesDuringPeerChurn
- Start a miner node
- In loop: connect peer, wait 2s, disconnect — for 30 seconds
- Verify chain height increased throughout (mining never stalled)

### J2. testSlowPeerDoesNotStallSync
- Set up 3 source nodes, one with artificial 500ms delay
- Sync fresh node from all 3
- Verify sync completes in reasonable time (not bottlenecked by slow peer)

---

## CATEGORY K: Coinbase Overflow Protection [P0] (2 tests)

Bitcoin's CVE-2010-5139 created 184 billion BTC from overflow.

### K1. testCoinbaseRewardPlusFeesOverflow
- Set `reward = UInt64.max - 10` and `totalFees = 100`
- Call `buildCoinbaseTransaction`
- Verify returns nil (overflow detected)

### K2. testCoinbaseBalanceOverflow
- Set miner currentBalance to `UInt64.max - 5` and payout to 10
- Verify coinbase returns nil (would overflow balance)

---

## CATEGORY L: Block Validation Completeness [P1] (2 tests)

### L1. testBlockWithDuplicateTransaction
- Construct block with same tx CID appearing twice
- Submit to node
- Verify rejection

### L2. testBlockWithGenesisIndexReuse
- Build block with `height: 0` and non-nil `parent`
- Submit to peer
- Verify rejection and `tally.recordFailure` called

---

## CATEGORY M: Performance Benchmarks [P2] (3 tests)

### M1. testBlockValidationThroughput
- Pre-build 1000 blocks in memory
- Time `processBlockAndRecoverReorg` for all 1000
- Assert < 10 seconds (100 blocks/sec minimum)

### M2. testMempoolInsertionThroughput
- Build 10,000 txs with random fees
- Time inserting all into NodeMempool
- Assert < 10 seconds
- Profile sorted insertion (O(n) per insert → possible bottleneck)

### M3. testStateDatabaseWriteThroughput
- Generate 100 StateChangesets, 100 account updates each
- Time `applyBlock` for all 100
- Assert < 5 seconds (2000 updates/sec minimum)

---

## CATEGORY 1: Invalid Data Handling [P1] (9 tests)

### 1a. testInvalidBlockRejected
Send garbage bytes as block, verify node doesn't crash, continues mining.

### 1b. testOversizedBlockRejected
Send 2MB block (max is 1MB), verify rejection.

### 1c. testFutureTimestampBlockRejected
Build block with timestamp 3 hours in future, verify `isBlockTimestampValid` rejects.

### 1d. testBlockWithWrongPreviousHash
Build block pointing to non-existent previous, verify not accepted.

### 1e. testInvalidSignatureTransactionRejected
Submit tx with garbage signature, verify rejected without crash.

### 1f. testBalanceNotConservedRejected
Create tx where debits != credits + fee, verify `.balanceNotConserved`.

### 1g. testTransactionTooLargeRejected
Create tx body > 100KB, verify `.transactionTooLarge`.

### 1h. testExpiredNonceRejected
Set confirmed nonce to 5, submit nonce 3, verify `.nonceAlreadyUsed`.

### 1i. testFarFutureNonceRejected
Submit nonce 10000 (> MAX_NONCE_DRIFT), verify `.nonceFromFuture`.

---

## CATEGORY 2: Economic Invariants [P1] (7 tests)

### 2a. testCoinbaseRewardMatchesSpec
Verify halving schedule: reward(0)=1024, reward(halvingInterval)=512, reward(2*halvingInterval)=256.

### 2b. testMinerBalanceEqualsSumOfRewards
Mine N blocks, verify balance == sum(rewardAtBlock(1...N)).

### 2c. testTotalSupplyConservation
Mine blocks with transfers, query all balances, verify total == premine + sum(rewards) - fees.

### 2d. testFeeGoesToMiner
Submit tx with fee=10, mine block including it, verify miner balance == reward + fee.

### 2e. testMempoolFeeEviction
Fill mempool, submit high-fee tx, verify lowest evicted, size stays at max.

### 2f. testNonceGapPreventsSelection
Add nonces [0, 2, 3], select for block, only nonce 0 selected.

### 2g. testRBFReplacementAndRejection
Replace tx at same nonce with 10% higher fee → success. Same fee → rejected.

---

## CATEGORY 3: Gossip Protocol [P1] (6 tests)

### 3a. testAnnouncementReachesAllPeers
3-node line: A→B→C, A announces, verify C receives.

### 3b. testTransactionGossipWithBody
Submit tx on A, verify arrives in B's mempool with intact body.

### 3c. testDuplicateAnnouncementSuppression
Two peers announce same CID, verify single processing.

### 3d. testNoEchoBackToSender
Node A announces to B, verify A doesn't receive echo.

### 3e. testGossipUnderLoad
100 announcements rapidly, verify no crash.

### 3f. testGossipTopicIsolation
Send "mempool" and "newBlock" simultaneously, verify correct handlers.

---

## CATEGORY 4: Sync Protocol [P2] (5 tests)

### 4a. testFreshNodeSyncsFromPeer
Node 1 mines 20 blocks, node 2 connects, verify catch-up.

### 4b. testSnapshotSync
ChainSyncer with 100 blocks, retentionDepth=20, verify correct retention.

### 4c. testFullSyncValidatesPoW
Full sync 50 blocks, verify cumulative work, verify chain accepts new blocks.

### 4d. testStateRebuildAfterSync
After sync, verify all account balances match postState state.

### 4e. testSyncPeerVerification
After sync, verify `verifySyncWithPeers` reports consistent state.

---

## CATEGORY 5: Consensus & Reorg [P0] (5 tests)

### 5a. testPartitionAndHeal
Two nodes mine independently, reconnect, verify convergence.

### 5b. testCompetingForksResolve
Two connected miners, verify heights converge within 3-5 blocks.

### 5c. testBlockConsistencyInvariant
Single miner + 2 nodes, verify identical block hashes at every height.

### 5d. testChainHeightMonotonicallyIncreases
Poll height every second during mining, verify never decreases.

### 5e. testFinalityEndpoint
Verify `/api/finality/{height}` returns the correct confirmation **depth** and the node's local `isFinal` status under its configured policy — a node-local guard, not protocol finality (the consensus rule permits any-depth reorgs).

---

## CATEGORY 6: Transaction Lifecycle [P0] (4 tests)

### 6a. testFullTransactionLifecycle
Submit → mine → confirm → mempool prune → balance update.

### 6b. testTransactionStatePropagatesAcrossNodes
Mine + submit on node 1, verify receiver balance on node 2.

### 6c. testRPCTransactionLifecycle
POST /transaction → mine → GET /receipt → verify balance via GET.

### 6d. testTransactionHistory
Mine blocks with txs, query GET /api/transactions/{addr}, verify history.

---

## CATEGORY 7: Reputation & Trust [P1] (5 tests)

### 7a. testTallyScoreDecreasesAfterFailures
Record 3 failures, verify reputation decreased.

### 7b. testTallyGatingBlocksBadPeers
Record enough failures that `shouldAllow` returns false.

### 7c. testCreditLineEstablishedOnConnect
Two nodes connect via TCP, verify credit lines exist with threshold > 0.

### 7d. testCreditLineTracksRelayFees
Fee-based retrieval, verify earning/spending balances changed.

### 7e. testSettlementViaMiningProof
Mine a block, verify credit line balance improved.

---

## CATEGORY 8: Peer Management [P2] (4 tests)

### 8a. testPeerChurn
10 rapid connect/disconnects, hub stays alive.

### 8b. testBootstrapAutoConnect
Node with bootstrap peers auto-connects.

### 8c. testPeerPersistenceAcrossRestart
Connect, stop, restart, verify persisted peers loaded.

### 8d. testDisconnectAndReconnect
Connect, disconnect, reconnect, verify data flows.

---

## CATEGORY 9: RPC Conformance [P2] (6 tests)

### 9a. testAllEndpointsReturnValidJSON
Hit every endpoint, verify 200 + valid JSON.

### 9b. testBalanceQueryCorrectData
Mine, query balance, verify matches expected rewards.

### 9c. testBlockQueryByIndexAndHash
Query by index and by hash, verify same block.

### 9d. testMempoolReflectsSubmissions
Submit tx → count=1. Mine → count=0.

### 9e. testFeeEstimationTracksBlocks
Mine blocks with varying fees, verify estimate is reasonable.

### 9f. testPrometheusMetrics
Verify `lattice_chain_height`, `lattice_blocks_accepted_total`, `lattice_mempool_size`.

---

## CATEGORY 10: Network Edge Cases [P2] (5 tests)

### 10a. testReconnectAfterLongOffline
Node goes offline, peer mines many blocks, node reconnects and catches up.

### 10b. testBurstAnnouncements
50 announcements rapidly, verify no crash or resource exhaustion.

### 10c. testLargeBlockPropagation
Mine block near maxBlockSize, verify propagation to peer.

### 10d. testEmptyBlockMining
Mine with empty mempool, verify valid blocks (coinbase only).

### 10e. testConcurrentMiningAndTxSubmission
Mine continuously while submitting txs in parallel, verify no crashes.

---

## CATEGORY 11: Ivy Protocol Layer [already implemented] (14 tests)

11a-11n: TCP connect, fee retrieval, 3-node relay, caching, pin discovery, mesh, disconnect/reconnect, large message, concurrent requests, invalid injection, dedup, churn, no-echo.

---

## CATEGORY N: Multi-Chain / Merged Mining [P0] (6 tests)

The core innovation of Lattice — child chains inheriting parent PoW — has zero dedicated network tests.

### N1. testChildChainGenesisDiscovery
- Mine a Nexus block containing a GenesisAction for a new child chain
- Verify the child process discovers the chain through parent-chain block extraction
- Verify the child chain network is auto-registered
- Verify child chain is at height 0 with correct genesis

### N2. testChildBlockEmbeddedInParentPropagates
- Mine a Nexus block with an embedded child block on node 1
- Verify node 2 receives both the parent and child block
- Verify child chain height advances on node 2

### N3. testChildChainIndependentState
- Mine blocks on both Nexus and a child chain
- Submit a transfer on the child chain
- Verify child state changes don't affect Nexus state
- Verify Nexus state changes don't affect child state

### N4. testParentReorgDoesNotRollbackChildState
- Two nodes mine different parent chains (partition)
- Parent reorg occurs on reconnect
- Verify child chain state does not roll back merely because parent canonicity changed
- Verify any child fork-choice change is explained by a child-local heavier
  `trueCumWork` fork or a newly verified proof contribution, not by treating the
  parent's canonical tip as an authority over child state
- Verify parent bytes/state roots used by the child are availability inputs:
  content-addressing, PoW, child-inclusion proofs, and parent-state continuity
  proofs must verify before they affect the child

### N5. testMinerContextsRefreshForNewChildChains
- Start mining on Nexus
- While mining, discover a new child chain
- Verify the next mined block includes the new child chain
- (Tests the childContextProvider closure refresh on the block-template path — the external miner pulls the refreshed template; there is no in-node mining loop)

### N6. testChildChainPersistsAcrossRestart
- Mine with a child chain, stop node
- Restart node
- Verify child chain state is restored from persisted data
- Verify child network is re-registered

---

## CATEGORY O: Ivy Economic Flow E2E [P0] (5 tests)

The full Ivy economic loop has never been tested end-to-end over real TCP.

### O1. testCreditLineGrowsWithSettlement
- Two nodes connected via TCP
- Node 1 mines blocks and calls `settleWithCreditors`
- Verify node 2's credit line threshold for node 1 increased
- Verify the growth is logarithmic (second settlement grows less than first)

### O2. testDepletedCreditLinePreventsRetrieval
- Two nodes connected, node 2 has data node 1 needs
- Exhaust node 1's credit line with node 2 (many requests)
- Verify subsequent `get(cid:target:)` fails (feeExhausted)
- Mine a block (settlement), verify retrieval works again

### O3. testPinAnnounceDiscoverFetchEarnLoop
- Node 1 stores data and publishes pin announcement
- Node 2 discovers node 1 as pinner via `discoverPinners`
- Node 2 fetches data from node 1 via targeted `get(cid:target:)`
- Verify node 1 earned credits from the serving

### O4. testStorageAdvertisingAndPinRequest
- Node 1 advertises available storage via gossip
- Node 2 sends a "pinRequest" peerMessage with a CID
- Verify node 1 fetches the data from node 2 and stores it
- Verify node 1 publishes a pin announcement for the new data

### O5. testRelayCachingUpgradesRevenue
- Chain: A→B→C, data only on A
- C requests via B (relay), B earns relayFee
- C requests same data again, B serves from cache, B earns full fee
- Verify B's second earning > first earning

---

## CATEGORY P: CAS Integrity [P1] (5 tests)

Content-addressable storage is the foundation. Integrity failures corrupt everything.

### P1. testCIDMismatchDetected
- Store data under a CID that doesn't match its content
- Read it back via `getLocal`
- Verify VerifiedDistanceStore rejects it (CID verification fails)

### P2. testCorruptDataOnDiskAutoRemoved
- Store valid data via DiskCASWorker
- Overwrite the file with garbage bytes
- Read via `getLocal` with `verifyReads: true`
- Verify returns nil and the corrupt file is deleted

### P3. testWorkerChainTraversal
- Set up memory → disk composite
- Store data in disk only (not memory)
- `get()` should find it in disk and backfill to memory
- Second `get()` should hit memory (faster path)

### P4. testCIDv1FormatConsistencyAcrossStack
- Compute CID for the same data via Acorn's `ContentIdentifier(for:)`
- Compute CID via Cashew's `HeaderImpl(node:).rawCID`
- Verify they produce identical CID strings

### P5. testBloomFilterPersistenceAndReload
- Store 1000 entries in DiskCASWorker
- Call `persistState()`
- Create a new DiskCASWorker at the same directory
- Verify `has(cid:)` returns true for all 1000 entries (bloom filter loaded)

---

## CATEGORY Q: Wire Protocol Edge Cases [P1] (4 tests)

### Q1. testMaximumMessageSizeHandling
- Send a message exactly at the 64MB frame limit
- Verify it's processed (or gracefully rejected, but no crash)

### Q2. testIdentifyWithWrongPublicKey
- Node connects and sends an identify message with a public key that doesn't match
- Verify the connection is rejected or the peer is remapped correctly

### Q3. testConnectionTimeoutOnUnresponsivePeer
- Start an Ivy node but connect to a port that accepts TCP but never sends identify
- Verify the connection attempt times out (doesn't hang forever)

### Q4. testMessageDeserializationWithEveryTag
- For every valid message tag (0-52), construct a minimal valid message
- Serialize and deserialize
- Verify roundtrip correctness for every message type

---

## CATEGORY R: Block Builder Correctness [P0] (4 tests)

### R1. testBlockWithMaxTransactions
- Build a block with exactly `spec.maxNumberOfTransactionsPerBlock` transactions
- Verify it's valid
- Build one with maxTransactions + 1, verify rejected

### R2. testBlockTimestampMustBeAfterParent
- Build a block with timestamp <= parent's timestamp
- Verify `validateTimestamp` returns false

### R3. testProofOfWorkHashComputationMatchesValidation
- Build a block, compute `proofOfWorkHash()`
- Compare with the hash computed by `validateProofOfWork`
- They must use the exact same input (including nonce)

### R4. testGenesisBlockDeterministic
- Call `NexusGenesis.create()` twice with same fetcher
- Verify block hashes are identical
- Verify genesis matches the expected hardcoded hash

---

## CATEGORY S: Light Client [P2] (3 tests)

### S1. testSparseMerkleProofGenerationAndVerification
- Mine blocks with account balances
- Generate a balance proof via `getBalanceProof(address:)`
- Verify the proof contains the state root, account root, and balance
- Verify it's a valid JSON structure

### S2. testHeaderChainDownloadValidatesPoW
- Build a 50-block chain, download headers via HeaderChain
- Verify every header's PoW is validated
- Inject a header with invalid PoW, verify download fails

### S3. testLightClientHeadersEndpoint
- Mine blocks, query GET /api/light/headers?from=0&to=10
- Verify returns headers with correct count and heights

---

## CATEGORY T: Concurrency / Actor Safety [P1] (4 tests)

### T1. testConcurrentBlockSubmissions
- Submit 10 blocks simultaneously to the same node (via Task group)
- Verify no crashes, chain height advances correctly
- Verify no duplicate blocks accepted

### T2. testMiningWhileProcessingReceivedBlocks
- Node 1 mines while node 2 sends blocks from a different fork
- Verify node 1 handles both mining output and incoming blocks without deadlock

### T3. testSimultaneousRPCRequests
- Send 50 concurrent HTTP requests to different RPC endpoints
- Verify all return valid responses (no 500 errors, no timeouts)

### T4. testStateStoreReadDuringWrite
- In parallel: apply a StateChangeset AND query balance for the same address
- Verify no crash (SQLite handles concurrent reads in WAL mode)
- Verify the read returns either the old or new value (not garbage)

---

## CATEGORY U: Data Persistence Edge Cases [P1] (4 tests)

### U1. testChainStateSurvivesUncleanShutdown
- Mine blocks, DON'T call `stop()` (simulate crash)
- Create new node at same data directory
- Verify chain state is recovered from the last persisted state

### U2. testSQLiteWALRecovery
- Apply a changeset, force-close the SQLite handle
- Re-open the database
- Verify either the full changeset committed or none of it did

### U3. testDiskCASWorkerSurvivesCorruption
- Write valid data, then corrupt 1 random file in the shard directory
- Create new DiskCASWorker at same directory
- Verify it initializes successfully (corrupt entry ignored during scan)

### U4. testMempoolPersistenceRoundtrip
- Add 10 txs to mempool, persist to disk
- Load from disk, verify 10 serialized txs recovered
- Verify CIDs match originals

---

## CATEGORY V: Ivy Advanced Protocol [P2] (4 tests)

### V1. testPeerExchange
- Three nodes: A connected to B, C connected to B
- Trigger PEX on B
- Verify A discovers C via peer exchange (or vice versa)

### V2. testZoneSyncReplication
- Node 1 has data in a DHT zone
- Node 2 joins the same zone
- Verify zone sync copies relevant CIDs to node 2

### V3. testHealthMonitorDisconnectsUnhealthyPeer
- Connect a peer that never responds to pings
- Verify health monitor eventually marks it unhealthy
- Verify it gets disconnected

### V4. testSTUNObservedAddressDiscovery
- Two nodes exchange identify messages
- Verify `didDiscoverPublicAddress` fires with the observed address

---

## Implementation Priority

| Priority | Categories | Test Count | What It Catches |
|----------|-----------|------------|-----------------|
| **P0** | A (difficulty), B (state), G (reorg), K (coinbase), N (multi-chain), O (Ivy economics), R (block builder), 5 (consensus), 6 (tx lifecycle) | 36 | Inflation, consensus splits, data loss, child chain corruption |
| **P1** | C (eclipse), D (protocol), E (pinning), I (expiry), J (chaos), L (block validation), P (CAS integrity), Q (wire protocol), T (concurrency), U (persistence), 1 (invalid data), 2 (economics), 3 (gossip), 7 (reputation) | 62 | Security, economic attacks, data corruption, network isolation |
| **P2** | F (selfish mining), H (fetcher), M (performance), S (light client), V (Ivy advanced), 4 (sync), 8 (peers), 9 (RPC), 10 (edge cases) | 32 | Regression, performance, conformance |
| **Total** | **30 categories** | **~130** | |

## Already Implemented

~39 tests exist across `SmokeTests/scenarios`, `ConfidenceTests.swift`, `TCPIntegrationTests.swift`, and the Ivy `NetworkRobustnessTests`. Cross-reference when implementing to avoid duplicates. Remaining to implement: ~91 new tests.

| Priority | Categories | Test Count | What It Catches |
|----------|-----------|------------|-----------------|
| **P0** | A (difficulty), B (state), G (reorg), K (coinbase), 5 (consensus), 6 (tx lifecycle) | 20 | Inflation, consensus splits, data loss |
| **P1** | C (eclipse), D (protocol), E (pinning), I (expiry), J (chaos), L (block validation), 1 (invalid data), 2 (economics), 3 (gossip), 7 (reputation) | 42 | Security, economic attacks, network isolation |
| **P2** | F (selfish mining), H (fetcher), M (performance), 4 (sync), 8 (peers), 9 (RPC), 10 (edge cases) | 28 | Regression, performance, conformance |
| **Total** | 24 categories | **90** | |

## Already Implemented

~39 tests exist across `SmokeTests/scenarios`, `ConfidenceTests.swift`, `TCPIntegrationTests.swift`, and the Ivy `NetworkRobustnessTests`. Cross-reference when implementing to avoid duplicates.
