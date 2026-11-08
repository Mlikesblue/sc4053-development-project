# AI Prompt Log

Keep representative prompt chains that shape the project specification, architecture, implementation, or validation. Record the actual prompt and the context the AI received. Summarize the result and capture any team decision or follow-up that changed it.

## Entry format

- **Date and tool**
- **Task and context** — relevant files, spec version, and decisions supplied to the AI
- **Prompt** — verbatim user request
- **Outcome and follow-ups** — what the AI produced, any follow-up prompts, and what the team accepted or revised
- **Evidence** — links to relevant specs, commits, tests, or results when available

## Entries

### 1. Requirements interview

- **Date and tool** — 2026-11-07, Codex
- **Task and context** — Interview the project owner to turn the course requirements in [the initial spec](./spec.md) into explicit product and contract rules. The spec was extracted from Section 5.2 of [the course brief](./project.pdf).

**Prompt**

> Based on the raw dApp idea in spec.md, interview me in details, two to four questions at a time. Cover undecided technical details of the auction, potential business rules to consider, an app user's lifecycle, what the frontend must show, what is out of scope, and any potential ambiguities. Do not ask obvious questions; dig into the parts I may not have considered. When a sentence in the brief has more than one reading, show me both readings and ask which one I mean. Keep interviewing until everything is covered.

**Outcome and follow-ups**

- Round 1 opened with bidding duration, clearing when price decay alone crosses the sellout threshold, allocation of an oversized clearing bid, and pricing when the auction expires undersubscribed.

**Round 1 response**

> ## Round 1 — Auction Clearing
>
> **1. Does sellout end bidding early?**
>
> Yes. The auction should terminate when either of two conditions is met: cumulative ETH commitments become sufficient to purchase the entire token supply at the current price, or the 20-minute deadline is reached, whichever occurs first. The 20-minute duration therefore represents the maximum auction duration.
>
> **2. What if the price falls enough to sell out without a new bid?**
>
> The auction should clear at the theoretical timestamp when existing ETH commitments first become sufficient to purchase the entire token supply, even if no new transaction occurs at that moment.
>
> Since the price-decay curve is deterministic, the contract can calculate the clearing threshold and its corresponding timestamp whenever a new commitment is made. This avoids the need for continuous on-chain execution.
>
> The auction should be considered closed from that calculated timestamp, although an actual transaction will still be required to finalize its state on-chain. Any subsequent bid should be rejected if the theoretical clearing time has already passed.
>
> **3. Who gets the tokens when the final bid is larger than needed?**
>
> Use first-come-first-served allocation based on on-chain transaction execution order. Earlier commitments retain priority, and only the portion of the final bid necessary to clear the remaining supply should be accepted. Any excess ETH should be refundable to the final bidder.
>
> All successful bidders receive tokens at the same uniform clearing price, with allocations proportional to their accepted ETH commitments.
>
> Refunds should use a withdrawal-based (pull-payment) mechanism rather than automatic ETH transfers.
>
> **4. What price applies if the auction reaches the deadline with unsold tokens?**
>
> The price-decay curve should reach the reserve price exactly at the 20-minute deadline, without an earlier reserve-price plateau.
>
> If the auction expires without selling out, all accepted commitments should settle at the reserve price. Any remaining unsold tokens should be burned.
>
> ## Additional Requirements
>
> **5. Irrevocable commitments:** Once confirmed on-chain, ETH commitments cannot be cancelled or reduced. Committed funds remain locked until settlement.
>
> **6. Multiple commitments:** Participants may submit multiple ETH commitments while the auction remains open. Commitments from the same address should be aggregated for accounting purposes, while preserving the transaction-level ordering necessary for first-come-first-served allocation. Subsequent commitments from an existing bidder should not inherit the priority of their earlier commitments.
>
> **7. Immediate clearing:** If a new commitment causes the auction to sell out immediately, the auction should clear at the price and timestamp of that transaction. Excess ETH from the final bid should be refundable. The calculated clearing timestamp must never precede the transaction responsible for triggering it.

**Round 2 response**

