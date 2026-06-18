#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLANG_BIN="${CLANG_BIN:-clang}"

if ! command -v "$CLANG_BIN" >/dev/null 2>&1; then
  echo "clang not found; set CLANG_BIN or install clang" >&2
  exit 1
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

SEED="$TMPDIR/analyzer_seed.c"
SEED_LOG="$TMPDIR/analyzer_seed.log"
cat > "$SEED" <<'EOF'
int analyzer_seed(int trigger) {
    int *value = 0;
    if (trigger) {
        return *value;
    }
    return 0;
}
EOF

"$CLANG_BIN" --analyze -Xanalyzer -analyzer-output=text "$SEED" >"$SEED_LOG" 2>&1 || true
if ! grep -Eq "Dereference of null pointer|null pointer" "$SEED_LOG"; then
  echo "clang analyzer seed did not produce the expected null-dereference diagnostic" >&2
  cat "$SEED_LOG" >&2
  exit 1
fi

ANALYZER_LOG="$TMPDIR/analyzer.log"
: > "$ANALYZER_LOG"

SOURCES=()
while IFS= read -r source; do
  if grep -Ev '^[[:space:]]*(//|/\*|\*/|\*|$)' "$ROOT/$source" >/dev/null; then
    SOURCES+=("$source")
  fi
done < <(cd "$ROOT" && find Sources -name '*.c' -print | sort)
if [ "${#SOURCES[@]}" -eq 0 ]; then
  echo "clang analyzer seed passed; no non-empty first-party C sources to analyze"
  exit 0
fi

invocation_failed=0
for source in "${SOURCES[@]}"; do
  if ! (
    cd "$ROOT"
    "$CLANG_BIN" --analyze \
      -Xanalyzer -analyzer-output=text \
      -I Sources/CSQLite/include \
      "$source"
  ) >>"$ANALYZER_LOG" 2>&1; then
    echo "clang analyzer invocation failed for $source" >>"$ANALYZER_LOG"
    invocation_failed=1
  fi
done

if [ "$invocation_failed" -ne 0 ]; then
  echo "clang analyzer failed to analyze first-party C sources" >&2
  cat "$ANALYZER_LOG" >&2
  exit 1
fi

if grep -Eq "warning:|error:" "$ANALYZER_LOG"; then
  echo "clang analyzer reported diagnostics in first-party C sources" >&2
  cat "$ANALYZER_LOG" >&2
  exit 1
fi

echo "clang analyzer seed and non-empty first-party C analysis passed"
