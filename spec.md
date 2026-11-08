# Dutch Auction dApp Specification

This is an AI-assisted baseline extracted from the [SC4053 Development Project brief](./project.pdf), Section 5.2, pages 5–6.

## Scope

Build Ethereum smart contracts and a web front end for a token launch in which participants commit Ether (ETH) and receive ERC-20 tokens through a Dutch auction.

## Required behavior

- **Token and auction contracts.** Define an ERC-20 project token and implement the auction mechanics in one or more separate smart contracts.
- **Descending price.** Open bidding at a high starting price and lower it automatically over time using a predefined decay function.
- **Clearing threshold.** Clear the auction when total committed ETH is enough to buy the available token supply at the current price.
- **Uniform clearing price.** Charge every winning bidder the same final price per token, regardless of the price when they committed ETH.
- **Duration and reserve.** Run the auction for exactly 20 minutes, as stated in the brief. Tokens sell out at or above the reserve price, or any unsold tokens are permanently burned.
- **Settlement.** Distribute minted tokens to winning bidders and automatically refund surplus ETH.

## Bonus

- Demonstrate resistance to a reentrancy attack.

## Questions to resolve

- If commitments reach the clearing threshold before 20 minutes, when does bidding close?
- How should the auction use EVM block timestamps for the countdown and price decay?
- How should tokens and surplus ETH be calculated for a bid that crosses the clearing threshold?
- What triggers automatic refunds, and how will the auction process them safely?
- How will the token contract permanently burn unsold supply?
