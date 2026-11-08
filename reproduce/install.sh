#!/usr/bin/env bash
# One-time environment setup: install Foundry + npm packages, build, run tests.
# Idempotent; safe to re-run.

set -euo pipefail

cd "$(dirname "$0")/.."

say() { printf '\n==> %s\n' "$*"; }

# --- Foundry ----------------------------------------------------------------
if ! command -v forge >/dev/null 2>&1; then
  say "Installing Foundry (foundry.paradigm.xyz | bash)"
  curl -L https://foundry.paradigm.xyz | bash
  export PATH="$HOME/.foundry/bin:$PATH"
  foundryup --install 1.9.0
else
  say "Foundry already present: $(forge --version | head -1)"
fi

# Make sure PATH picks up Foundry regardless of prior shell state.
export PATH="$HOME/.foundry/bin:$PATH"

# --- Node sanity ------------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "node is required but not found. Install Node.js 20.19+ (we tested on 22.14.0)." >&2
  exit 1
fi
say "Node $(node -v), npm $(npm -v)"

# --- Frontend deps ----------------------------------------------------------
say "Installing frontend packages (web/)"
npm ci --prefix web

# --- Contracts: build + test ------------------------------------------------
say "Building contracts"
forge build

say "Running Foundry tests (unit + gas benchmarks)"
forge test

# --- ABI export + frontend build -------------------------------------------
say "Exporting ABIs to web/src/abi/"
node script/export-abi.mjs

say "Running frontend unit tests"
npm --prefix web test

say "Building frontend bundle"
npm --prefix web run build

say "Setup complete."
