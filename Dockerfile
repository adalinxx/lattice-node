# Stage 1: Build
FROM swift:6.1-jammy AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    libjavascriptcoregtk-4.1-dev \
    libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY Package.swift Package.resolved ./
RUN swift package resolve

COPY Sources Sources
COPY Tests Tests
COPY FuzzTargets FuzzTargets
RUN swift build -c release --static-swift-stdlib

# Stage 2: Runtime
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    dnsutils \
    jq \
    libatomic1 \
    libcurl4 \
    libjavascriptcoregtk-4.1-0 \
    libsqlite3-0 \
    libxml2 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/.build/release/LatticeNode /usr/local/bin/lattice-node
# The node never mines in-process; block production runs in the external miner.
# Ship both binaries so a miner can run from the same image. The entrypoint
# dispatches on the first arg (`lattice-node` / `lattice-miner`), defaulting to
# the node so existing `docker run <image> --flags` call sites keep working.
COPY --from=builder /build/.build/release/LatticeMiner /usr/local/bin/lattice-miner
COPY deploy/entrypoint.sh /usr/local/bin/lattice-entrypoint
RUN chmod +x /usr/local/bin/lattice-entrypoint

RUN useradd -m -s /bin/bash lattice
USER lattice

VOLUME /home/lattice/.lattice
EXPOSE 4001
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD grep -q "status: OK" /home/lattice/.lattice/health || exit 1

ENTRYPOINT ["/usr/local/bin/lattice-entrypoint"]
CMD ["lattice-node", "--autosize", "--data-dir", "/home/lattice/.lattice"]
