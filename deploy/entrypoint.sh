#!/bin/sh
# Container entrypoint that dispatches to either binary, so one image can run
# a node or the external miner. Block production is NOT in the node — the
# miner is a separate process — but both ship in the same image.
#
#   docker run <image> --flags...                 -> lattice-node  --flags   (back-compat)
#   docker run <image> lattice-node  --flags...   -> lattice-node  --flags
#   docker run <image> lattice-miner --flags...   -> lattice-miner --flags
#
# Bare args (no leading binary name) default to lattice-node so existing
# `docker run <image> --port 4001 ...`-style call sites keep working.

# Optionally co-locate a mining coordinator with the node in the same container.
# It reads the node's local /data/.cookie for admin RPC (the secret never leaves
# the machine) and mines against 127.0.0.1. Enable by setting
# COLOCATED_MINER_WORKERS to a positive worker count.
start_colocated_miner() {
  [ -n "$COLOCATED_MINER_WORKERS" ] || return 0
  (
    # Wait until the node has written its RPC cookie and the RPC port (8080 =
    # 0x1F90) is listening (state 0A in /proc/net/tcp).
    while [ ! -s /data/.cookie ] || ! grep -qi ':1F90 .* 0A' /proc/net/tcp 2>/dev/null; do
      sleep 2
    done
    sleep 3
    exec lattice-mining-coordinator \
      --node http://127.0.0.1:8080/api \
      --rpc-cookie-file /data/.cookie \
      --worker-executable /usr/local/bin/lattice-miner \
      --workers "$COLOCATED_MINER_WORKERS"
  ) &
}

case "$1" in
  lattice-node)  shift; start_colocated_miner; exec lattice-node  "$@" ;;
  lattice-miner) shift; exec lattice-miner "$@" ;;
  lattice-mining-coordinator) shift; exec lattice-mining-coordinator "$@" ;;
  *)             start_colocated_miner; exec lattice-node "$@" ;;
esac
