# AI Audit Report — Dutch Auction dApp

**Prepared:** 2026-11-08  
**Status:** Contracts deployed to Sepolia; frontend wired to both anvil and Sepolia.

This report records AI-assisted implementation and local validation. It is not an independent smart-contract security audit. The approved requirements and course-brief interpretation are recorded in [spec-working.md](./spec-working.md); interview answers and the implementation request are recorded in [ai-log.md](./ai-log.md).

## Implementation summary

- **Contracts:** `AuctionFactory` fixes one `Ownable` administrator for the deployment, blocks ownership transfer and renunciation, and creates independent `DutchAuction` instances. Each auction deploys a dedicated 18-decimal ERC-20 and escrows its full whole-token supply.
- **Auction logic:** Linear, quadratic slow-initial, and quadratic fast-initial curves share a deterministic integer price function. Auctions support immediate or scheduled starts, pre-start cancellation, early sellout, time-decay sellout, and reserve-price expiry.
- **Settlement:** Individual commitment order is retained, including repeated bids from one address. Settlement trims from newest commitments, aggregates retained ETH by bidder, computes independent token/refund entitlements, burns unsold or rounding-dust units, and reserves refunds before proceeds can be withdrawn.
- **Claims:** The combined Claim finalizes when necessary and transfers tokens plus ETH refunds. Separate token-only and bidder-authorized redirected refund functions are available. State updates precede external transfers and all payout entry points use reentrancy protection.
- **Frontend:** React/Vite with viem reads auction data, displays a locally advancing deterministic price curve and frozen close marker, supports wallet/network prompts and administrator controls, and maintains wallet-filtered activity using on-chain events plus browser storage.
- **Operational scripts:** Foundry deployment and ABI export scripts are present. The deployment script was not broadcast to any network.

## Settlement arithmetic and invariants reviewed

Let `U = 10^18`, `P` be the final integer price in wei per whole token, and `Bᵢ` be bidder `i`'s retained ETH budget after newest-first trimming.

```text
tokenUnitsᵢ = floor(Bᵢ × U / P)
chargedWeiᵢ = ceil(tokenUnitsᵢ × P / U)
roundingRefundᵢ = Bᵢ - chargedWeiᵢ
```

Because `tokenUnitsᵢ × P / U ≤ Bᵢ` and `Bᵢ` is an integer number of wei, the ceiling charge cannot exceed the budget. Each rounding refund is therefore nonnegative. For a zero-unit allocation, the charge is zero and the full retained budget is refunded.

At a sellout price, aggregate retained budgets equal `wholeTokenSupply × P` after trimming. Summing per-bidder floor conversions cannot allocate more than `wholeTokenSupply × U`; any remaining smallest units are burned. Each positive retained budget loses less than one smallest token unit to division rounding. The 64-commitment cap also bounds distinct bidders and the total rounding-dust bound.

Per bidder, the refund entitlement adds ETH trimmed from that bidder's newest commitments, any retained-budget-versus-rounded-charge remainder, and any immediate overbid excess. Sale proceeds are total ETH received minus refund entitlements. Tests assert token conservation, no oversell, receipt/refund/proceeds conservation, and contract balance equal to remaining proceeds plus outstanding refund liability.

The price function rounds the positive premium above reserve up at the final division. This maintains the configured starting price, monotonic non-increase, a price no lower than reserve, and reserve first occurring at exactly second 1,200. `Math.mulDiv` supplies full-precision conversions. The time-based clearing search is bounded to 11 integer-second iterations.

## Commitment cap and gas evidence

The official factory pins the maximum to **64 commitments per auction**. The cap counts bid calls, not distinct bidders. Benchmarks cover all-distinct and repeated bidders, newest-first trimming, a zero-allocation refund claimant, and nonzero rounding burns for the all-distinct case.

The project uses 5,000,000 gas as its conservative per-finalization/first-claim budget for cap selection. This is a project benchmark target, not a claim about a network protocol limit.

