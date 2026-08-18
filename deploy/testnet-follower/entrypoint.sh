#!/bin/sh
# Public child-chain follower: one host running the parent (Nexus) and one
# child process under `lattice up --foreground` (PID 1, restarts on exit).
# The topology is declarative and rewritten every boot; identities and chain
# state persist on the /data volume (lattice-node creates missing identity
# keys itself).
#
# The child joins permissionlessly: CHILD_GENESIS_SEED (the deployer's seed
# JSON) is written once into the child's data directory; the node rebuilds
# the identical self-contained genesis from it and self-admits only after
# confirming the parent chain recorded that exact CID. The child's bounded
# public read surface (--public-read-port, enforced in code) is what makes
# the chain browsable; fly maps 443/80 to it.
set -eu

ROOT=/data
CHILD_PATH="${CHILD_PATH:?absolute child path, e.g. Nexus/testnet}"
CHILD_DIR="$ROOT/chains/$CHILD_PATH"
NEXUS_PEERS="${NEXUS_PEERS:?space-separated publicKey@host:port peers}"
# Optional overlay self-description. Ivy accepts IP LITERALS only (the
# browser-facing hostname stays a lattice-home concern; the protocol is
# name-free): set this to the app's dedicated public IPv4 so overlay
# announcements are dialable, or leave unset to announce nothing.
EXTERNAL_HOST="${EXTERNAL_HOST:-}"

mkdir -p "$CHILD_DIR"

peers_json=""
for peer in $NEXUS_PEERS; do
    peers_json="$peers_json\"$peer\","
done
peers_json="${peers_json%,}"

external_nexus=""
external_child=""
if [ -n "$EXTERNAL_HOST" ]; then
    external_nexus=",
      \"externalAddress\": \"$EXTERNAL_HOST\""
    external_child=",
      \"externalAddress\": \"$EXTERNAL_HOST\""
fi

cat > "$ROOT/lattice.json" <<EOF
{
  "chains": {
    "Nexus": {
      "listen": 4001,
      "fact": 4002,
      "rpc": 8080,
      "peers": [$peers_json]$external_nexus
    },
    "$CHILD_PATH": {
      "listen": 4101,
      "fact": 4102,
      "rpc": 8180,
      "publicRead": 8081$external_child
    }
  }
}
EOF

if [ -n "${CHILD_GENESIS_SEED:-}" ] && [ ! -f "$CHILD_DIR/child-genesis.json" ]; then
    printf '%s' "$CHILD_GENESIS_SEED" > "$CHILD_DIR/child-genesis.json"
fi

exec lattice up --root "$ROOT" --foreground
