#!/usr/bin/env bash
set -euo pipefail

iterations="${LATTICE_STRESS_ITERATIONS:-5}"
if [[ ! "$iterations" =~ ^[1-9][0-9]*$ ]]; then
  echo "LATTICE_STRESS_ITERATIONS must be a positive integer" >&2
  exit 2
fi
rounds="${LATTICE_STRESS_ROUNDS:-24}"
if [[ ! "$rounds" =~ ^[1-9][0-9]*$ ]] || (( rounds > 155 )); then
  echo "LATTICE_STRESS_ROUNDS must be between 1 and 155" >&2
  exit 2
fi

filter='ParentChildE2ETests/(testChildBootstrapsFromRestartedParentAndAdvancesInLiveRound|testIntermediateTargetMissStillCarriesGrandchildWork|testSamePathTransactionRelaysAndSurvivesSubmittingReplicaRestart|testMalformedOverlayPeerCannotBlockHonestTransactionProgress|testParentOutageRevokesNestedReadinessButKeepsTransactionIngress|testPortableContinuityWaitsForLiveParentWorkBeforeConsensus|testPureParentDescendantsDoNotReweightChildAfterPartitionHeal|testPureAncestorDescendantsDoNotReweightNestedChildren|testStoppedDirectChildDoesNotBlockHealthySiblingRound|testSamePathReplicaReorgsTieFromLosingSegmentBase|testSamePathReplicaRelaysHigherWorkAcrossRestartAndLateJoin|testVariableRateExchangeSurvivesAdversarialChildPool|testTwoChildExchangeSurvivesHeavierNexusForkAfterSettlement|testAbruptCrashReopensDurableMempoolAndAcceptedTip|testStoppedStoreBackupRestoresAndMismatchedHalfFailsClosed)'

for ((iteration = 1; iteration <= iterations; iteration++)); do
  echo "critical-path stress iteration $iteration/$iterations"
  swift test --skip-build --filter "$filter"

  for offset in 1 18 255; do
    seed=$((iteration * 1000 + offset))
    echo "seeded operational E2E seed $seed"
    LATTICE_E2E_SEED="$seed" LATTICE_E2E_ROUNDS="$rounds" swift test --skip-build \
      --filter 'ParentChildE2ETests/testSeededNexusReplicasReconcileAcrossRestartAndLateJoin'
  done
done
