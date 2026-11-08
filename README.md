# Dutch Auction dApp

An Ethereum dApp for configurable, 20-minute Dutch auctions with a uniform clearing price, ERC-20 claims, and automatic ETH refund accounting. Read the live requirements in [spec-working.md](./spec-working.md), the original course baseline in [spec.md](./spec.md), the interview history in [ai-log.md](./ai-log.md), and the implementation review in [AI_AUDIT_REPORT.md](./AI_AUDIT_REPORT.md).

## Requirements

- Foundry / Forge (local setup used Foundry 1.9.0)
- Node.js 20.19+ (local setup used Node 22.14.0) and npm 10+
- MetaMask or another injected browser wallet for transaction demos
- Anvil only for local interactive demos

Solidity is pinned to 0.8.28. OpenZeppelin Contracts v5.7.0 and `forge-std` v1.16.2 are pinned in `lib/`; React, viem, Vite, and TypeScript versions are pinned by `web/package-lock.json`.

## Install and build

Install Foundry if it is not already present:

```sh
curl -L https://foundry.paradigm.xyz | bash
export PATH="$HOME/.foundry/bin:$PATH"
foundryup --install 1.9.0
```

If you are reconstructing dependencies rather than using the included `lib/` directory, install the pinned Solidity libraries from the project root:

```sh
forge install OpenZeppelin/openzeppelin-contracts@v5.7.0 --no-git
forge install foundry-rs/forge-std@v1.16.2 --no-git
```

Build contracts, run the local test and gas suites, and install/build the frontend:

```sh
forge build
forge test
forge test --gas-report
forge fmt --check
npm ci --prefix web
npm --prefix web test
node script/export-abi.mjs
npm --prefix web run build
```

The checked-in ABI files are regenerated from Foundry artifacts by `node script/export-abi.mjs` after contract changes.

## Local interactive demo

Start Anvil in one terminal:

```sh
anvil --chain-id 31337
```

In another terminal, deploy the factory to Anvil using one of Anvil's local test accounts:

```sh
forge script script/Deploy.s.sol:Deploy \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast --unlocked --sender <ANVIL_TEST_ACCOUNT>
```

The deployment script fixes the per-auction commitment limit at 64. Copy the resulting factory address and its deployment block into `web/.env.local`; start from `web/.env.example`. Then run:

```sh
npm --prefix web run dev
```

Open the localhost URL printed by Vite. Add the local Anvil network to MetaMask if prompted and import an Anvil test account only for local demonstrations. Anvil test accounts and keys are public demo credentials; never use them outside Anvil.

To browse Sepolia, set `VITE_FACTORY_SEPOLIA_ADDRESS` and `VITE_SEPOLIA_RPC_URL` in `web/.env.local`. The web app does not need or accept a private key. Transaction signing stays in the connected wallet.

## Sepolia deployment

Sepolia is in project scope, but this workspace has **not** been deployed to Sepolia. Do not broadcast a Sepolia deployment until the local implementation is validated and the project owner has supplied the required RPC and signing configuration.

When ready, copy the root `.env.example` to `.env`, provide `SEPOLIA_RPC_URL` and `PRIVATE_KEY` locally, and run the deployment script explicitly:

```sh
forge script script/Deploy.s.sol:Deploy --rpc-url sepolia --broadcast
```

Keep `.env` private. Never copy `PRIVATE_KEY` into `web/.env.local`, frontend variables, source files, or reports. After deployment, configure the public Sepolia factory address and RPC endpoint in `web/.env.local`, then rebuild/restart the frontend.

## Selected on-chain behavior

- The fixed factory administrator creates auctions. The factory pins each auction to a maximum of 64 commitments.
- Auctions use one of three deterministic integer-second price curves. Prices are wei per whole token; tokens use 18 decimals.
- Settlement preserves commitment order, trims surplus from newest commitments, refunds whole-wei rounding remainder, and burns any unallocated token units.
- Finalization is permissionless. A bidder's first Claim can finalize and deliver its tokens and ETH refund together. Separate token and redirected-refund paths are available.
- Admin proceeds are withdrawable after finalization while outstanding refund liabilities remain reserved.

See [AI_AUDIT_REPORT.md](./AI_AUDIT_REPORT.md) for the gas measurements, arithmetic review, executed checks, and outstanding environment-dependent validation.
