#!/usr/bin/env bash
# Build release binaries twice from clean, canonical Linux containers and require
# byte-identical SHA-256 outputs. This is the same check operators can run
# against a tagged source checkout before trusting a release artifact.
set -euo pipefail

cd "$(dirname "$0")/.."

PRODUCTS=(LatticeNode LatticeMiner)
default_build_root="$PWD/.build-reproducible"
if [[ "${REPRO_IN_CONTAINER:-0}" != "1" && "$(uname -s)" == "Darwin" && "$PWD" != /Users/* ]]; then
  # Docker Desktop does not always share /private/tmp mounts back to the host.
  # Keep operator runs from temporary worktrees usable by choosing a shared path.
  default_build_root="$HOME/Library/Caches/lattice-node/reproducible-builds/$(basename "$PWD")"
fi
BUILD_ROOT="${BUILD_ROOT:-$default_build_root}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || printf '0')}"
SWIFT_IMAGE="${SWIFT_IMAGE:-swift:6.1-jammy}"

export SOURCE_DATE_EPOCH
export ZERO_AR_DATE=1
export TZ=UTC
export LANG=C
export LC_ALL=C

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

normalize_release_artifact() {
  local artifact="$1"

  strip --strip-debug "$artifact"

  # Swift 6.1 emits a compiler module-hash section whose bytes can vary across
  # clean builds even when the loadable code/data are identical. The section is
  # not needed to execute release binaries, so compare operator artifacts after
  # removing it alongside debug-only metadata.
  if command -v objcopy >/dev/null 2>&1; then
    objcopy --remove-section=.swift_modhash "$artifact"
  fi
}

build_once_in_container() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "inner reproducible build must run in Linux" >&2
    exit 2
  fi

  local label="${REPRO_LABEL:-release}"
  local build_dir="$BUILD_ROOT/$label"
  local artifact_dir="$BUILD_ROOT/$label-artifacts"
  local hashes="$BUILD_ROOT/$label.sha256"
  local -a build_flags=(
    --disable-index-store
    -Xswiftc -file-prefix-map
    -Xswiftc "$PWD=."
    -Xswiftc -debug-prefix-map
    -Xswiftc "$PWD=."
    -Xswiftc -prefix-serialized-debugging-options
    -Xcc "-ffile-prefix-map=$PWD=."
    -Xcxx "-ffile-prefix-map=$PWD=."
    -Xlinker --build-id=none
  )

  rm -rf "$build_dir" "$artifact_dir"
  mkdir -p "$artifact_dir"
  swift package resolve
  swift build -c release --build-path "$build_dir" "${build_flags[@]}"

  : > "$hashes"
  for product in "${PRODUCTS[@]}"; do
    local built_artifact="$build_dir/release/$product"
    local release_artifact="$artifact_dir/$product"
    if [[ ! -x "$built_artifact" ]]; then
      echo "missing release artifact: $built_artifact" >&2
      exit 1
    fi
    cp "$built_artifact" "$release_artifact"
    normalize_release_artifact "$release_artifact"
    printf '%s  %s\n' "$(sha256_file "$release_artifact")" "$product" >> "$hashes"
  done
}

run_container_build() {
  local label="$1"
  local output_dir="$BUILD_ROOT/$label"
  rm -rf "$output_dir"
  mkdir -p "$output_dir"

  git archive --format=tar HEAD | docker run --rm -i \
    -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    -e REPRO_IN_CONTAINER=1 \
    -e REPRO_LABEL=release \
    -e BUILD_ROOT=/workspace/build \
    -v "$output_dir:/out" \
    "$SWIFT_IMAGE" bash -lc '
      set -euo pipefail
      apt-get update
      apt-get install -y --no-install-recommends libjavascriptcoregtk-4.1-dev libsqlite3-dev
      mkdir -p /workspace/lattice-node
      tar -xf - -C /workspace/lattice-node
      cd /workspace/lattice-node
      scripts/reproducible-build.sh
      cp /workspace/build/release.sha256 /out/sha256
      cp -a /workspace/build/release-artifacts /out/artifacts
    '

  cp "$output_dir/sha256" "$BUILD_ROOT/$label.sha256"
}

if [[ "${REPRO_IN_CONTAINER:-0}" == "1" ]]; then
  build_once_in_container
  cat "$BUILD_ROOT/${REPRO_LABEL:-release}.sha256"
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required for reproducible release verification" >&2
  exit 2
fi

if ! git diff --quiet HEAD -- || ! git diff --cached --quiet --; then
  echo "warning: reproducible build uses committed HEAD; uncommitted changes are ignored" >&2
fi

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"

run_container_build first
run_container_build second

if ! diff -u "$BUILD_ROOT/first.sha256" "$BUILD_ROOT/second.sha256"; then
  echo "release binaries are not reproducible" >&2
  exit 1
fi

cat "$BUILD_ROOT/first.sha256"
