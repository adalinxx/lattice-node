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
case "$1" in
  lattice-node)  shift; exec lattice-node  "$@" ;;
  lattice-miner) shift; exec lattice-miner "$@" ;;
  *)             exec lattice-node "$@" ;;
esac
