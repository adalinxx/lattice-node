#!/bin/sh
# Container entrypoint for the one-chain node and external mining binaries.
#
#   docker run <image> --flags...                        -> lattice-node
#   docker run <image> lattice-node --flags...           -> lattice-node
#   docker run <image> lattice-mining-coordinator ...    -> coordinator
#   docker run <image> lattice-miner ...                 -> worker
#   docker run <image> lattice-proof-verifier ...        -> proof verifier
#
# Bare args (no leading binary name) default to lattice-node so existing
# `docker run <image> --listen-port 4001 ...`-style call sites keep working.
case "$1" in
  lattice-node) shift; exec lattice-node "$@" ;;
  lattice-mining-coordinator) shift; exec lattice-mining-coordinator "$@" ;;
  lattice-miner) shift; exec lattice-miner "$@" ;;
  lattice-proof-verifier) shift; exec lattice-proof-verifier "$@" ;;
  *) exec lattice-node "$@" ;;
esac