> ## Round 1 Clarifications
>
> 1. **Early termination:** Retain early sellout. The brief states that the auction clears when commitments cover supply, so 20 minutes is the maximum duration, with sellout as an alternative termination condition.
> 2. **Refunds:** Automatically calculate surplus ETH refunds at settlement. The primary Claim action must return tokens and refundable ETH in one transaction, without requiring a separate refund transaction.
>
> ## Round 2 Decisions
>
> 1. **Price decay:** Support three creator-selectable curves: linear, quadratic slow-initial (accelerating decay), and quadratic fast-initial (decelerating decay). All must decrease monotonically from starting price to reserve over exactly 1,200 seconds, without an early reserve plateau.
> 2. **Surplus from price decay:** Apply first-come-first-served priority even when declining prices trigger sellout without a new bid. Refund surplus starting with the newest commitments; minimize rounding-induced surplus.
> 3. **Finalization:** Permissionless and idempotent. Anyone may finalize after logical closure; the first claim may also finalize automatically. Clearing time and price must be independent of finalization timing. No operator dependency.
> 4. **Claims/refunds:** Provide a combined token-and-ETH Claim action, plus separate token-claim and ETH-refund fallback functions. Prevent reentrancy and double claiming; track entitlements independently. Refund entitlements are calculated automatically at settlement.
>
> ## Additional Requirements
>
> **Auction configuration:** Creator-configurable starting price, reserve price, token supply, and decay curve, immutable once bidding begins. Require `startingPrice > reservePrice > 0` and `supply > 0`. Duration fixed at 1,200 seconds. Example test prices: 0.01 ETH/token starting, 0.004 ETH/token reserve; do not hardcode.
>
> **Curves:** With (x=t/1200), (D=P_0-P_r):
>
> - Linear: (P=P_r+D(1-x))
> - Quadratic slow-initial: (P=P_r+D(1-x^2))
> - Quadratic fast-initial: (P=P_r+D(1-x)^2)
>
> **Clearing calculation:** Use binary search over integer-second timestamps (at most 11 price evaluations) to find the earliest timestamp at which existing commitments cover supply. Use the same deterministic integer price function for clearing, settlement, and frontend display.
>
> **Units and precision:** Explicitly define price units (wei per token or fixed-point equivalent), ERC-20 decimals, ETH/token conversions, and rounding rules. Use safe multiplication-before-division or `mulDiv` arithmetic to prevent overflow and precision loss. Prevent overselling, excess ETH acceptance, premature clearing, and incorrect refunds.
>
> **Accounting invariants:** Total allocated tokens ≤ supply; all accepted/refundable ETH accounted for; no duplicate claims or refunds. Preserve transaction-level priority even when aggregating multiple commitments from the same address.
>
> **Testing:** Cover all three curves, fractional tokens, small commitments, price boundaries, reserve settlement, threshold-crossing bids, repeated commitments, time-based sellout, rounding edge cases, and claim/refund security.

**Round 3 response**

> ## Round 3 Decisions
>
> 1. **Auction administration:** Support multiple auctions, with creation restricted to a single administrator wallet via OpenZeppelin `Ownable`. Only the administrator can create or cancel auctions, and cancellation is permitted strictly before an auction starts. Allow immediate or scheduled starts, with each auction lasting at most 1,200 seconds from its start timestamp. Admin controls should only appear for authorized wallets; all users can browse and participate.
>
> 2. **Token supply:** Deploy a dedicated ERC-20 token per auction. Mint the full sale supply into auction escrow before bidding, distribute sold tokens through claims, and permanently burn unsold tokens at finalization.
>
> 3. **Partial bid acceptance:** No minimum accepted ETH requirement. Accept any valid bid submitted while the auction is open, even if only a fraction is needed to clear the supply. Preserve first-come-first-served priority and automatically account for excess ETH as refundable. Reject bids after logical closure.
>
> 4. **Price rounding:** Allow flat steps caused by integer rounding. The price must be monotonically non-increasing, never fall below reserve, and first reach reserve at second 1,200. Strict per-second decreases are unnecessary.

**Round 4 response**

