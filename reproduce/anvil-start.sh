#!/usr/bin/env bash
# Start a background anvil node on http://127.0.0.1:8545 if one isn't already running.
# Idempotent — safe to re-run; prints the running PID either way.

set -euo pipefail

cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

RPC=http://127.0.0.1:8545

# Already running? Just report and exit.
if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
  if [ -f .anvil.pid ] && kill -0 "$(cat .anvil.pid)" 2>/dev/null; then
    echo "anvil already running (PID $(cat .anvil.pid)) at $RPC"
  else
    echo "anvil already running at $RPC (not started by this script; stop it however you started it)"
  fi
  exit 0
fi

# Start it, logging to anvil.log (gitignored by *.log in .gitignore).
nohup anvil --chain-id 31337 >anvil.log 2>&1 &
PID=$!
echo "$PID" > .anvil.pid

# Wait up to 10 seconds for the JSON-RPC port to answer.
for _ in $(seq 1 30); do
  if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
    echo "anvil started (PID $PID, logs: anvil.log)"
    echo "Stop it later with:  reproduce/anvil-stop.sh"
    exit 0
  fi
  sleep 0.3
done

echo "anvil did not become ready within 10s. Check anvil.log." >&2
exit 1
