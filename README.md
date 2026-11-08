# Dutch Auction dApp

An Ethereum dApp for configurable, 20-minute Dutch auctions with a uniform clearing price, ERC-20 claims, and automatic ETH refund accounting. Read the live requirements in [spec-working.md](./spec-working.md), the original course baseline in [spec.md](./spec.md), the interview history in [ai-log.md](./ai-log.md), and the implementation review in [AI_AUDIT_REPORT.md](./AI_AUDIT_REPORT.md).

## Requirements

- Foundry / Forge (local setup used Foundry 1.9.0)
- Node.js 20.19+ (local setup used Node 22.14.0) and npm 10+
- MetaMask or another injected browser wallet for transaction demos
- Anvil only for local interactive demos

Solidity is pinned to 0.8.28. OpenZeppelin Contracts v5.7.0 and `forge-std` v1.16.2 are pinned in `lib/`; React, viem, Vite, and TypeScript versions are pinned by `web/package-lock.json`.

## Reproduce from scratch

Three shell scripts in `reproduce/` cover every path. Run them from the repo root. (Note: the course-shipped Solidity scripts live in `script/` — the directories are deliberately different.)

### 1. Install dependencies, build, run all tests

```sh
reproduce/install.sh
```

What it does:

- Installs Foundry 1.9.0 via `curl -L https://foundry.paradigm.xyz | bash && foundryup --install 1.9.0` if `forge` is not already on `PATH`.
- Runs `npm ci --prefix web` against the committed `web/package-lock.json`.
- Runs `forge build` then `forge test` (30 tests including gas benchmarks).
- Runs `node script/export-abi.mjs` to regenerate `web/src/abi/*.json` from the Foundry artifacts.
- Runs `npm --prefix web test` (frontend unit tests) and `npm --prefix web run build` (Vite production bundle).

The script is idempotent; re-running after a code change rebuilds and retests. It exits non-zero on any failure, so it doubles as a CI-style sanity check.

Node.js 20.19 or later is required and must already be installed; we tested on 22.14.0.

### 2. Local demo on anvil

One terminal is enough:

```sh
reproduce/anvil-deploy.sh
npm --prefix web run dev
```

`anvil-deploy.sh` first delegates to `reproduce/anvil-start.sh`, which spawns `anvil --chain-id 31337` in the background if nothing is already listening on `http://127.0.0.1:8545`. The node logs go to `anvil.log` and its PID is stored in `.anvil.pid`; both are gitignored. If you already have an anvil running in another terminal, the start script detects that and reuses it.

The deploy itself runs `forge script script/Deploy.s.sol:Deploy` with anvil account 0 as deployer (that account's private key is Foundry's public demo credential, valid only on local anvil). It reads the resulting factory address and deployment block out of `broadcast/Deploy.s.sol/31337/run-latest.json` and writes them to `web/.env.local` as `VITE_FACTORY_ANVIL_ADDRESS` and `VITE_ANVIL_DEPLOYMENT_BLOCK`; any Sepolia values already in that file are preserved.

The Vite dev server defaults to `http://127.0.0.1:5173`. Connect MetaMask, add the Anvil network when prompted, and import any Anvil test account to transact. Anvil accounts and their keys are public demo credentials; never use them outside anvil.

Stop the background anvil when you're done:

```sh
reproduce/anvil-stop.sh
```

If you started anvil by hand in another terminal, stop it there (`Ctrl+C`) — the stop script only touches anvils it spawned.

### 3. Fresh Sepolia deployment

Prepare one secret file at the repo root:

```sh
cp .env.example .env
```

Edit `.env`:

- `SEPOLIA_RPC_URL` — JSON-RPC endpoint. We used Alchemy, which the course materials recommend; any Sepolia HTTPS RPC works.
- `PRIVATE_KEY` — hex-prefixed private key of the deploying wallet. It must hold at least ~0.05 Sepolia ETH; a factory deploy on post-Pectra Sepolia consumes about 0.03 ETH at a 1 gwei tip, and each `createAuction` call costs another ~0.03 ETH because it also deploys two child contracts.

`.env` is gitignored. Keep it there — never copy `PRIVATE_KEY` into `web/.env.local`, frontend source, or any report.

Then:

```sh
reproduce/sepolia-deploy.sh
npm --prefix web run dev
```

`sepolia-deploy.sh` runs:

```sh
forge create src/AuctionFactory.sol:AuctionFactory \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

It parses the deployed address from forge's stdout and the deployment block from a `cast receipt` call, then writes `VITE_FACTORY_SEPOLIA_ADDRESS`, `VITE_SEPOLIA_RPC_URL`, and `VITE_SEPOLIA_DEPLOYMENT_BLOCK` into `web/.env.local` (preserving any anvil values). It prints the address, deployment block, transaction hash, and an Etherscan link.

With the frontend running, use the network dropdown in the top bar to toggle between Anvil and Sepolia. Each network reads its own factory address and RPC URL from `web/.env.local`.

## Live Sepolia deployment

This repository ships with a reference Sepolia deployment. You can browse it with any Sepolia RPC endpoint of your own; no private key is required for read-only access.

```sh
VITE_FACTORY_SEPOLIA_ADDRESS=0xB200E4c71ba447281869880f895f24F825407173
VITE_SEPOLIA_RPC_URL=<your Sepolia HTTPS RPC — Alchemy, Infura, or any other>
VITE_SEPOLIA_DEPLOYMENT_BLOCK=12089885
```

Etherscan: <https://sepolia.etherscan.io/address/0xB200E4c71ba447281869880f895f24F825407173>

Only the wallet that deployed this factory is admin — only it can call `createAuction` or `cancelAuction`. Any connected wallet can bid on and claim from auctions once they exist. To act as admin yourself, deploy your own factory using section 3 above (your wallet then owns that deployment).

## Selected on-chain behavior

- The fixed factory administrator creates auctions. The factory pins each auction to a maximum of 64 commitments.
- Auctions use one of three deterministic integer-second price curves. Prices are wei per whole token; tokens use 18 decimals.
- Settlement preserves commitment order, trims surplus from newest commitments, refunds whole-wei rounding remainder, and burns any unallocated token units.
- Finalization is permissionless. A bidder's first Claim can finalize and deliver its tokens and ETH refund together. Separate token and redirected-refund paths are available.
- Admin proceeds are withdrawable after finalization while outstanding refund liabilities remain reserved.

See [AI_AUDIT_REPORT.md](./AI_AUDIT_REPORT.md) for the gas measurements, arithmetic review, executed checks, and outstanding environment-dependent validation.
