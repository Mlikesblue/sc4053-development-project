// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AuctionFactory} from "../src/AuctionFactory.sol";
import {AuctionToken} from "../src/AuctionToken.sol";
import {DutchAuction} from "../src/DutchAuction.sol";

contract RejectingReceiver {
    DutchAuction private immutable auction;

    constructor(DutchAuction auction_) {
        auction = auction_;
    }

    function bid() external payable {
        auction.bid{value: msg.value}();
    }

    function claim() external {
        auction.claim();
    }

    function claimTokens() external {
        auction.claimTokens();
    }

    receive() external payable {
        revert("reject ETH");
    }
}

contract ReenteringReceiver {
    DutchAuction private immutable auction;
    bool public attemptedReentry;
    bool public reentrySucceeded;

    constructor(DutchAuction auction_) {
        auction = auction_;
    }

    function bid() external payable {
        auction.bid{value: msg.value}();
    }

    function claim() external {
        auction.claim();
    }

    receive() external payable {
        attemptedReentry = true;
        try auction.claim() {
            reentrySucceeded = true;
        } catch {}
    }
}

contract DutchAuctionTest is Test {
    uint256 private constant U = 1e18;
    uint256 private constant START_PRICE = 10 ether;
    uint256 private constant RESERVE_PRICE = 4 ether;

    address private admin = address(0xA11CE);
    address private alice = address(0xA1);
    address private bob = address(0xB0B);
    uint64 private start;

    function setUp() public {
        start = uint64(block.timestamp);
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(admin, 1_000 ether);
    }

    function _deploy(uint256 supply, uint256 startingPrice, uint256 reservePrice, DutchAuction.Curve curve, uint32 cap)
        internal
        returns (DutchAuction)
    {
        DutchAuction.Config memory config = DutchAuction.Config({
            admin: admin,
            startTime: start,
            commitmentCap: cap,
            startingPriceWeiPerToken: startingPrice,
            reservePriceWeiPerToken: reservePrice,
            wholeTokenSupply: supply,
            curve: curve,
            tokenName: "Auction Token",
            tokenSymbol: "AUC"
        });
        return new DutchAuction(config);
    }

    function _ceilDiv(uint256 numerator, uint256 denominator) private pure returns (uint256) {
        return numerator == 0 ? 0 : (numerator - 1) / denominator + 1;
    }

    function _referencePrice(DutchAuction.Curve curve, uint256 startingPrice, uint256 reservePrice, uint256 elapsed)
        private
        pure
        returns (uint256)
    {
        if (elapsed == 0) return startingPrice;
        if (elapsed >= 1_200) return reservePrice;
        uint256 remaining = 1_200 - elapsed;
        uint256 numerator;
        uint256 denominator;
        if (curve == DutchAuction.Curve.Linear) {
            numerator = remaining;
            denominator = 1_200;
        } else if (curve == DutchAuction.Curve.QuadraticSlowInitial) {
            numerator = 1_200 * 1_200 - elapsed * elapsed;
            denominator = 1_200 * 1_200;
        } else {
            numerator = remaining * remaining;
            denominator = 1_200 * 1_200;
        }
        return reservePrice + _ceilDiv((startingPrice - reservePrice) * numerator, denominator);
    }

    function testAllCurvesMatchReferenceAtEverySecondAndStayMonotone() public {
        for (uint8 curveIndex; curveIndex < 3; ++curveIndex) {
            DutchAuction auction = _deploy(1, 2 ether + 7, 1 ether + 3, DutchAuction.Curve(curveIndex), 64);
            uint256 priorPrice = auction.priceAtElapsed(0);
            assertEq(priorPrice, 2 ether + 7);
            for (uint256 elapsed = 1; elapsed <= 1_200; ++elapsed) {
                uint256 price = auction.priceAtElapsed(elapsed);
                assertEq(price, _referencePrice(DutchAuction.Curve(curveIndex), 2 ether + 7, 1 ether + 3, elapsed));
                assertLe(price, priorPrice);
                assertGe(price, 1 ether + 3);
                if (elapsed < 1_200) assertGt(price, 1 ether + 3);
                priorPrice = price;
            }
        }
    }

    function testCurveEndpointsAndRoundingPlateaus() public {
        DutchAuction auction = _deploy(1, 2, 1, DutchAuction.Curve.QuadraticFastInitial, 64);
        assertEq(auction.priceAtElapsed(0), 2);
        assertEq(auction.priceAtElapsed(1), 2);
        assertEq(auction.priceAtElapsed(1_199), 2);
        assertEq(auction.priceAtElapsed(1_200), 1);
    }

    function testFuzzPriceIsBoundedAndMatchesIntegerReference(
        uint96 rawStarting,
        uint96 rawSpread,
        uint16 rawElapsed,
        uint8 rawCurve
    ) public {
        uint256 spread = bound(rawSpread, 1, 1e24);
        uint256 reservePrice = bound(rawStarting, 1, 1e24);
        uint256 startingPrice = reservePrice + spread;
        uint256 elapsed = bound(rawElapsed, 0, 1_200);
        DutchAuction.Curve curve = DutchAuction.Curve(uint8(rawCurve % 3));
        DutchAuction auction = _deploy(1, startingPrice, reservePrice, curve, 64);

        uint256 price = auction.priceAtElapsed(elapsed);
        assertEq(price, _referencePrice(curve, startingPrice, reservePrice, elapsed));
        assertLe(price, startingPrice);
        assertGe(price, reservePrice);
    }

    function testScheduledAuctionStartsAndCancellationBurnsSupply() public {
        AuctionFactory factory;
        vm.prank(admin);
        factory = new AuctionFactory();

        uint64 scheduled = uint64(block.timestamp + 60);
        AuctionFactory.AuctionInput memory input = AuctionFactory.AuctionInput({
            tokenName: "Scheduled Token",
            tokenSymbol: "SCH",
            wholeTokenSupply: 5,
            startingPriceWeiPerToken: START_PRICE,
            reservePriceWeiPerToken: RESERVE_PRICE,
            curve: DutchAuction.Curve.Linear,
            scheduledStartTime: scheduled
        });
        vm.prank(admin);
        DutchAuction auction = DutchAuction(factory.createAuction(input));
        AuctionToken token = auction.token();

        assertEq(auction.commitmentCap(), 64);
        assertEq(uint256(auction.status()), uint256(DutchAuction.Status.Scheduled));
        assertEq(token.balanceOf(address(auction)), 5 * U);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.cancelAuction(address(auction));

        vm.prank(admin);
        factory.cancelAuction(address(auction));
        assertEq(uint256(auction.status()), uint256(DutchAuction.Status.Cancelled));
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(address(auction)), 0);
    }

    function testFactoryOwnerCannotTransferOrRenounce() public {
        vm.prank(admin);
        AuctionFactory factory = new AuctionFactory();

        vm.prank(admin);
        vm.expectRevert(AuctionFactory.OwnershipIsFixed.selector);
        factory.transferOwnership(alice);

        vm.prank(admin);
        vm.expectRevert(AuctionFactory.OwnershipIsFixed.selector);
        factory.renounceOwnership();
        assertEq(factory.owner(), admin);
    }

    function testBidsBeforeStartAreRejectedAndSettingsAreImmutable() public {
        DutchAuction.Config memory config = DutchAuction.Config({
            admin: admin,
            startTime: uint64(block.timestamp + 60),
            commitmentCap: 64,
            startingPriceWeiPerToken: START_PRICE,
            reservePriceWeiPerToken: RESERVE_PRICE,
            wholeTokenSupply: 2,
            curve: DutchAuction.Curve.Linear,
            tokenName: "Future",
            tokenSymbol: "FUT"
        });
        DutchAuction auction = new DutchAuction(config);
        vm.prank(alice);
        vm.expectRevert(DutchAuction.AuctionNotOpen.selector);
        auction.bid{value: 1 ether}();

        vm.warp(config.startTime);
        vm.prank(alice);
        auction.bid{value: 1 ether}();
        assertEq(auction.startingPriceWeiPerToken(), START_PRICE);
        assertEq(auction.reservePriceWeiPerToken(), RESERVE_PRICE);
    }

    function testThresholdCrossingAcceptsOnlyNeededEthAndClaimPaysTokenAndRefund() public {
        DutchAuction auction = _deploy(1, 10, 5, DutchAuction.Curve.Linear, 64);

        vm.prank(alice);
        auction.bid{value: 6}();
        vm.prank(bob);
        auction.bid{value: 10}();

        assertTrue(auction.isLogicallyClosed());
        assertEq(auction.totalAcceptedEth(), 10);
        assertEq(auction.totalEthReceived(), 16);
        auction.finalize();

        assertEq(auction.finalPriceWeiPerToken(), 10);
        assertEq(auction.finalTimestamp(), block.timestamp);
        assertEq(auction.tokenEntitlement(alice), 6 * U / 10);
        assertEq(auction.tokenEntitlement(bob), 4 * U / 10);
        assertEq(auction.refundEntitlement(bob), 6);
        assertEq(auction.totalSaleProceeds(), 10);

        uint256 bobBalanceBefore = bob.balance;
        vm.prank(bob);
        auction.claim();
        assertEq(bob.balance - bobBalanceBefore, 6);
        assertEq(auction.token().balanceOf(bob), 4 * U / 10);
        assertTrue(auction.tokensClaimed(bob));
        assertTrue(auction.refundClaimed(bob));
        assertEq(auction.totalRefundLiability(), 0);

        vm.prank(alice);
        auction.claim();
        assertEq(auction.token().balanceOf(alice), 6 * U / 10);
        assertEq(auction.token().totalSupply(), U);
    }

    function testDecayTriggeredCloseUsesEarliestSecondAndTrimsNewestCommitment() public {
        DutchAuction auction = _deploy(2, 10, 5, DutchAuction.Curve.Linear, 64);

        vm.prank(alice);
        auction.bid{value: 10}();
        vm.prank(bob);
        auction.bid{value: 9}();

        assertEq(auction.logicalClosingTime(), uint256(start) + 240);
        assertEq(auction.logicalClosingPrice(), 9);
        vm.warp(uint256(start) + 239);
        assertFalse(auction.isLogicallyClosed());
        vm.warp(uint256(start) + 240);
        assertTrue(auction.isLogicallyClosed());
        vm.deal(address(0xC), 1);
        vm.prank(address(0xC));
        vm.expectRevert(DutchAuction.AuctionClosed.selector);
        auction.bid{value: 1}();

        auction.finalize();
        assertEq(auction.acceptedWeiByBidder(alice), 10);
        assertEq(auction.acceptedWeiByBidder(bob), 8);
        assertEq(auction.refundEntitlement(bob), 1);
        assertEq(auction.finalTimestamp(), uint256(start) + 240);
        assertEq(auction.totalAcceptedEth(), 19);
        assertEq(auction.totalSaleProceeds() + auction.totalRefundLiability(), 19);

        vm.prank(alice);
        auction.claim();
        vm.prank(bob);
        auction.claim();
        assertEq(auction.token().balanceOf(alice) + auction.token().balanceOf(bob), 2 * U - 1);
        assertEq(auction.token().totalSupply(), 2 * U - 1);
    }

    function testRepeatedCommitmentsKeepEachTransactionInPriorityOrder() public {
        DutchAuction auction = _deploy(2, 10, 5, DutchAuction.Curve.Linear, 64);

        vm.prank(alice);
        auction.bid{value: 10}();
        vm.prank(alice);
        auction.bid{value: 9}();
        assertEq(auction.commitmentCount(), 2);
        (address firstBidder, uint256 firstAmount) = auction.commitmentAt(0);
        (address secondBidder, uint256 secondAmount) = auction.commitmentAt(1);
        assertEq(firstBidder, alice);
        assertEq(secondBidder, alice);
        assertEq(firstAmount, 10);
        assertEq(secondAmount, 9);

        vm.warp(uint256(start) + 240);
        auction.finalize();
        assertEq(auction.acceptedWeiByBidder(alice), 18);
        assertEq(auction.refundEntitlement(alice), 1);
    }

    function testExpiryBurnsUnsoldTokensAndFullyRefundsZeroUnitBid() public {
        DutchAuction auction = _deploy(1, 4 ether, 2 ether, DutchAuction.Curve.Linear, 64);
        uint256 aliceBalanceBefore = alice.balance;
        vm.prank(alice);
        auction.bid{value: 1}();

        vm.warp(uint256(start) + 1_200);
        assertEq(auction.logicalClosingPrice(), 2 ether);
        auction.finalize();
        assertFalse(auction.soldOut());
        assertEq(auction.tokenEntitlement(alice), 0);
        assertEq(auction.refundEntitlement(alice), 1);
        assertEq(auction.totalBurnedTokens(), U);
        assertEq(auction.token().totalSupply(), 0);

        vm.prank(alice);
        vm.expectRevert(DutchAuction.NoEntitlement.selector);
        auction.claimTokens();
        vm.prank(alice);
        auction.withdrawRefund(payable(alice));
        assertEq(alice.balance, aliceBalanceBefore);
    }

    function testZeroUnitAllocationRefundsEverythingAtSettlementPrice() public {
        DutchAuction auction = _deploy(1, 4 ether, 2 ether, DutchAuction.Curve.Linear, 64);
        vm.prank(alice);
        auction.bid{value: 1}();
        vm.warp(uint256(start) + 1_200);
        auction.finalize();

        assertEq(auction.tokenEntitlement(alice), 0);
        assertEq(auction.refundEntitlement(alice), 1);
        assertEq(auction.totalSaleProceeds(), 0);
        assertEq(auction.token().totalSupply(), 0);
    }

    function testRevertingRefundReceiverCanClaimTokensAndRedirectRefund() public {
        DutchAuction auction = _deploy(1, 10, 5, DutchAuction.Curve.Linear, 64);
        RejectingReceiver receiver = new RejectingReceiver(auction);
        vm.deal(address(this), 11);
        vm.deal(address(receiver), 0);

        receiver.bid{value: 11}();
        auction.finalize();
        vm.expectRevert(DutchAuction.TransferFailed.selector);
        receiver.claim();
        assertFalse(auction.tokensClaimed(address(receiver)));
        assertFalse(auction.refundClaimed(address(receiver)));

        receiver.claimTokens();
        assertEq(auction.token().balanceOf(address(receiver)), U);
        vm.prank(address(receiver));
        auction.withdrawRefund(payable(alice));
        assertEq(alice.balance, 1_000 ether + 1);
    }

    function testReentrantRefundReceiverCannotClaimTwice() public {
        DutchAuction auction = _deploy(1, 10 ether, 5 ether, DutchAuction.Curve.Linear, 64);
        ReenteringReceiver attacker = new ReenteringReceiver(auction);
        vm.deal(address(this), 12 ether);
        vm.deal(address(attacker), 0);
        attacker.bid{value: 12 ether}();
        auction.finalize();

        attacker.claim();
        assertTrue(attacker.attemptedReentry());
        assertFalse(attacker.reentrySucceeded());
        assertEq(auction.token().balanceOf(address(attacker)), U);
        assertEq(address(attacker).balance, 2 ether);
        assertEq(auction.totalRefundLiability(), 0);
        assertTrue(auction.tokensClaimed(address(attacker)));
        assertTrue(auction.refundClaimed(address(attacker)));
    }

    function testPermissionlessIdempotentFinalizeAndClaimTriggeredFinalize() public {
        DutchAuction auction = _deploy(1, 10 ether, 5 ether, DutchAuction.Curve.Linear, 64);
        vm.prank(alice);
        auction.bid{value: 10 ether}();
        assertTrue(auction.isLogicallyClosed());

        vm.prank(alice);
        auction.claim();
        assertTrue(auction.finalized());
        auction.finalize();
        assertEq(auction.token().balanceOf(alice), U);
    }

    function testCapacityRejectsNewBidsButExistingBidsCanExpire() public {
        DutchAuction auction = _deploy(100, 10 ether, 5 ether, DutchAuction.Curve.Linear, 2);
        vm.prank(alice);
        auction.bid{value: 1 wei}();
        vm.prank(bob);
        auction.bid{value: 1 wei}();

        assertEq(uint256(auction.status()), uint256(DutchAuction.Status.CapacityReached));
        vm.prank(admin);
        vm.expectRevert(DutchAuction.CommitmentCapReached.selector);
        auction.bid{value: 1 wei}();

        vm.warp(uint256(start) + 1_200);
        auction.finalize();
        assertTrue(auction.finalized());
        assertEq(auction.refundEntitlement(alice), 1);
        assertEq(auction.refundEntitlement(bob), 1);
    }

    function testAdminWithdrawalKeepsAllOutstandingRefundsReserved() public {
        DutchAuction auction = _deploy(1, 10, 5, DutchAuction.Curve.Linear, 64);
        vm.prank(alice);
        auction.bid{value: 6}();
        vm.prank(bob);
        auction.bid{value: 10}();
        auction.finalize();

        uint256 adminBefore = admin.balance;
        vm.prank(admin);
        auction.withdrawProceeds();
        assertEq(admin.balance - adminBefore, 10);
        assertEq(address(auction).balance, 6);
        assertEq(auction.totalRefundLiability(), 6);

        vm.prank(admin);
        vm.expectRevert(DutchAuction.NoEntitlement.selector);
        auction.withdrawProceeds();

        vm.prank(bob);
        auction.withdrawRefund(payable(bob));
        assertEq(address(auction).balance, 0);
    }

    function testFuzzSettlementConservesEthAndTokenSupply(
        uint32 rawStartingPrice,
        uint32 rawReservePrice,
        uint16 rawSupply,
        uint96 rawBid
    ) public {
        uint256 reservePrice = bound(rawReservePrice, 2, 1e12);
        uint256 startingPrice = reservePrice + bound(rawStartingPrice, 1, 1e12);
        uint256 supply = bound(rawSupply, 1, 20);
        uint256 amount = bound(rawBid, 1, supply * startingPrice * 2);
        DutchAuction auction = _deploy(supply, startingPrice, reservePrice, DutchAuction.Curve.QuadraticFastInitial, 8);
        vm.deal(alice, amount + 1);
        vm.prank(alice);
        auction.bid{value: amount}();
        vm.warp(uint256(start) + 1_200);
        auction.finalize();

        assertEq(auction.totalSaleProceeds() + auction.totalRefundLiability(), amount);
        assertEq(address(auction).balance, auction.totalSaleProceeds() + auction.totalRefundLiability());
        assertEq(auction.totalAllocatedTokens() + auction.totalBurnedTokens(), supply * U);
        assertEq(auction.token().balanceOf(address(auction)), auction.totalAllocatedTokens());
        assertLe(auction.totalAllocatedTokens(), supply * U);
        assertEq(auction.totalRefundLiability(), auction.refundEntitlement(alice));

        if (auction.tokenEntitlement(alice) != 0 || auction.refundEntitlement(alice) != 0) {
            vm.prank(alice);
            auction.claim();
        }
        assertEq(auction.totalRefundLiability(), 0);
        assertEq(address(auction).balance, auction.totalSaleProceeds());
    }

    function testFuzzMultiWalletSettlementPreservesWeiAndTokenInvariants(
        uint32 rawStartingPrice,
        uint32 rawReservePrice,
        uint16 rawSupply,
        uint64 rawAliceBid,
        uint64 rawBobBid,
        uint64 rawAdminBid
    ) public {
        uint256 reservePrice = bound(rawReservePrice, 2, 1e12);
        uint256 startingPrice = reservePrice + bound(rawStartingPrice, 1, 1e12);
        uint256 supply = bound(rawSupply, 1, 20);
        uint256 startingCost = supply * startingPrice;
        uint256 perBidMax = startingCost / 3;
        uint256[3] memory bids =
            [bound(rawAliceBid, 1, perBidMax), bound(rawBobBid, 1, perBidMax), bound(rawAdminBid, 1, perBidMax)];
        _exerciseMultiWalletSettlement(supply, startingPrice, reservePrice, bids, uint8(rawAliceBid % 3));
    }

    function _exerciseMultiWalletSettlement(
        uint256 supply,
        uint256 startingPrice,
        uint256 reservePrice,
        uint256[3] memory bids,
        uint8 curveIndex
    ) private {
        DutchAuction auction = _deploy(supply, startingPrice, reservePrice, DutchAuction.Curve(curveIndex), 4);

        address[3] memory bidders = [alice, bob, admin];
        for (uint256 i; i < bidders.length; ++i) {
            vm.deal(bidders[i], bids[i]);
            vm.prank(bidders[i]);
            auction.bid{value: bids[i]}();
        }

        vm.warp(uint256(start) + 1_200);
        auction.finalize();
        uint256 totalSent = bids[0] + bids[1] + bids[2];
        assertEq(auction.totalEthReceived(), totalSent);
        assertEq(auction.totalSaleProceeds() + auction.totalRefundLiability(), totalSent);
        assertEq(address(auction).balance, auction.totalSaleProceeds() + auction.totalRefundLiability());
        assertEq(auction.totalAllocatedTokens() + auction.totalBurnedTokens(), supply * U);
        assertLe(auction.totalAllocatedTokens(), supply * U);
        assertEq(auction.token().balanceOf(address(auction)), auction.totalAllocatedTokens());

        for (uint256 i; i < bidders.length; ++i) {
            address bidder = bidders[i];
            if (auction.tokenEntitlement(bidder) != 0 || auction.refundEntitlement(bidder) != 0) {
                vm.prank(bidder);
                auction.claim();
            }
        }

        assertEq(auction.totalRefundLiability(), 0);
        assertEq(address(auction).balance, auction.totalSaleProceeds());
    }

    function testOnlyOriginalBidderCanRedirectRefundAndRefundCannotRepeat() public {
        DutchAuction auction = _deploy(1, 10, 5, DutchAuction.Curve.Linear, 64);
        vm.prank(alice);
        auction.bid{value: 6}();
        vm.prank(bob);
        auction.bid{value: 10}();
        auction.finalize();

        vm.prank(admin);
        vm.expectRevert(DutchAuction.NoEntitlement.selector);
        auction.withdrawRefund(payable(admin));

        vm.prank(bob);
        auction.withdrawRefund(payable(address(0xCAFE)));
        assertEq(address(0xCAFE).balance, 6);
        assertEq(auction.totalRefundLiability(), 0);

        vm.prank(bob);
        vm.expectRevert(DutchAuction.NoEntitlement.selector);
        auction.withdrawRefund(payable(bob));
    }

    function testCancellationAtTheStartTimestampIsRejected() public {
        DutchAuction auction = _deploy(1, START_PRICE, RESERVE_PRICE, DutchAuction.Curve.Linear, 64);
        vm.warp(start);
        vm.prank(admin);
        vm.expectRevert(DutchAuction.NotCancellable.selector);
        auction.cancel();
    }
}
