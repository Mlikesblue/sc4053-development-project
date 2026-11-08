#!/usr/bin/env bash
# Deploy AuctionFactory to a running anvil node and point the frontend at it.
# Prereq: `anvil --chain-id 31337` is running in another terminal.

set -euo pipefail

cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

# Anvil account 0 private key. PUBLIC demo credential shipped with every anvil
# release — only usable on local anvil, carries no funds anywhere else.
ANVIL_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

say() { printf '\n==> %s\n' "$*"; }

# Make sure an anvil node is running; start one in the background if not.
"$(dirname "$0")/anvil-start.sh"

say "Deploying factory to anvil"
PRIVATE_KEY="$ANVIL_KEY" forge script script/Deploy.s.sol:Deploy \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast

RUN=broadcast/Deploy.s.sol/31337/run-latest.json
if [ ! -f "$RUN" ]; then
  echo "Deploy succeeded but broadcast record missing: $RUN" >&2
  exit 1
fi

ADDRESS=$(python3 -c "import json; d=json.load(open('$RUN')); print(d['receipts'][0]['contractAddress'])")
BLOCK_HEX=$(python3 -c "import json; d=json.load(open('$RUN')); print(d['receipts'][0]['blockNumber'])")
BLOCK=$(python3 -c "print(int('$BLOCK_HEX', 0))")

# Update web/.env.local: set/overwrite the two anvil keys, preserve the rest.
export NEW_ANVIL_ADDRESS="$ADDRESS"
export NEW_ANVIL_BLOCK="$BLOCK"
python3 - <<'PY'
import os
from pathlib import Path

p = Path("web/.env.local")
items: dict[str, str] = {}
if p.exists():
    for line in p.read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            items[k.strip()] = v.strip()
items["VITE_FACTORY_ANVIL_ADDRESS"] = os.environ["NEW_ANVIL_ADDRESS"]
items["VITE_ANVIL_DEPLOYMENT_BLOCK"] = os.environ["NEW_ANVIL_BLOCK"]
p.write_text("\n".join(f"{k}={v}" for k, v in items.items()) + "\n")
print(f"wrote {p}")
PY

echo
echo "==> Factory deployed on anvil"
echo "    address: $ADDRESS"
echo "    block:   $BLOCK"
echo
echo "Start the frontend:"
echo "    npm --prefix web run dev"
