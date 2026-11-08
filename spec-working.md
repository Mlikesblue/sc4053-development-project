# Dutch Auction dApp Specification and Implementation Plan

The specification and implementation and testing plans were approved on 2026-11-07. The [original course baseline](./spec.md) comes from Section 5.2, pages 5–6 of the [SC4053 Development Project brief](./project.pdf). The [AI prompt log](./ai-log.md) records the interview and approval.

## Scope

Build Ethereum smart contracts and a web front end for a token launch in which participants commit Ether (ETH) and receive ERC-20 tokens through a Dutch auction. Define the ERC-20 project token separately from the auction contract.

- Support browser wallets, with MetaMask as the demo wallet, on local Anvil and Ethereum Sepolia. Run the same front end on localhost against either network. Public front-end hosting is optional.
- Mainnet deployment, secondary trading, a custom backend, user accounts, and notification services are out of scope.

## Auction administration and inventory

- Support multiple independent auctions. One permanently fixed administrator wallet, enforced on-chain through OpenZeppelin `Ownable`, can create and cancel auctions and withdraw proceeds. Disable ownership transfer and renunciation. Cancellation is allowed only before the auction's start timestamp.
- Support immediate starts and scheduled future starts. An auction accepts bids from its start timestamp until logical closure, which occurs no later than 1,200 seconds after that start.
- All users can browse auctions and participate when bidding is open. The administrator may bid under the same rules as any other wallet. Show creation and cancellation controls only to the authorized administrator wallet, with cancellation available only for auctions that have yet to start.
- Deploy a dedicated ERC-20 token for each auction and mint the full sale supply into that auction's escrow at creation. Winners claim their allocations from escrow. Finalization permanently burns any unsold inventory. Pre-start cancellation burns the full escrow and leaves a minimal on-chain `Cancelled` status. The front end has no separate cancellation log or history view.

## Configuration and price curves

- The administrator configures starting price, reserve price, sale supply, and decay curve. Auction settings are immutable from creation. Require `startingPrice > reservePrice > 0` and `supply > 0`. The maximum duration is fixed at 1,200 seconds.
- Let `t` be the elapsed seconds clamped to the range 0–1,200, `x = t / 1200`, `D = startingPrice - reservePrice`, and `Pr = reservePrice`.

| Curve | Price |
| --- | --- |
| Linear | `Pr + D * (1 - x)` |
| Quadratic slow-initial (accelerating decay) | `Pr + D * (1 - x²)` |
| Quadratic fast-initial (decelerating decay) | `Pr + D * (1 - x)²` |

- All three curves start at the configured starting price, are monotonically non-increasing at integer-second resolution, and first reach the reserve at 1,200 seconds. Integer rounding may produce flat steps above the reserve.
- Use one deterministic integer price function as the source of truth for clearing, settlement, and what the front end displays. Preserve the curve's precision until the final division.
- Use 0.01 ETH per token and 0.004 ETH per token as example starting and reserve prices in tests. The contract takes its prices from configuration.

## Auction and commitments

- The auction closes at the first of sellout or the 20-minute deadline. Sellout occurs when accepted ETH is enough to buy the full token supply at the applicable price.
- Confirmed commitments are irrevocable and stay locked until settlement. A wallet can commit multiple times. Aggregate accepted ETH by wallet for settlement while preserving priority by individual transaction execution order. A later commitment from the same wallet has its own place in that order.
- If a new commitment reaches the sellout threshold, lock the clearing price and timestamp to that transaction. Accept only the ETH needed to reach the threshold and make the surplus withdrawable at settlement. The timestamp cannot precede the commitment that made sellout possible.
- A valid bid has no bidder-specified minimum accepted amount. If only a fraction is needed to clear, accept that fraction and automatically account for the rest as refundable.
- Enforce a maximum of **64 commitments per auction**, fixed in the factory from Foundry gas benchmarks. Each accepted bid call counts separately in execution order, including repeated calls by the same wallet or within one transaction. Once the cap is reached, reject further bids. Existing commitments can still clear through price decay or expire normally. The cap bounds both settlement work and per-bidder rounding dust.
- After an accepted commitment, determine the earliest timestamp at which those commitments would cover the full supply as the price falls. If the auction reaches that timestamp before another commitment changes it, bidding closes at that timestamp. A later transaction records the result using the price at the computed timestamp. Any bid executed at or after the computed close is rejected, including before finalization has been recorded.
- If price decay alone triggers sellout and commitments exceed the cost at the first qualifying timestamp, refund surplus beginning with the newest individual commitments. Minimize rounding-induced surplus.
- If the deadline arrives without sellout, settle at the reserve price and permanently burn the unsold tokens. If commitments first cover supply at the deadline, settle as a sellout at the reserve.