> ## Round 4 Decisions
>
> 1. **Cancellation:** Auction settings are immutable from creation. No editing; administrators may only cancel auctions before their scheduled start. Mint and escrow the full token supply at creation, burning it upon cancellation. Retain a minimal on-chain `Cancelled` status, but no separate cancellation log/history UI.
> 2. **Proceeds:** Each auction records an immutable payout address at creation, defaulting to the administrator wallet. After finalization, the designated recipient may withdraw sale proceeds without waiting for bidder claims, provided all outstanding ETH refund liabilities remain fully reserved. Prevent reentrancy and double withdrawals.
> 3. **Token precision:** Use 18 ERC-20 decimals and quote prices in wei per whole token. Support fractional tokens down to the smallest unit (10⁻¹⁸ tokens). Fully refund commitments that cannot purchase even one smallest token unit; also refund any ETH remainder caused by integer rounding.
> 4. **Bidder UI:** Display confirmed information: auction status, current price, starting/reserve prices, countdown, total committed ETH, and the connected wallet's commitments. Omit conditional allocation and projected sellout estimates. Upon logical closure, display the determined clearing price and enable Claim immediately; the first claim may automatically finalize the auction.

**Round 5 response**

> ## Round 5 Decisions
>
> 1. **Rounding dust:** Permit sellout based on aggregate ETH even if per-bidder integer rounding leaves negligible token dust. Burn unallocated units at finalization and refund unused wei. Ensure rounding losses remain negligible for realistic supply sizes; prevent material underallocation or incorrect ETH accounting. No complex remainder redistribution.
> 2. **Refund redirection:** Allow the original bidding address to specify an alternative ETH recipient through the refund fallback function. Only that bidding address may authorize redirection. Maintain reentrancy and double-refund protections.
> 3. **Claim expiry:** No expiration. Token claims and refund entitlements remain available indefinitely.
> 4. **Admin participation:** Allow the administrator to bid under normal participant rules. Use a single `Ownable` administrator who also receives auction proceeds; no separate payout address. The administrator may withdraw proceeds after finalization, with outstanding refunds fully reserved.
>
> ## Additional Requirement — Live Price-Curve Visualization
>
> Display the selected price-decay curve to all users, with a dynamically updating marker indicating elapsed time and current price. Show starting/reserve prices, curve type, and auction progress. Use the contract's deterministic pricing rules for consistency. Update the visualization client-side without additional transactions. Freeze the marker at the actual clearing time and price once the auction closes.

**Final round response**

> ## Final Round Decisions
>
> 1. **Settlement scalability:** Use a gas-tested maximum number of commitments per auction rather than batched settlement. Determine and justify the cap using Foundry gas benchmarks, ensuring worst-case finalization fits within gas limits and rounding losses remain negligible. Count individual commitments, including repeated bids from the same wallet. Once the cap is reached, reject new bids while allowing existing commitments to clear through price decay or expire normally.
> 2. **Administrator:** Use a single permanently fixed `Ownable` administrator who also receives auction proceeds. Disable ownership transfer and renunciation. No administrator changes or proceeds reassignment.
> 3. **Transaction UX:** Support browsing without a connected wallet, wallet/network prompts, and distinct awaiting-signature, pending, confirmed, rejected, and reverted states. Show claimed and outstanding token/refund entitlements with relevant fallback actions. Add a compact transaction activity log beneath each auction's main information, filtered to the connected wallet, showing actions, amounts, timestamps, statuses, and available transaction/explorer links. Use on-chain events and lightweight client-side storage; no backend required.
> 4. **Development and deployment:** Use Foundry/Forge for compilation, automated tests, gas benchmarking, and deployment scripts; Anvil for local blockchain testing; and a localhost frontend connected through MetaMask. After local validation, deploy contracts to Ethereum Sepolia and ensure the same frontend works with Sepolia. Public frontend hosting is optional, but Sepolia deployment is in scope. Provide reproducible setup, testing, and deployment instructions.
>
> **Out of scope:** Mainnet deployment, secondary trading, custom backend, user accounts, and notification services. Support browser wallets and the two development/demo networks (local Anvil and Ethereum Sepolia).

**Plan approval**

- **Date and tool** — 2026-11-07, Codex

