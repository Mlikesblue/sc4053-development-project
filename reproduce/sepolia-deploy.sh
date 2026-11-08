#!/usr/bin/env bash
# Deploy AuctionFactory to Sepolia and point the frontend at it.
# Prereq: .env at repo root with SEPOLIA_RPC_URL + PRIVATE_KEY.
# Wallet behind PRIVATE_KEY must hold at least ~0.05 Sepolia ETH.

set -euo pipefail

cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

say() { printf '\n==> %s\n' "$*"; }

if [ ! -f .env ]; then
  echo ".env missing at repo root." >&2
  echo "Copy .env.example to .env and fill in SEPOLIA_RPC_URL and PRIVATE_KEY." >&2
  exit 1
fi

# shellcheck disable=SC1091
set -a; source .env; set +a

if [ -z "${SEPOLIA_RPC_URL:-}" ] || [ -z "${PRIVATE_KEY:-}" ]; then
  echo ".env must define both SEPOLIA_RPC_URL and PRIVATE_KEY." >&2
  exit 1
fi

say "Deploying factory to Sepolia"
# Plain forge create with Foundry default gas handling.
OUTPUT=$(forge create src/AuctionFactory.sol:AuctionFactory \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast)
echo "$OUTPUT"

ADDRESS=$(printf '%s\n' "$OUTPUT" | awk '/^Deployed to:/{print $3}')
TX=$(printf '%s\n' "$OUTPUT" | awk '/^Transaction hash:/{print $3}')

if [ -z "$ADDRESS" ] || [ -z "$TX" ]; then
  echo "Could not parse forge create output above." >&2
  exit 1
fi

# Deployment block comes from the receipt.
BLOCK_HEX=$(cast receipt --rpc-url "$SEPOLIA_RPC_URL" "$TX" --json \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['blockNumber'])")
BLOCK=$(python3 -c "print(int('$BLOCK_HEX', 0))")

# Update web/.env.local: set/overwrite the three Sepolia keys, preserve the rest.
export NEW_SEPOLIA_ADDRESS="$ADDRESS"
export NEW_SEPOLIA_BLOCK="$BLOCK"
export NEW_SEPOLIA_RPC_URL="$SEPOLIA_RPC_URL"
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
items["VITE_FACTORY_SEPOLIA_ADDRESS"] = os.environ["NEW_SEPOLIA_ADDRESS"]
items["VITE_SEPOLIA_RPC_URL"] = os.environ["NEW_SEPOLIA_RPC_URL"]
items["VITE_SEPOLIA_DEPLOYMENT_BLOCK"] = os.environ["NEW_SEPOLIA_BLOCK"]
p.write_text("\n".join(f"{k}={v}" for k, v in items.items()) + "\n")
print(f"wrote {p}")
PY

echo
echo "==> Factory deployed to Sepolia"
echo "    address:  $ADDRESS"
echo "    block:    $BLOCK"
echo "    tx:       $TX"
echo "    explorer: https://sepolia.etherscan.io/address/$ADDRESS"
echo
echo "Start the frontend:"
echo "    npm --prefix web run dev"