| Cap | Finalize | First Claim finalizes | Result against 5M target |
| ---: | ---: | ---: | --- |
| 16 | 1,176,033 | 1,211,502 | Pass |
| 32 | 2,115,425 | 2,150,894 | Pass |
| 64 | 3,994,209 | 4,075,434 | Pass; selected; partial-trim bidder gets tokens and refund |
| 64, refund-only bidder | — | 4,029,678 | Pass; fully trimmed commitment |
| 64, repeated bidder | — | 676,841 | Pass; one-wallet settlement path |
| 128 | 7,751,777 | 7,787,246 | Exceeds target |

At 64, the all-distinct first-claim case leaves 924,566 gas below the project target (about 18.5%). Cap 128 exceeds the budget. The maximum possible dust bound is 64 token base units, or `6.4×10^-17` whole tokens; the all-distinct benchmark exercises nonzero rounding dust.

Measurements came from `forge test --match-path test/GasBenchmark.t.sol -vv` and the full `forge test --gas-report` run. Max-cap bidding was set up outside the measured operation; the benchmark measures finalization or a first Claim after those commitments accumulate.

## Local checks

Environment used: Foundry 1.9.0, Solidity 0.8.28, Node.js 22.14.0, npm 10.9.2, React 19.2.9, viem 2.57.16, and Vite 8.3.6. Solidity dependencies are pinned to OpenZeppelin Contracts v5.7.0 and `forge-std` v1.16.2.

Foundry was missing initially and was installed with the official Foundry installer and `foundryup`. Frontend packages were installed from the pinned lockfile using `npm ci --prefix web`; the install reported zero npm audit vulnerabilities. To reproduce the local checks from the project root:

```sh
foundryup --install 1.9.0
npm ci --prefix web
forge build
forge test --gas-report
npm --prefix web test
node script/export-abi.mjs
npm --prefix web run build
```

- Full Foundry suite: **30 tests passed, 0 failed**, including 1,536 fuzz runs across three pricing/settlement properties and 10 gas benchmark cases.
- Gas benchmarks: **10 passed, 0 failed**; measurements are listed above. The cap-64 first Claim includes token and ETH transfers for one partially trimmed bidder.
- Curve coverage: all three curves were compared to an independent integer reference at each of the 1,201 elapsed-second values. Fuzz tests also cover price bounds, rounding, and ETH/token accounting.
- Security/accounting scenarios include threshold-crossing bids, time-based closure, reserve expiry, newest-first trimming, repeated bidder commitments, zero-unit refunds, redirected refunds, duplicate actions, reverting/reentrant recipients, and proceeds withdrawal with refund reserves.
- Frontend production build: `npm run build` passed (TypeScript and Vite). Vite reports one non-blocking warning that an optional `node:worker_threads` import from `ox` is externalized for browser compatibility; the browser bundle succeeds.
- Frontend price helper tests: **2 passed**, including all three curves at every elapsed second and narrow-spread rounding/clamping cases.
- Solidity formatting: `forge fmt --check` passed after applying the formatter.
- Foundry lint completed with 23 advisory diagnostics: 14 `block-timestamp`, 8 `reentrancy-events`, and 1 `arbitrary-send-eth`. Timestamp checks are required by the auction's time-based pricing and closure; event-order advisories cover known token calls and first-claim finalization; the ETH-transfer advisory covers the required bidder-authorized refund destination. Timestamp-to-`uint64` projections are bounded by the validated auction end time, and payout entry points are reentrancy-guarded.
- `npm ci` installed the locked frontend dependencies; the install reported zero npm audit vulnerabilities.

Reproduce with the commands in [README.md](./README.md). The ABI JSON under `web/src/abi/` is generated from current Foundry artifacts.

## Findings fixed during implementation

1. Refund accounting initially counted immediate overbid excess twice. Settlement now adds each refund category once; ETH-conservation tests cover the correction.
2. The first-claim benchmark originally chose a bidder with no refund. The selected cap-64 case now claims as a partially trimmed bidder and includes both token and ETH transfers; separate refund-only and repeated-bidder cases remain measured.
3. The bidder UI previously hid Claim at logical closure because per-wallet entitlements are not stored until finalization. It now offers Claim to a bidder with accepted ETH while closed and explains that the transaction records settlement.
4. The proceeds display now subtracts already withdrawn proceeds. Activity refresh replaces a local transaction entry with its matching confirmed event rather than displaying both.