> I approve the proposed implementation and testing plan. Use whole-token initial supplies while supporting fractional allocations with 18 ERC-20 decimals. Determine the commitment cap through Foundry gas benchmarks. Retain our previously agreed interpretations of early sellout and claim-triggered automatic refunds, documenting the remaining ambiguity in the course wording.

## Implementation request — 2026-11-07

> Proceed with implementation according to the approved `spec-working.md` and its testing plan. Install any missing development dependencies, including Foundry, as needed. You may execute local setup, builds, tests, and benchmarks without further approval. Verify settlement arithmetic and rounding invariants thoroughly. Document installation steps, test results, and relevant findings for the AI Audit Report. Do not deploy to Sepolia or perform actions requiring private keys or funded wallets until the local implementation is validated and I have provided the necessary configuration.

**Outcome**

- Installed/used Foundry 1.9.0 and the pinned local Solidity and web dependencies. Added the auction contracts, deployment/ABI scripts, tests, and React frontend.
- Ran the full Foundry suite: 30 tests passed, 0 failed, including fuzz properties and 10 cap benchmarks. The factory now fixes the gas-tested cap at 64 commitments. A first Claim at cap 64 that transfers both tokens and a refund measured 4,075,434 gas (4,029,678 gas for a refund-only claimant); cap 128 measured 7,787,246 gas.
- `forge fmt --check`, the two frontend integer-curve tests, and the frontend production build passed. The settlement review and measured results are summarized in `AI_AUDIT_REPORT.md`.
- Opened the localhost UI without a connected wallet and verified it displays the expected factory-configuration prompt. No wallet was connected.
- No Anvil deployment or wallet transaction was performed. No Sepolia deployment, private-key operation, or funded-wallet action was performed.

## Refinement — Add to MetaMask functionality

> **Refinement — Add to MetaMask functionality**
>
> Add an **Add to MetaMask** button to the auction interface, allowing bidders to conveniently import the auction's ERC-20 token into MetaMask without manually entering its contract address.
>
> - Use the EIP-747 `wallet_watchAsset` method, supplying the auction token's contract address, symbol, and decimals.
> - Dynamically identify the correct token for each auction, since every auction deploys a separate ERC-20 token.
> - Display the button after a successful token claim, and keep it accessible afterward for users who have already claimed.
> - Handle wallet rejection, unsupported wallets, and incorrect network selection gracefully.
> - Adding the token must remain optional and require no gas fees or blockchain transaction.
>
> Preserve existing bidding and claiming functionality. Implement and test this refinement on the local Anvil network, ensuring compatibility with Sepolia. (Record this prompt in the prompt log and potentially audit report if necessary.)

**Outcome**

- Added an optional **Add to MetaMask** action for claimed tokens. It reads the selected auction token's address, symbol, and decimals from the chain and checks the wallet network before requesting `wallet_watchAsset`.
- In Chrome with MetaMask on Anvil, opened the CateCoin prompt from an existing claim, dismissed it, then reopened and approved it. The account transaction count stayed at six.
- The frontend build and all five frontend tests passed. The tests cover the Anvil and Sepolia request paths, wrong networks, and wallet failures. Live Sepolia validation awaits a configured deployment.

## Sepolia deployment — 2026-11-08

- **Date and tool** — 2026-11-08, Kiro
- **Task and context** — Bring the implementation onto a live testnet to fulfill the Sepolia deployment scope. The contract and frontend had been validated on local anvil only. Alchemy was chosen for the JSON-RPC endpoint on the basis of the `hello-dapp` reference workflow in the course materials (Infura in the original, Alchemy as the current equivalent).

**Prompt**

> Deploy the `AuctionFactory` contract to the Ethereum Sepolia testnet using the tooling recommended in the course materials.
>
> - Use Alchemy as the JSON-RPC provider, consistent with the course's `hello-dapp` reference workflow.
> - Reuse the existing MetaMask development wallet. Store `SEPOLIA_RPC_URL` and `PRIVATE_KEY` in a gitignored root `.env` derived from `.env.example`.
> - Pre-flight: verify the private key derives to the expected address, that the configured RPC reports Sepolia's chain id, and that the deployer wallet is funded. Document the funding sources used.
> - After deployment, confirm by reading factory state over the same RPC, then exercise the full flow end-to-end on the live chain: create one auction, place bids from two separate wallets, and finalize through a bidder claim.
> - Write the deployed factory address, RPC URL, and deployment block into `web/.env.local` without clobbering any anvil values. Any code change required to accommodate Sepolia must remain consistent with local anvil behavior.

