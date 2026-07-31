#!/usr/bin/env python3
"""Reference mining supervisor: one coordinator batch per block, one
pre-signed reward per block, in nonce order.

Consumes a `lattice-rewards emit-batch` file line by line. The cursor
advances only when a block paying the current line is accepted, or when a
healthy node repeatedly refuses the template — the node's signal that this
nonce is already spent (HTTP 400 at template build). It never advances on
generic failure: a skipped nonce permanently invalidates every later line.

Children are spawned with a clean signal mask because a shell that forks
with SIGCHLD blocked (nohup + backgrounding) wedges Foundation's child
reaping inside the coordinator. See docs/operations.md.

Configuration (environment):
  NODE_URL      default http://127.0.0.1:8080
  COORDINATOR   default /usr/local/bin/lattice-mining-coordinator
  WORKER        default /usr/local/bin/lattice-miner
  WORKERS       default 1
  BATCH_SIZE    nonces per coordinator batch, default 2000000000
  REWARD_BATCH  default /var/lib/lattice/reward-batch.jsonl
  CURSOR_FILE   default /var/lib/lattice/reward-cursor
  LOG_FILE      default /var/log/lattice-mining.log
"""
import json
import os
import signal
import subprocess
import time
import urllib.request

NODE_URL = os.environ.get("NODE_URL", "http://127.0.0.1:8080")
COORDINATOR = os.environ.get(
    "COORDINATOR", "/usr/local/bin/lattice-mining-coordinator"
)
WORKER = os.environ.get("WORKER", "/usr/local/bin/lattice-miner")
WORKERS = os.environ.get("WORKERS", "1")
BATCH_SIZE = os.environ.get("BATCH_SIZE", "2000000000")
REWARD_BATCH = os.environ.get(
    "REWARD_BATCH", "/var/lib/lattice/reward-batch.jsonl"
)
CURSOR_FILE = os.environ.get("CURSOR_FILE", "/var/lib/lattice/reward-cursor")
LOG_FILE = os.environ.get("LOG_FILE", "/var/log/lattice-mining.log")
REWARDS_FILE = CURSOR_FILE + ".current-rewards.json"

signal.pthread_sigmask(signal.SIG_SETMASK, set())
LOG = open(LOG_FILE, "a", buffering=1)


def log(message):
    LOG.write(time.strftime("%FT%T") + " " + message + "\n")


def read_cursor():
    try:
        return int(open(CURSOR_FILE).read().strip())
    except Exception:
        return 0


def write_cursor(index):
    with open(CURSOR_FILE + ".tmp", "w") as handle:
        handle.write(str(index))
    os.replace(CURSOR_FILE + ".tmp", CURSOR_FILE)


def node_healthy():
    try:
        with urllib.request.urlopen(NODE_URL + "/health", timeout=5) as reply:
            return json.load(reply).get("phase") == "active"
    except Exception:
        return False


def main():
    batch = [line for line in open(REWARD_BATCH) if line.strip()]
    index = read_cursor()
    refused_streak = 0
    log("supervisor start at reward cursor %d of %d" % (index, len(batch)))
    while True:
        if index >= len(batch):
            log("reward batch exhausted; mining without rewards — re-emit it")
            rewards_args = []
        else:
            with open(REWARDS_FILE, "w") as handle:
                handle.write(batch[index])
            rewards_args = ["--rewards-file", REWARDS_FILE]
        run = subprocess.run(
            [
                COORDINATOR,
                "--node", NODE_URL,
                "--worker-executable", WORKER,
                "--workers", WORKERS,
                "--batch-size", BATCH_SIZE,
                "--once",
            ] + rewards_args,
            capture_output=True,
            text=True,
        )
        result = {}
        for line in reversed((run.stdout or "").strip().splitlines()):
            try:
                result = json.loads(line)
                break
            except Exception:
                continue
        kind = result.get("result", "exit=%d" % run.returncode)
        if kind == "submitted" and result.get("accepted"):
            log("reward %d accepted tip=%s"
                % (index, str(result.get("tipCID", ""))[:24]))
            index += 1
            write_cursor(index)
            refused_streak = 0
            continue
        if kind in ("noSolution", "stale"):
            refused_streak = 0
            continue
        # backoff / nodeFailed / unparsed output: only a HEALTHY node
        # refusing the template implicates the reward (nonce already spent —
        # e.g. a crash after acceptance but before the cursor write).
        if node_healthy():
            refused_streak += 1
            if refused_streak >= 5:
                log("reward %d refused by healthy node 5x; advancing "
                    "(stderr: %s)" % (index, (run.stderr or "")[-200:]))
                index += 1
                write_cursor(index)
                refused_streak = 0
                continue
        else:
            refused_streak = 0
        time.sleep(5)


if __name__ == "__main__":
    main()