## Settlement

- Every winner settles at the same final price, with each wallet's allocation rounded down to whole smallest token units. Aggregate ETH can trigger sellout even when per-wallet rounding leaves negligible unallocated token units. Burn those units at finalization and refund unused whole wei. Prevent material underallocation without redistributing rounding leftovers.
- Automatically calculate surplus ETH entitlements at settlement. The primary bidder-initiated **Claim** action delivers both tokens and any refundable ETH in one transaction. Separate token claim and ETH refund functions are available as fallbacks.
- Track token and refund entitlements independently across all claim functions. Prevent reentrancy and duplicate claims or refunds.
- Token claims and refund entitlements do not expire. Only the original bidding address may authorize a different ETH recipient through the refund fallback function.
- Finalization is permissionless and idempotent. After a time-based close, anyone can record the outcome, and the first eligible claim can finalize and settle in the same transaction. The recorded closing time and price are independent of when finalization is submitted.
- The fixed administrator receives sale proceeds. After finalization, the administrator can withdraw sale proceeds before bidders claim, while the contract retains enough ETH to cover every outstanding refund. Prevent reentrancy and duplicate proceeds withdrawals. Proceeds cannot be reassigned.

## Units and accounting

- Use 18 ERC-20 decimals and quote the price in wei per whole token. The smallest transferable amount is `10^-18` tokens. Fully refund a wallet's accepted ETH if its combined commitments buy less than one smallest token unit at settlement, and refund any whole-wei remainder caused by integer rounding.
- Use safe multiplication before division or full-precision `mulDiv` arithmetic. The clearing threshold must use the same price and compatible rounding as settlement to prevent premature clearing, overselling, excess ETH acceptance, and incorrect refunds.
- Total allocated tokens must be at most the configured supply. Account for every wei received through bidding as a pending commitment, sale proceeds, or refundable ETH, including amounts already withdrawn. Preserve transaction-level priority even when presenting or settling wallet-level totals.

## Front end

- Show auction status, current price, starting and reserve prices, countdown, total committed ETH, and the connected wallet's confirmed commitments. Omit conditional allocation and projected sellout estimates.
- Show the selected price-decay curve and its type to all users, along with starting and reserve prices and auction progress. Update a marker for elapsed time and current price client-side, using the contract's deterministic integer pricing rules. The chart requires no transactions. At logical closure, freeze the marker at the determined closing time and price, including when finalization is still pending.
- Distinguish scheduled, open, at commitment capacity, closed awaiting finalization, finalized, and cancelled auctions. Capacity disables bidding while the clock and curve continue until logical closure. At closure, show the determined clearing price and enable **Claim** for eligible wallets even before finalization is recorded.
- After a bidder claims tokens, offer an optional **Add to MetaMask** button when they view the auction with that account. Read the selected auction token's address, symbol, and decimals on chain and use EIP-747 `wallet_watchAsset` on the matching wallet network. Handle rejection and unsupported wallets with a clear message and offer the contract address for manual import when the request fails. Adding the token affects wallet display and requires no transaction or gas.
- Allow browsing without a wallet. Prompt for a wallet connection or network switch when an action needs one. Show distinct awaiting-signature, pending, confirmed, rejected, and reverted transaction states. Show claimed and outstanding token and ETH entitlements and the relevant claim or refund fallbacks.
- Show a compact activity log beneath the main auction information for the connected wallet. Include action, amount, time, status, and transaction or explorer links where available. Use on-chain events and transaction receipts for confirmed results and lightweight browser storage for locally observed attempts and pending state. Scope data to the network, auction, and wallet. Rejected wallet prompts without a transaction hash are local entries.
- Show creation and eligible cancellation controls only for the fixed administrator. Show the administrator the available proceeds and the withdrawal action after finalization.

## Settlement arithmetic

- **Price rounding.** Evaluate the chosen curve with integer-second elapsed time. Round the positive premium above reserve up at the final division, which makes the price reach reserve for the first time at second 1,200. Use identical arithmetic for the chart and contract.
- **Sale inventory.** Require a positive whole number of tokens per auction. Bidder allocations can be fractional down to one smallest unit. At integer price `P` wei per whole token, a supply of `N` whole tokens costs exactly `N * P` wei. Validate inventory and maximum cost against integer limits.
- **Settlement conversion.** With `U = 10^18` and wallet budget `B` in wei after trimming newer commitments, allocate `floor(B * U / P)` smallest units. Charge `ceil(allocatedUnits * P / U)` wei and refund the difference, plus any precredited or trimmed surplus. This refunds all of `B` for zero units and keeps the wallet's charge at or below its budget. Each positive allocation can cost less than one wei above its exact mathematical value because ETH settles in whole wei. At sellout, the total unallocated dust is less than one smallest token unit per wallet with a retained budget. The gas-tested commitment cap also bounds the number of those wallets.

