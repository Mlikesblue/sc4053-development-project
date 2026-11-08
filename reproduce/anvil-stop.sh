#!/usr/bin/env bash
# Stop the anvil node that anvil-start.sh spawned.
# Only acts on PIDs it owns via .anvil.pid; anvils you started by hand are left alone.

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .anvil.pid ]; then
  echo "No .anvil.pid; nothing to stop here."
  echo "If an anvil is running from a terminal you opened by hand, stop it there (Ctrl+C)."
  exit 0
fi

PID=$(cat .anvil.pid)
if kill -0 "$PID" 2>/dev/null; then
  kill "$PID"
  echo "Stopped anvil (PID $PID)."
else
  echo "PID $PID is not running; cleaning up stale .anvil.pid."
fi

rm -f .anvil.pid
