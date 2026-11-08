// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {DutchAuction} from "../src/DutchAuction.sol";

contract GasBenchmarkTest is Test {
    address private admin = address(0xA11CE);
    uint64 private start;

    function setUp() public {
        start = uint64(block.timestamp);
    }

    function _benchmark(uint32 cap, bool claimFinalizes, bool repeatedBidder, bool partialTrimClaim) internal {
        DutchAuction.Config memory config = DutchAuction.Config({
            admin: admin,
            startTime: start,
            commitmentCap: cap,
            startingPriceWeiPerToken: 7,
            reservePriceWeiPerToken: 3,
            wholeTokenSupply: uint256(cap) * 31,
            curve: DutchAuction.Curve.Linear,
            tokenName: "Gas Token",
            tokenSymbol: "GAS"
        });
        DutchAuction auction = new DutchAuction(config);

        vm.pauseGasMetering();
        if (repeatedBidder) {
            vm.deal(address(uint160(0x1000)), uint256(cap) * 100);
        }
        for (uint256 i; i < cap; ++i) {
            address bidder = repeatedBidder ? address(uint160(0x1000)) : address(uint160(0x1000 + i));
            if (!repeatedBidder) vm.deal(bidder, 100);
            vm.prank(bidder);
            auction.bid{value: 100}();
        }
        vm.warp(uint256(start) + 1_200);
        vm.resumeGasMetering();

        address firstClaimant;
        uint256 claimantBalanceBefore;
        if (claimFinalizes) {
            if (repeatedBidder) {
                firstClaimant = address(uint160(0x1000));
            } else if (partialTrimClaim) {
                uint256 fullyTrimmedCommitments = uint256(cap) * 7 / 100;
                firstClaimant = address(uint160(0x1000 + uint256(cap) - fullyTrimmedCommitments - 1));
            } else {
                firstClaimant = address(uint160(0x1000 + cap - 1));
            }
            claimantBalanceBefore = firstClaimant.balance;
        }
        uint256 gasBefore = gasleft();
        if (claimFinalizes) {
            vm.prank(firstClaimant);
            auction.claim();
        } else {
            auction.finalize();
        }
        uint256 used = gasBefore - gasleft();
        uint256 paidRefund = claimFinalizes ? firstClaimant.balance - claimantBalanceBefore : 0;
        emit log_named_uint(
            string.concat("gas/", vm.toString(cap), claimFinalizes ? "/first-claim-finalizes" : "/finalize"), used
        );

        assertTrue(auction.finalized());
        assertEq(auction.commitmentCount(), cap);
        assertLe(auction.totalAllocatedTokens(), auction.tokenSupply());
        if (repeatedBidder) assertEq(auction.totalBurnedTokens(), 0);
        else assertGt(auction.totalBurnedTokens(), 0);
        if (partialTrimClaim) {
            assertGt(auction.tokenEntitlement(firstClaimant), 0);
            assertGt(auction.refundEntitlement(firstClaimant), 0);
        }
        assertTrue(paidRefund != 0 || auction.totalRefundLiability() != 0);
        assertEq(
            auction.totalSaleProceeds() + auction.totalRefundLiability() + paidRefund + auction.proceedsWithdrawn(),
            auction.totalEthReceived()
        );
        assertEq(
            address(auction).balance,
            auction.totalSaleProceeds() - auction.proceedsWithdrawn() + auction.totalRefundLiability()
        );
    }

    function testGasFinalizeAtCap16() public {
        _benchmark(16, false, false, false);
    }

    function testGasFirstClaimAtCap16() public {
        _benchmark(16, true, false, false);
    }

    function testGasFinalizeAtCap32() public {
        _benchmark(32, false, false, false);
    }

    function testGasFirstClaimAtCap32() public {
        _benchmark(32, true, false, false);
    }

    function testGasFinalizeAtCap64() public {
        _benchmark(64, false, false, false);
    }

    function testGasFirstClaimAtCap64() public {
        _benchmark(64, true, false, true);
    }

    function testGasFirstClaimAtCap64RefundOnly() public {
        _benchmark(64, true, false, false);
    }

    function testGasFirstClaimAtCap64RepeatedBidder() public {
        _benchmark(64, true, true, false);
    }

    function testGasFinalizeAtCap128() public {
        _benchmark(128, false, false, false);
    }

    function testGasFirstClaimAtCap128() public {
        _benchmark(128, true, false, false);
    }
}
