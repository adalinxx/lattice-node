#!/usr/bin/env bash
# Reproduce the CI `test-linux` job locally (Docker via colima or Docker Desktop).
# Linux build artifacts live in a named Docker volume so they never clobber the
# macOS .build directory.
#
#   scripts/linux-build.sh            # swift build -c release  (matches CI Build step)
#   scripts/linux-build.sh test       # build + swift test
#   scripts/linux-build.sh shell      # interactive shell in the Linux image
#   scripts/linux-build.sh <cmd...>   # run an arbitrary command in the image
#
# On Apple Silicon this builds native arm64-linux, which catches the same
# portability errors as CI. Set PLATFORM=linux/amd64 to match CI's exact target
# (slower, emulated).
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE=lattice-linux
PLATFORM="${PLATFORM:-}"
PLATFORM_ARG=()
[ -n "$PLATFORM" ] && PLATFORM_ARG=(--platform "$PLATFORM")

docker build "${PLATFORM_ARG[@]}" -t "$IMAGE" -f Dockerfile.linux . >&2

case "${1:-build}" in
  build) RUN="swift build -c release --build-path .build-linux" ;;
  test)  RUN="swift build -c release --build-path .build-linux && swift test --build-path .build-linux" ;;
  shell) RUN="bash" ;;
  *)     RUN="$*" ;;
esac

TTY=()
[ -t 0 ] && TTY=(-it)

exec docker run --rm "${TTY[@]}" "${PLATFORM_ARG[@]}" \
  -v "$PWD":/src \
  -v lattice-linux-build:/src/.build-linux \
  "$IMAGE" bash -lc "$RUN"