**Outcome and follow-ups**

- Created a Sepolia Alchemy app and populated `.env` with the HTTPS endpoint and the dev wallet's exported private key (`0x33C8Dfe2150C7E294b97b51f17f929E7D06850B8`). Funded the wallet via the Google Cloud Sepolia faucet, topped up through PK910's proof-of-work faucet after the next-drop cooldown.
- Pre-flight validated key → address derivation, chain id `11155111`, and wallet balance before broadcasting.
- `forge create src/AuctionFactory.sol:AuctionFactory` with Foundry's default gas handling deployed the factory at `0xB200E4c71ba447281869880f895f24F825407173`, block `12089885`.
- Reduced `MAX_LOG_BLOCK_RANGE` from 2000 to 10 in `web/src/ui/App.tsx` so each `eth_getLogs` call stays inside Alchemy's free-tier 10-block range cap. The scan loop is otherwise unchanged; anvil, which has no such limit, keeps working.
- End-to-end exercise on Sepolia: one auction at `0x8AE8F3367548a690B2A8f087206B1472C5B32C1a`, bids from two wallets, finalization through bidder claims. Final state: 100 TST supply, 37.5 allocated across both bidders, 62.5 burned, 0.15 ETH in sale proceeds.
- The existing anvil deployment path and 30/30 Foundry test suite remained untouched by the Sepolia work.

**Evidence**

- Commit `688395e`. Factory on Etherscan: <https://sepolia.etherscan.io/address/0xB200E4c71ba447281869880f895f24F825407173>.

## Reproducibility scripts — 2026-11-08

- **Date and tool** — 2026-11-08, Kiro
- **Task and context** — Package every reproduction path behind shell wrappers so a grader can go from a bare clone to a running demo with a single command per path. The earlier instructions were spread across multiple README sections and assumed the reader would assemble them; this replaces that with scripts the reader runs directly.

**Prompt**

> Make the repository fully reproducible from a bare clone. Package every reproduction path (install + build + full test suite; local anvil demo; Sepolia deployment) behind shell scripts under a new top-level folder so a grader can go from `git clone` to a running demo with a single command per path.
>
> - `reproduce/install.sh`: install Foundry at the pinned version if missing, run `npm ci --prefix web`, build contracts, run the full Foundry suite, regenerate ABIs, run frontend unit tests, and produce the Vite production bundle. Exit non-zero on the first failure.
> - `reproduce/anvil-deploy.sh` plus `reproduce/anvil-start.sh` and `reproduce/anvil-stop.sh`: deploy to a background-managed anvil in a single terminal and write anvil env values to `web/.env.local` without clobbering Sepolia values. The start script must be idempotent and the PID tracked for clean teardown.
> - `reproduce/sepolia-deploy.sh`: read the root `.env`, broadcast `forge create` with Foundry's default gas handling, parse the resulting address and deployment block, and write the Sepolia env values into `web/.env.local` without clobbering anvil values.
> - Rewrite the README's install, local demo, and Sepolia sections around these scripts. The new folder name must not be confusable with the existing Solidity `script/` directory. Update `.gitignore` for any runtime files the scripts create.

**Outcome and follow-ups**