## Implementation plan

1. Set up Foundry compilation, tests, gas benchmarks, and deployment scripts. Implement the fixed administrator, on-chain auction discovery, immutable settings, dedicated token escrow, and pre-start cancellation.
2. Implement deterministic pricing and the bid path. Check the existing close before accepting a bid. Lock the price and timestamp on immediate sellout. Otherwise, test coverage at the reserve and binary search for the first qualifying integer-second timestamp between the latest accepted commitment and the deadline, using at most 11 price evaluations inside the search. Check the execution-time price separately when evaluating the incoming bid.
3. Retain commitment order and wallet totals. On finalization, apply the final cost cutoff in transaction order, aggregate retained amounts by wallet, compute the token and refund entitlements, and burn unallocated tokens. Make finalization and first-claim settlement atomic. Pin the factory commitment cap to 64 based on worst-case finalization and refund-bearing first-claim benchmarks under a 5,000,000 gas project budget. No batched settlement.
4. Implement combined claims, token-only claims, refund withdrawals with authorized redirection, and administrator withdrawals against shared accounting. Update entitlements before external transfers and guard against reentrancy. Preserve the fallback paths if a combined claim cannot deliver ETH.
5. Build the public auction list and details, administrator controls, curve visualization, wallet connection, and wallet activity log. Derive authoritative close state from chain reads. Advance the marker locally between reads and reconcile it to chain state.
6. Validate the full flow on Anvil with MetaMask, then deploy the contracts to Sepolia and smoke-test the same localhost front end. Document dependencies, network settings, setup, tests, gas benchmarks, deployment, and verification steps. Save representative test results and transaction hashes for the AI Audit Report.

## Testing plan

| Area | Coverage |
| --- | --- |
| Administration and inventory | Fixed ownership, unauthorized calls, admin bidding, immutable settings, scheduled and immediate starts, pre-start cancellation and full burn, cancellation at the start boundary, and isolation across auctions. |
| Pricing and clearing | All three curves, narrow price spreads, endpoints, first reserve occurrence, binary-search results against a linear-scan reference, exact and oversized bids, repeated wallets, same-block ordering, decay-triggered sellout, late bid rejection, reserve expiry, and close time and price independent of finalization. |
| Settlement and security | Fuzz conversion and aggregate accounting. Cover fractional allocations, small bids, zero-unit refunds, newest-first trimming, dust burns, no overselling, ETH conservation, idempotent finalization, indefinite entitlements, combined and fallback claims, authorized refund redirection, duplicate claims and withdrawals, reentrancy attempts, and proceeds withdrawal with refunds fully reserved. |
| Gas and cap | Measure finalization and first claim at candidate caps. Include all-distinct and repeated bidders, partial and full trimming, burns, refund-bearing claims, and a bid that fills the last slot. Verify cap-plus-one rejection and both decay-triggered close and deadline expiry at capacity. Record benchmark commands, results, chosen cap, and gas headroom. |
| Front end and deployment | Verify all curve markers against on-chain prices, chart freeze at immediate sellout, time-based sellout, and expiry, capacity and claim states, wallet and network switches, transaction errors, activity filtering and links, then run an end-to-end Anvil flow and Sepolia smoke test. |

### Measured cap decision

The factory pins 64 commitments per auction. Under Foundry gas benchmarks, finalization used 3,994,209 gas. A refund-bearing first Claim by a fully trimmed bidder used 4,029,678 gas; the more demanding first Claim by a partially trimmed bidder that receives both tokens and ETH used 4,075,434 gas. The repeated-bidder first-claim case used 676,841 gas. At 128 commitments, finalization used 7,751,777 gas and first Claim used 7,787,246 gas. The project selected 64 against a 5,000,000 gas budget, leaving 924,566 gas of headroom in the combined token-and-refund first-claim case. The cap also limits worst-case rounding dust to at most 64 smallest token units (`6.4×10^-17` whole tokens).

## Course brief interpretations

- **Duration.** The brief says “exactly 20 minutes” and describes clearing when commitments cover the supply. The team reads 20 minutes as the maximum and has chosen early closure on sellout. Course interpretation remains unverified.
- **Refunds.** The brief calls for automatic processing of surplus ETH refunds. The design calculates entitlements at settlement and sends any refund as part of the primary token claim. If the course expects ETH to arrive without bidder action, this design still requires a claim transaction.

## Bonus

- Demonstrate resistance to a reentrancy attack.
