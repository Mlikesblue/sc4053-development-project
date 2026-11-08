// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice One fixed-supply ERC-20 escrow token for a single auction.
contract AuctionToken is ERC20 {
    error OnlyAuction();

    address public immutable auction;

    constructor(string memory name_, string memory symbol_, uint256 supply_, address auction_) ERC20(name_, symbol_) {
        if (auction_ == address(0)) revert OnlyAuction();
        auction = auction_;
        _mint(auction_, supply_);
    }

    function burnEscrow(uint256 amount) external {
        if (msg.sender != auction) revert OnlyAuction();
        _burn(auction, amount);
    }
}