- Added five executable scripts under `reproduce/` (named to avoid confusion with Solidity `script/`): `install.sh`, `anvil-start.sh`, `anvil-stop.sh`, `anvil-deploy.sh`, `sepolia-deploy.sh`. Each uses `set -euo pipefail`, exits non-zero on failure, and prints a next-step command line on success.
- `anvil-start.sh` spawns anvil in the background only when no listener answers on the default port, tracks the PID in `.anvil.pid`, and tails `anvil.log`. `anvil-deploy.sh` delegates to it so one terminal covers both. `anvil-stop.sh` only touches PIDs it owns, leaving hand-started anvils to the user.
- Both deploy scripts update `web/.env.local` through a small Python helper that preserves existing values on the opposite network.
- Updated `.gitignore` to cover `.anvil.pid` and `tsconfig.tsbuildinfo` (and untracked the previously-committed buildinfo file).
- Rewrote the README install, local demo, and Sepolia sections around the scripts; added a short "Reproduce from scratch" header so the scripts are the first thing a reader sees.
- Verified end-to-end on both chains: `install.sh` runs green, `anvil-deploy.sh` brings up a fresh factory on anvil, `sepolia-deploy.sh` deploys a second factory to Sepolia (which was reverted locally after the test so the committed documentation continues to point at the reference deployment).

**Evidence**

- Commits `688395e` (initial three scripts + README rewrite) and `7ed4854` (`anvil-start` / `anvil-stop` split).

## UI split refactor — 2026-11-08

- **Date and tool** — 2026-11-08, Kiro
- **Task and context** — The frontend was a single scrolling page: hero, auction list, auction detail, and create-auction form all rendered on one route. Split it into a landing page and a dashboard with a sidebar, without changing any contract interaction, wallet handling, or on-chain read logic. Shift the palette from dark to bold light-mode.

**Prompt**

> Restructure the frontend into two views without changing any contract interaction, wallet handling, or on-chain read logic.
>
> - Introduce a landing page containing the existing hero, a short "how it works" section with three steps, and a single call-to-action that transitions to the dashboard. Remove network and wallet controls from the landing page.
> - Introduce a dashboard view with a left sidebar and a main content area. The sidebar contains the brand, navigation items for "Live auctions" and "Create auctions", the network dropdown, and the connect-wallet control. The main area renders the existing auction section or create-auction form based on the selected nav item.
> - Keep the "Create auctions" sidebar item gated by the pre-existing `isAdmin && factoryAddress` condition. Do not add any new admin logic.
> - Persist the active view, selected dashboard section, and selected network to `localStorage` so a reload returns the user to the same place.
> - Pin the dashboard layout with the sidebar and main area owning their own scrolls; the sidebar must not move with page scroll.
> - Replace the dark palette with a bold light-mode scheme (warm off-white background, near-black text, saturated accent, thick outlines, hard-edged accent shadows on cards and buttons).
> - Enable Multicall3 aggregation on the Sepolia public client so the per-render read volume does not exceed the free-tier compute-unit limit. Keep anvil's transport simple since fresh anvil does not deploy Multicall3.

**Outcome and follow-ups**

- Added `view` (`"landing" | "dashboard"`) and `dashboardSection` (`"auctions" | "create"`) state. All three state values plus `network` are persisted to `localStorage` under a `drop/` prefix.
- Landing page carries the existing hero, a new three-card "how it works" section, and a "Launch app" button. Dashboard carries the left sidebar (brand, nav, network dropdown, wallet button) and main area that renders the pre-existing auction section or create-auction section unchanged. The "Create auctions" nav button is gated on the pre-existing `isAdmin && factoryAddress` condition.
- Dashboard shell pinned at `height: 100vh` with `overflow: hidden`; sidebar and main area each own an independent `overflow-y: auto`, so the sidebar stays put while content scrolls. Mobile breakpoint releases the pin and stacks the layout.
- Palette replaced in `styles.css`: warm cream background, near-black ink, emerald accent, 1.5px black outlines with hard-edged accent shadows on cards and buttons. All component classnames retained.
- `publicClientFor("sepolia")` now uses viem's Multicall3 batching (`batch.multicall` at the canonical address) plus a retry policy on the http transport (3 attempts, 500ms). The ~18 read calls that fire on every refresh collapse into a single `eth_call`, which keeps per-render traffic under Alchemy's free-tier compute-unit ceiling and ends the `Failed to fetch` bursts on account/network switches. Anvil's client keeps plain HTTP batching because fresh anvil does not deploy Multicall3.
- No contract calls, event signatures, wallet flows, or auction logic were changed. The 30/30 Foundry suite and 5/5 frontend tests still pass.

**Evidence**

- Commit `c5b5bfc`.
