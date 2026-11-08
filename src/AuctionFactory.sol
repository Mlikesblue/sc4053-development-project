// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {DutchAuction} from "./DutchAuction.sol";

/// @notice Creates independent Dutch auctions for a permanently fixed administrator.
contract AuctionFactory is Ownable {
    error OwnershipIsFixed();
    error InvalidStartTime();

    uint32 public constant COMMITMENT_CAP = 64;

    event AuctionCreated(uint256 indexed auctionId, address indexed auction, address indexed token, uint256 startTime);

    struct AuctionInput {
        string tokenName;
        string tokenSymbol;
        uint256 wholeTokenSupply;
        uint256 startingPriceWeiPerToken;
        uint256 reservePriceWeiPerToken;
        DutchAuction.Curve curve;
        uint64 scheduledStartTime;
    }

    address[] private _auctions;

    constructor() Ownable(msg.sender) {}

    function transferOwnership(address) public pure override {
        revert OwnershipIsFixed();
    }

    function renounceOwnership() public pure override {
        revert OwnershipIsFixed();
    }

    function auctionCount() external view returns (uint256) {
        return _auctions.length;
    }

    function auctionAt(uint256 index) external view returns (address) {
        return _auctions[index];
    }

    function createAuction(AuctionInput calldata input) external onlyOwner returns (address auctionAddress) {
        uint64 start = input.scheduledStartTime;
        if (start == 0) {
            if (block.timestamp > type(uint64).max - 1_200) revert InvalidStartTime();
            // forge-lint: disable-next-line(unsafe-typecast)
            start = uint64(block.timestamp);
        } else if (start <= block.timestamp) {
            revert InvalidStartTime();
        }

        DutchAuction.Config memory config = DutchAuction.Config({
            admin: owner(),
            startTime: start,
            commitmentCap: COMMITMENT_CAP,
            startingPriceWeiPerToken: input.startingPriceWeiPerToken,
            reservePriceWeiPerToken: input.reservePriceWeiPerToken,
            wholeTokenSupply: input.wholeTokenSupply,
            curve: input.curve,
            tokenName: input.tokenName,
            tokenSymbol: input.tokenSymbol
        });
        DutchAuction auction = new DutchAuction(config);
        auctionAddress = address(auction);
        _auctions.push(auctionAddress);

        emit AuctionCreated(_auctions.length - 1, auctionAddress, address(auction.token()), start);
    }

    function cancelAuction(address auction) external onlyOwner {
        DutchAuction(auction).cancel();
    }
}
