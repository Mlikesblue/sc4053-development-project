# AI Audit Report — Dutch Auction dApp

**Team:** Mirza Bin Muhammad Hisham (U2340585L), Garv Sachdev (U2323262H)  
**Course:** SC4053 Blockchain Technology, AY2026-2027 Semester 1, Nanyang Technological University  
**Prepared:** 2026-11-08  
**Status:** Contracts deployed to Sepolia; frontend wired to both anvil and Sepolia.

This report records AI-assisted implementation and end-to-end validation on both local anvil and Sepolia. It is not an independent smart-contract security audit. Design decisions and the running specification are recorded in [spec-working.md](https://github.com/gavkujo/sc4053-development-project/blob/f1b9d62dcc4509c6f47468f1d23f5753ec1c46d6/spec-working.md); interview answers and the implementation request are recorded in [ai-log.md](https://github.com/gavkujo/sc4053-development-project/blob/f1b9d62dcc4509c6f47468f1d23f5753ec1c46d6/ai-log.md).

## 1. Initial Specification & System Scope

We selected the Dutch auction in Section 5.2 of the [course brief](https://github.com/gavkujo/sc4053-development-project/blob/f1b9d62dcc4509c6f47468f1d23f5753ec1c46d6/project.pdf). The starting scope was a token sale with a separate ERC-20 and auction contract, a descending price, one clearing price for all winners, claims for tokens and surplus ETH, and a browser UI for viewing the auction, bidding, and claiming. The [baseline specification](https://github.com/gavkujo/sc4053-development-project/blob/f1b9d62dcc4509c6f47468f1d23f5753ec1c46d6/spec.md) captures these requirements and the open questions from the brief.

We agreed to treat 20 minutes as the maximum bidding window because the brief also describes the auction clearing when commitments cover the supply. We calculate refunds automatically at settlement and pay them with the bidder's **Claim** transaction. These are our interpretations of “exactly 20 minutes” and “automatically process ETH refunds.” The [approved specification](https://github.com/gavkujo/sc4053-development-project/blob/f1b9d62dcc4509c6f47468f1d23f5753ec1c46d6/spec-working.md#course-brief-interpretations) records both. The project targets local Anvil and Sepolia. Mainnet deployment, secondary trading, and a custom backend are outside scope.

## 2. Development Methodology & AI Tooling Infrastructure

Mirza conducted the initial requirements interview with Codex and supervised the first implementation. He approved the specification and testing plan before asking Codex to implement it. Garv helped test the app, improve the frontend, and work on the Sepolia deployment. The [prompt log](https://github.com/gavkujo/sc4053-development-project/blob/f1b9d62dcc4509c6f47468f1d23f5753ec1c46d6/ai-log.md) records Kiro's assistance with the Sepolia deployment, reproduction scripts, and dashboard refactor. Mirza then tested the full application again after those changes.

We used the approved specification and testing plan to guide code generation and review. Foundry built and tested the Solidity contracts, `script/export-abi.mjs` exported the contract ABIs used by the React/Vite frontend, and `reproduce/` scripts packaged the build, tests, and deployment commands. MetaMask supported browser testing on Anvil and Sepolia. The implementation request deferred Sepolia deployment until local validation was complete and the team supplied the necessary configuration.

## 3. Specification Engineering & Prompt Logs

1. **Requirements interview.** We gave Codex [the baseline](https://github.com/gavkujo/sc4053-development-project/blob/f1b9d62dcc4509c6f47468f1d23f5753ec1c46d6/spec.md) and asked it to interview us two to four questions at a time, surface ambiguous wording, and explore the auction lifecycle and UI. The [interview rounds](https://github.com/gavkujo/sc4053-development-project/blob/f1b9d62dcc4509c6f47468f1d23f5753ec1c46d6/ai-log.md#1-requirements-interview) record the prompts and our answers on early sellout, excess bids, and claim-triggered refunds.
2. **Plan approval and implementation.** We gave Codex the [approved specification and testing plan](https://github.com/gavkujo/sc4053-development-project/blob/f1b9d62dcc4509c6f47468f1d23f5753ec1c46d6/spec-working.md#implementation-plan). The [approval and implementation prompts](https://github.com/gavkujo/sc4053-development-project/blob/f1b9d62dcc4509c6f47468f1d23f5753ec1c46d6/ai-log.md#implementation-request--2026-11-07) required whole-token initial supplies with fractional allocations, verification of settlement and rounding invariants, and a commitment cap chosen through gas benchmarks.
3. **Sepolia and frontend iteration.** The [Sepolia prompt](https://github.com/gavkujo/sc4053-development-project/blob/f1b9d62dcc4509c6f47468f1d23f5753ec1c46d6/ai-log.md#sepolia-deployment--2026-11-08) gave Kiro the locally tested implementation, the intended RPC provider, and a create–bid–claim checklist. The [dashboard prompt](https://github.com/gavkujo/sc4053-development-project/blob/f1b9d62dcc4509c6f47468f1d23f5753ec1c46d6/ai-log.md#ui-split-refactor--2026-11-08) then specified a new layout while preserving contract calls, wallet behavior, and auction logic.

## 4. AI-Generated Architecture

The plan proposed a factory for administrator-controlled auction creation and discovery, independent auction contracts holding their own settings and commitments, and an ERC-20 escrow for each auction. The proposed interfaces separated creation, bidding, finalization, claims, and proceeds withdrawal. Settlement would use an ordered list of bids for priority and per-wallet totals for token and refund entitlements. The browser would read authoritative auction state from the chain and use local storage for wallet activity and UI preferences. The [approved implementation plan](https://github.com/gavkujo/sc4053-development-project/blob/f1b9d62dcc4509c6f47468f1d23f5753ec1c46d6/spec-working.md#implementation-plan) records this design. The implementation below follows that split. Benchmarking established the 64-commitment cap.

- **Contracts:** `AuctionFactory` fixes one `Ownable` administrator for the deployment, blocks ownership transfer and renunciation, and creates independent `DutchAuction` instances. Each auction deploys a dedicated 18-decimal ERC-20 and escrows its full whole-token supply.
- **Auction logic:** Linear, quadratic slow-initial, and quadratic fast-initial curves share a deterministic integer price function. Auctions support immediate or scheduled starts, pre-start cancellation, early sellout, time-decay sellout, and reserve-price expiry.
- **Settlement:** Individual commitment order is retained, including repeated bids from one address. Settlement trims from newest commitments, aggregates retained ETH by bidder, computes independent token/refund entitlements, burns unsold or rounding-dust units, and reserves refunds before proceeds can be withdrawn.
- **Claims:** The combined Claim finalizes when necessary and transfers tokens plus ETH refunds. Separate token-only and bidder-authorized redirected refund functions are available. State updates precede external transfers and all payout entry points use reentrancy protection.
- **Frontend:** React/Vite with viem reads auction data, displays a locally advancing deterministic price curve and frozen close marker, supports wallet/network prompts and administrator controls, and maintains wallet-filtered activity using on-chain events plus browser storage.
- **Operational scripts:** Foundry deployment and ABI export scripts, plus shell wrappers under `reproduce/` for one-command install, local anvil deployment, and Sepolia deployment. The factory is live on anvil and on Sepolia (see the Sepolia deployment section).

## 5. Problems Discovered & Vulnerability Analysis

### Immediate overbid surplus was counted twice

- **Cause.** The initial settlement logic counted the same immediate overbid excess twice when forming the refund. The prompt log does not establish what led the AI to make that accounting mistake.
- **Impact.** An inflated refund could overpay a bidder and reduce the ETH available for other payouts.
- **Fix.** Settlement now adds the three distinct components once each: accepted ETH trimmed at settlement, the unused rounding remainder, and the immediate excess recorded at bid time. Sale proceeds equal the ETH received minus refund entitlements.
- **Evidence.** [`testThresholdCrossingAcceptsOnlyNeededEthAndClaimPaysTokenAndRefund`](https://github.com/gavkujo/sc4053-development-project/blob/f1b9d62dcc4509c6f47468f1d23f5753ec1c46d6/test/DutchAuction.t.sol) passes. In the test, a 10-wei bid follows a 6-wei bid for one token costing 10 wei. The contract accepts 4 wei from the second bid, pays back exactly 6 wei when that bidder claims, and records 10 wei of proceeds from the 16 wei received.

### The UI hid Claim after logical closure

- **Cause.** The initial UI expected stored settlement entitlements to enable Claim. A closed auction can have eligible bidders before those values exist, because the first eligible claim can finalize the auction.
- **Impact.** A bidder could see the auction close but have no claim action in the browser, delaying access to tokens and refunds.
- **Fix.** The UI now offers Claim to a bidder with accepted ETH when the auction is closed and explains that claiming records settlement. After finalization, it uses the stored entitlements and claim flags.
- **Evidence.** [`testPermissionlessIdempotentFinalizeAndClaimTriggeredFinalize`](https://github.com/gavkujo/sc4053-development-project/blob/f1b9d62dcc4509c6f47468f1d23f5753ec1c46d6/test/DutchAuction.t.sol) passes and verifies the contract path. In a separate Chrome and MetaMask run on Sepolia, the UI exposed **Claim tokens + ETH** while the auction was **Closed**. The [claim transaction](https://sepolia.etherscan.io/tx/0x868d9eac7a79c949650b611e9b3bd35edd94e66b860682acf36644e3426816d0) finalized the auction and paid 10 SDT and a 0.000218 ETH refund.

### The first-claim benchmark missed a refund-bearing path

- **Cause.** The initial benchmark selected a claimant with no refund, so it missed the cost of combining token and ETH transfers with first-claim settlement.
- **Impact.** That measurement could understate settlement cost and lead to a cap that leaves too little gas headroom for bidders who are owed refunds.
- **Fix.** We benchmarked a partially trimmed bidder receiving both assets and added separate refund-only and repeated-bidder cases.
- **Evidence.** At cap 64, the combined case used 4,075,434 gas against our 5,000,000 gas target. The measured first claim at cap 128 exceeded the target. See the gas table below and [`GasBenchmark.t.sol`](https://github.com/gavkujo/sc4053-development-project/blob/f1b9d62dcc4509c6f47468f1d23f5753ec1c46d6/test/GasBenchmark.t.sol).

## 6. Validation Process & Testing Strategy

We checked settlement with an arithmetic review and Foundry unit and fuzz tests covering accounting and attack cases. Gas benchmarks guided the commitment cap. We also checked wallet behavior on Anvil and used Sepolia to validate the deployed factory and auction lifecycle. The [testing plan](https://github.com/gavkujo/sc4053-development-project/blob/f1b9d62dcc4509c6f47468f1d23f5753ec1c46d6/spec-working.md#testing-plan) maps these checks to the risks they address.

### Settlement arithmetic and invariants reviewed

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

### Commitment cap and gas evidence

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

### Local checks

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
- For the reentrancy bonus, [`testReentrantRefundReceiverCannotClaimTwice`](https://github.com/gavkujo/sc4053-development-project/blob/f1b9d62dcc4509c6f47468f1d23f5753ec1c46d6/test/DutchAuction.t.sol) deploys a malicious refund recipient that tries to call `claim()` from its ETH receive hook. The test passes: the reentry fails, the recipient receives one token allocation and one refund, and refund liability falls to zero.
- Frontend production build: `npm run build` passed (TypeScript and Vite). Vite reports one non-blocking warning that an optional `node:worker_threads` import from `ox` is externalized for browser compatibility; the browser bundle succeeds.
- Frontend price helper tests: **2 passed**, including all three curves at every elapsed second and narrow-spread rounding/clamping cases.
- Solidity formatting: `forge fmt --check` passed after applying the formatter.
- Foundry lint completed with 23 advisory diagnostics: 14 `block-timestamp`, 8 `reentrancy-events`, and 1 `arbitrary-send-eth`. Timestamp checks are required by the auction's time-based pricing and closure; event-order advisories cover known token calls and first-claim finalization; the ETH-transfer advisory covers the required bidder-authorized refund destination. Timestamp-to-`uint64` projections are bounded by the validated auction end time, and payout entry points are reentrancy-guarded.
- `npm ci` installed the locked frontend dependencies; the install reported zero npm audit vulnerabilities.

Reproduce with the commands in [README.md](https://github.com/gavkujo/sc4053-development-project/blob/f1b9d62dcc4509c6f47468f1d23f5753ec1c46d6/README.md). The ABI JSON under `web/src/abi/` is generated from current Foundry artifacts.

## 7. Improvements & Refinements

- The proceeds display subtracts amounts already withdrawn. Activity refresh reconciles local transaction entries with their matching on-chain events so a confirmed transaction appears once.
- We split the frontend into a landing page and dashboard while preserving the auction and wallet flows. On Sepolia, Multicall3 batches reads to reduce RPC traffic, and the activity scanner uses smaller log ranges to fit the provider's limits. The [dashboard prompt and results](https://github.com/gavkujo/sc4053-development-project/blob/f1b9d62dcc4509c6f47468f1d23f5753ec1c46d6/ai-log.md#ui-split-refactor--2026-11-08) record the change.
- We added [reproduction scripts](https://github.com/gavkujo/sc4053-development-project/blob/f1b9d62dcc4509c6f47468f1d23f5753ec1c46d6/README.md#reproduce-from-scratch) for building and testing from a fresh clone, deploying on Anvil, and deploying on Sepolia.

### Add to MetaMask refinement — 2026-11-07

- The original CateCoin claim on Anvil delivered 93,060.909791827293754818 CTN and a 4,416.5 ETH refund to account #1 in transaction `0x2694ab0aff287d1066fcdd50d9b4ab38432818716704308a0edb604336382fbb`. MetaMask required a token display import on the local network.
- The auction page now offers **Add to MetaMask** after a token claim and on later visits by the same account. It reads the token metadata from the selected auction, checks the current wallet chain ID, and sends the EIP-747 `wallet_watchAsset` request. An unsupported or failed request offers the contract address for manual import.
- Verified in Chrome and MetaMask with a prior CateCoin claim on Anvil. The prompt showed CTN and the account's token balance. Dismissal returned a message and allowed a retry. Approval returned to the auction page with a message pointing to the wallet's token list. The account transaction count stayed at six, so the display request submitted no transaction and used no gas.
- The frontend build and all five frontend tests passed. Automated tests cover both chain IDs, token metadata in the request, network mismatch, rejection, unsupported methods, and other wallet errors. We later verified the live Sepolia path in Chrome by adding SDT to MetaMask after the claim above.

## 8. Lessons Learned

The Codex interview helped turn ambiguous brief wording into decisions the team could approve and test. AI also helped produce the first implementation, tests, and deployment scripts quickly. We got more useful changes when we gave the tool specific boundaries, such as asking Kiro to split the UI while preserving wallet and contract calls.

The overbid bug showed the need for an explicit ETH conservation invariant. The missing Claim button showed that contract tests alone cannot establish that a bidder can complete settlement from the browser. Next time, we would write the accounting invariants and state transitions before generating implementation code, require a regression test for each major fix, and verify the full wallet flow on a testnet before calling the feature complete.

## Appendix — Sepolia deployment evidence

The factory below is the project's reference deployment. The [README](https://github.com/gavkujo/sc4053-development-project/blob/f1b9d62dcc4509c6f47468f1d23f5753ec1c46d6/README.md#live-sepolia-deployment) explains how to configure `web/.env.local` to use it. Running `reproduce/sepolia-deploy.sh` deploys a separate factory using the configured wallet and RPC. This snapshot describes the reference deployment.

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

### Deployment status

- The factory is deployed on local Anvil and on Sepolia. The Sepolia factory address, deployment block, and settlement snapshot are listed above.
- No independent third-party audit has been performed.
