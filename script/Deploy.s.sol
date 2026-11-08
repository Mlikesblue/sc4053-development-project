// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";

import {AuctionFactory} from "../src/AuctionFactory.sol";

/// @notice Deploy with Forge only after reviewing the script and selected network.
contract Deploy is Script {
    error UnsupportedChain();

    function run() external returns (AuctionFactory factory) {
        if (block.chainid != 31_337 && block.chainid != 111_55111) revert UnsupportedChain();

        uint256 privateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        if (privateKey == 0) vm.startBroadcast();
        else vm.startBroadcast(privateKey);
        factory = new AuctionFactory();
        vm.stopBroadcast();
    }
}