## Add to MetaMask refinement — 2026-11-07

- The original CateCoin claim on Anvil delivered 93,060.909791827293754818 CTN and a 4,416.5 ETH refund to account #1 in transaction `0x2694ab0aff287d1066fcdd50d9b4ab38432818716704308a0edb604336382fbb`. MetaMask required a token display import on the local network.
- The auction page now offers **Add to MetaMask** after a token claim and on later visits by the same account. It reads the token metadata from the selected auction, checks the current wallet chain ID, and sends the EIP-747 `wallet_watchAsset` request. An unsupported or failed request offers the contract address for manual import.
- Verified in Chrome and MetaMask with a prior CateCoin claim on Anvil. The prompt showed CTN and the account's token balance. Dismissal returned a message and allowed a retry. Approval returned to the auction page with a message pointing to the wallet's token list. The account transaction count stayed at six, so the display request submitted no transaction and used no gas.
- The frontend build and all five frontend tests passed. Automated tests cover both chain IDs, token metadata in the request, network mismatch, rejection, unsupported methods, and other wallet errors. Sepolia coverage for this feature used a simulated provider.

## Sepolia deployment

The factory below is this project's reference deployment and the one the shipped `web/.env.local` points at. Readers reproducing the project with `reproduce/sepolia-deploy.sh` deploy an independent factory from their own wallet and RPC; the addresses and state snapshot in this section are specific to the reference deployment.

- Factory: `0xB200E4c71ba447281869880f895f24F825407173`
- Deployment block: `12089885`
- Admin (factory owner): `0x33C8Dfe2150C7E294b97b51f17f929E7D06850B8`
- Etherscan: <https://sepolia.etherscan.io/address/0xB200E4c71ba447281869880f895f24F825407173>

The deployment is performed by `reproduce/sepolia-deploy.sh`, which wraps a single command:

```sh
forge create src/AuctionFactory.sol:AuctionFactory \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

The script parses the deployed address and deployment block from forge and `cast receipt`, then writes `VITE_FACTORY_SEPOLIA_ADDRESS`, `VITE_SEPOLIA_RPC_URL`, and `VITE_SEPOLIA_DEPLOYMENT_BLOCK` into `web/.env.local` while preserving any existing anvil values.

One supporting frontend change was needed to run against Sepolia on Alchemy's free tier: `MAX_LOG_BLOCK_RANGE` in `web/src/ui/App.tsx` was reduced from 2000 to 10 so that each `eth_getLogs` call in the activity-history scanner stays within Alchemy's free-tier per-call 10-block range. The scan loop and all other behavior are unchanged, so anvil, which has no such limit, is unaffected (just makes more, local calls).

### Deployment state snapshot

One auction has been created against the live factory to confirm end-to-end behavior from contract creation through bidder claims.

- Auction: `0x8AE8F3367548a690B2A8f087206B1472C5B32C1a`
- Token supply: 100 TST (18 decimals)
- Starting price: 0.01 ETH per token · Reserve: 0.004 ETH per token · Curve: quadratic fast-initial · Window: 20 minutes
- Commitments: 3 / 64 · Total accepted: 0.15 ETH · Final clearing price: 0.004 ETH per token
- Allocated: 37.5 TST · Burned: 62.5 TST · Sale proceeds: 0.15 ETH · Refund liability: 0 ETH
- Status: Finalized; proceeds remain in the auction contract until `withdrawProceeds` is called by the admin.

## Deployment status

- The factory is deployed on local Anvil and on Sepolia. The Sepolia factory address, deployment block, and settlement snapshot are listed above.
- No independent third-party audit has been performed. The course wording about “exactly 20 minutes” and “automatic” refunds remains an interpretation: this project implements early sellout and calculates refunds at settlement, paid by the bidder's combined Claim action, as approved.
