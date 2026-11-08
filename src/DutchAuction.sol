// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AuctionToken} from "./AuctionToken.sol";

/// @notice A fixed-supply, descending-price ETH auction with pull claims.
contract DutchAuction is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant DURATION = 1_200;
    uint256 public constant TOKEN_UNIT = 1e18;
    uint256 private constant CURVE_DENOMINATOR = DURATION * DURATION;

    enum Curve {
        Linear,
        QuadraticSlowInitial,
        QuadraticFastInitial
    }

    enum Status {
        Scheduled,
        Open,
        CapacityReached,
        Closed,
        Finalized,
        Cancelled
    }

    struct Commitment {
        address bidder;
        uint256 acceptedWei;
    }

    struct Config {
        address admin;
        uint64 startTime;
        uint32 commitmentCap;
        uint256 startingPriceWeiPerToken;
        uint256 reservePriceWeiPerToken;
        uint256 wholeTokenSupply;
        Curve curve;
        string tokenName;
        string tokenSymbol;
    }

    error OnlyAdmin();
    error InvalidConfiguration();
    error InvalidStartTime();
    error NotCancellable();
    error AuctionNotOpen();
    error AuctionClosed();
    error CommitmentCapReached();
    error ZeroBid();
    error NoEntitlement();
    error RefundRecipientIsZero();
    error TransferFailed();

    event BidCommitted(
        address indexed bidder,
        uint256 indexed commitmentIndex,
        uint256 acceptedWei,
        uint256 excessWei,
        uint256 timestamp
    );
    event AuctionClosedEarly(uint256 timestamp, uint256 priceWeiPerToken);
    event AuctionFinalized(
        uint256 timestamp,
        uint256 priceWeiPerToken,
        bool soldOut,
        uint256 allocatedTokens,
        uint256 burnedTokens,
        uint256 refundLiability
    );
    event AuctionCancelled();
    event Claimed(address indexed bidder, uint256 tokenAmount, uint256 refundWei);
    event RefundWithdrawn(address indexed bidder, address indexed recipient, uint256 amountWei);
    event ProceedsWithdrawn(address indexed admin, uint256 amountWei);

    address public immutable admin;
    address public immutable factory;
    uint64 public immutable startTime;
    uint32 public immutable commitmentCap;
    uint256 public immutable startingPriceWeiPerToken;
    uint256 public immutable reservePriceWeiPerToken;
    uint256 public immutable tokenSupply;
    uint256 public immutable wholeTokenSupply;
    Curve public immutable curve;
    AuctionToken public immutable token;

    uint64 private _projectedCloseTime;
    uint256 private _closingPrice;
    bool private _immediateSellout;
    bool public finalized;
    bool public cancelled;
    bool public soldOut;

    uint256 public totalEthReceived;
    uint256 public totalAcceptedEth;
    uint256 public totalRefundLiability;
    uint256 public totalSaleProceeds;
    uint256 public proceedsWithdrawn;
    uint256 public totalAllocatedTokens;
    uint256 public totalBurnedTokens;
    uint256 public finalPriceWeiPerToken;
    uint256 public finalTimestamp;

    Commitment[] private _commitments;
    address[] private _bidders;
    mapping(address bidder => bool seen) private _hasBidder;
    mapping(address bidder => uint256 amount) public grossAcceptedWei;
    mapping(address bidder => uint256 amount) public immediateExcessRefundWei;
    mapping(address bidder => uint256 amount) public acceptedWeiByBidder;
    mapping(address bidder => uint256 amount) public tokenEntitlement;
    mapping(address bidder => uint256 amount) public refundEntitlement;
    mapping(address bidder => bool claimed) public tokensClaimed;
    mapping(address bidder => bool claimed) public refundClaimed;

    constructor(Config memory config) {
        if (
            config.admin == address(0) || config.commitmentCap == 0
                || config.startingPriceWeiPerToken <= config.reservePriceWeiPerToken
                || config.reservePriceWeiPerToken == 0 || config.wholeTokenSupply == 0
                || uint8(config.curve) > uint8(Curve.QuadraticFastInitial)
                || config.wholeTokenSupply > type(uint256).max / TOKEN_UNIT
                || config.wholeTokenSupply > type(uint256).max / config.startingPriceWeiPerToken
        ) revert InvalidConfiguration();
        if (config.startTime < block.timestamp || uint256(config.startTime) > type(uint64).max - DURATION) {
            revert InvalidStartTime();
        }

        admin = config.admin;
        factory = msg.sender;
        startTime = config.startTime;
        commitmentCap = config.commitmentCap;
        startingPriceWeiPerToken = config.startingPriceWeiPerToken;
        reservePriceWeiPerToken = config.reservePriceWeiPerToken;
        tokenSupply = config.wholeTokenSupply * TOKEN_UNIT;
        wholeTokenSupply = config.wholeTokenSupply;
        curve = config.curve;

        token = new AuctionToken(config.tokenName, config.tokenSymbol, tokenSupply, address(this));
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    function commitmentCount() external view returns (uint256) {
        return _commitments.length;
    }

    function bidderCount() external view returns (uint256) {
        return _bidders.length;
    }

    function commitmentAt(uint256 index) external view returns (address bidder, uint256 acceptedWei) {
        Commitment storage item = _commitments[index];
        return (item.bidder, item.acceptedWei);
    }

    function bidderAt(uint256 index) external view returns (address) {
        return _bidders[index];
    }

    function endTime() public view returns (uint256) {
        return uint256(startTime) + DURATION;
    }

    function status() public view returns (Status) {
        if (cancelled) return Status.Cancelled;
        if (finalized) return Status.Finalized;
        if (block.timestamp < startTime) return Status.Scheduled;
        if (isLogicallyClosed()) return Status.Closed;
        if (_commitments.length >= commitmentCap) return Status.CapacityReached;
        return Status.Open;
    }

    function isLogicallyClosed() public view returns (bool) {
        if (cancelled || finalized) return true;
        if (block.timestamp < startTime) return false;
        if (_projectedCloseTime != 0 && block.timestamp >= _projectedCloseTime) return true;
        return block.timestamp >= endTime();
    }

    function logicalClosingTime() public view returns (uint256) {
        if (_projectedCloseTime != 0) return _projectedCloseTime;
        return endTime();
    }

    function logicalClosingPrice() public view returns (uint256) {
        if (_immediateSellout) return _closingPrice;
        uint256 closeAt = logicalClosingTime();
        uint256 elapsed = closeAt <= startTime ? 0 : closeAt - startTime;
        if (elapsed > DURATION) elapsed = DURATION;
        return priceAtElapsed(elapsed);
    }

    function currentPrice() external view returns (uint256) {
        uint256 timestamp = block.timestamp;
        if (_projectedCloseTime != 0 && timestamp >= _projectedCloseTime) {
            timestamp = _projectedCloseTime;
        }
        if (timestamp > endTime()) timestamp = endTime();
        if (timestamp < startTime) return startingPriceWeiPerToken;
        return priceAtElapsed(timestamp - startTime);
    }

    function priceAtElapsed(uint256 elapsed) public view returns (uint256) {
        if (elapsed == 0) return startingPriceWeiPerToken;
        if (elapsed >= DURATION) return reservePriceWeiPerToken;

        uint256 remaining = DURATION - elapsed;
        uint256 premium;
        if (curve == Curve.Linear) {
            premium = Math.mulDiv(
                startingPriceWeiPerToken - reservePriceWeiPerToken, remaining, DURATION, Math.Rounding.Ceil
            );
        } else if (curve == Curve.QuadraticSlowInitial) {
            uint256 weight = DURATION * DURATION - elapsed * elapsed;
            premium = Math.mulDiv(
                startingPriceWeiPerToken - reservePriceWeiPerToken, weight, CURVE_DENOMINATOR, Math.Rounding.Ceil
            );
        } else {
            premium = Math.mulDiv(
                startingPriceWeiPerToken - reservePriceWeiPerToken,
                remaining * remaining,
                CURVE_DENOMINATOR,
                Math.Rounding.Ceil
            );
        }
        return reservePriceWeiPerToken + premium;
    }

    function bid() external payable nonReentrant {
        if (cancelled || finalized) revert AuctionClosed();
        if (block.timestamp < startTime) revert AuctionNotOpen();
        if (block.timestamp >= endTime() || (_projectedCloseTime != 0 && block.timestamp >= _projectedCloseTime)) {
            revert AuctionClosed();
        }
        if (_commitments.length >= commitmentCap) revert CommitmentCapReached();
        if (msg.value == 0) revert ZeroBid();

        uint256 price = priceAtElapsed(block.timestamp - startTime);
        uint256 totalCost = wholeTokenSupply * price;
        uint256 neededWei = totalCost - totalAcceptedEth;
        uint256 acceptedWei = msg.value < neededWei ? msg.value : neededWei;
        uint256 excessWei = msg.value - acceptedWei;

        _commitments.push(Commitment(msg.sender, acceptedWei));
        if (!_hasBidder[msg.sender]) {
            _hasBidder[msg.sender] = true;
            _bidders.push(msg.sender);
        }
        grossAcceptedWei[msg.sender] += acceptedWei;
        totalAcceptedEth += acceptedWei;
        totalEthReceived += msg.value;
        if (excessWei != 0) immediateExcessRefundWei[msg.sender] += excessWei;

        emit BidCommitted(msg.sender, _commitments.length - 1, acceptedWei, excessWei, block.timestamp);

        if (totalAcceptedEth >= totalCost) {
            // forge-lint: disable-next-line(unsafe-typecast)
            _projectedCloseTime = uint64(block.timestamp);
            _closingPrice = price;
            _immediateSellout = true;
            emit AuctionClosedEarly(block.timestamp, price);
            return;
        }

        _updateProjectedClose(block.timestamp - startTime);
    }

    function finalize() external nonReentrant {
        _finalize();
    }

    function _finalizeIfClosed() private {
        if (!finalized && !cancelled && isLogicallyClosed()) _finalize();
    }

    function _finalize() private {
        if (finalized) return;
        if (cancelled || !isLogicallyClosed()) revert AuctionNotOpen();

        uint256 closeAt = logicalClosingTime();
        uint256 elapsed = closeAt <= startTime ? 0 : closeAt - startTime;
        if (elapsed > DURATION) elapsed = DURATION;
        uint256 price = _immediateSellout ? _closingPrice : priceAtElapsed(elapsed);
        uint256 requiredWei = wholeTokenSupply * price;
        soldOut = totalAcceptedEth >= requiredWei;
        if (soldOut) {
            uint256 surplusWei = totalAcceptedEth - requiredWei;
            for (uint256 i = _commitments.length; i > 0 && surplusWei > 0;) {
                unchecked {
                    --i;
                }
                Commitment storage item = _commitments[i];
                uint256 trimmedWei = item.acceptedWei < surplusWei ? item.acceptedWei : surplusWei;
                if (trimmedWei != 0) {
                    item.acceptedWei -= trimmedWei;
                    surplusWei -= trimmedWei;
                }
            }
            assert(surplusWei == 0);
        }

        for (uint256 i; i < _commitments.length; ++i) {
            Commitment storage item = _commitments[i];
            acceptedWeiByBidder[item.bidder] += item.acceptedWei;
        }

        uint256 allocatedTokens = 0;
        uint256 refunds = 0;
        for (uint256 i; i < _bidders.length; ++i) {
            address bidder = _bidders[i];
            uint256 budgetWei = acceptedWeiByBidder[bidder];
            uint256 allocated = Math.mulDiv(budgetWei, TOKEN_UNIT, price);
            uint256 chargedWei = Math.mulDiv(allocated, price, TOKEN_UNIT, Math.Rounding.Ceil);
            uint256 bidderRefund = grossAcceptedWei[bidder] - budgetWei + (budgetWei - chargedWei);
            bidderRefund += immediateExcessRefundWei[bidder];
            tokenEntitlement[bidder] = allocated;
            refundEntitlement[bidder] = bidderRefund;
            allocatedTokens += allocated;
            refunds += bidderRefund;
        }

        assert(allocatedTokens <= tokenSupply);
        totalAllocatedTokens = allocatedTokens;
        totalBurnedTokens = tokenSupply - allocatedTokens;
        totalRefundLiability = refunds;
        totalSaleProceeds = totalEthReceived - refunds;
        finalPriceWeiPerToken = price;
        finalTimestamp = closeAt;
        finalized = true;

        emit AuctionFinalized(closeAt, price, soldOut, allocatedTokens, totalBurnedTokens, refunds);
        if (totalBurnedTokens != 0) token.burnEscrow(totalBurnedTokens);
    }

    function cancel() external nonReentrant {
        if (msg.sender != admin && msg.sender != factory) revert OnlyAdmin();
        if (cancelled || finalized || block.timestamp >= startTime) revert NotCancellable();
        cancelled = true;
        totalBurnedTokens = tokenSupply;
        emit AuctionCancelled();
        token.burnEscrow(tokenSupply);
    }

    function claim() external nonReentrant {
        _finalizeIfClosed();
        uint256 tokenAmount = _takeTokenEntitlement(msg.sender);
        uint256 refundWei = _takeRefundEntitlement(msg.sender);
        if (tokenAmount == 0 && refundWei == 0) revert NoEntitlement();
        emit Claimed(msg.sender, tokenAmount, refundWei);
        if (tokenAmount != 0) IERC20(address(token)).safeTransfer(msg.sender, tokenAmount);
        if (refundWei != 0) _sendEth(payable(msg.sender), refundWei);
    }

    function claimTokens() external nonReentrant {
        _finalizeIfClosed();
        uint256 amount = _takeTokenEntitlement(msg.sender);
        if (amount == 0) revert NoEntitlement();
        emit Claimed(msg.sender, amount, 0);
        IERC20(address(token)).safeTransfer(msg.sender, amount);
    }

    function withdrawRefund(address payable recipient) external nonReentrant {
        _finalizeIfClosed();
        if (recipient == address(0)) revert RefundRecipientIsZero();
        uint256 amount = _takeRefundEntitlement(msg.sender);
        if (amount == 0) revert NoEntitlement();
        emit RefundWithdrawn(msg.sender, recipient, amount);
        _sendEth(recipient, amount);
    }

    function withdrawProceeds() external nonReentrant onlyAdmin {
        _finalizeIfClosed();
        if (!finalized) revert AuctionNotOpen();
        uint256 availableWei = totalSaleProceeds - proceedsWithdrawn;
        if (availableWei == 0) revert NoEntitlement();
        assert(address(this).balance >= totalRefundLiability + availableWei);
        proceedsWithdrawn += availableWei;
        emit ProceedsWithdrawn(admin, availableWei);
        _sendEth(payable(admin), availableWei);
    }

    function _takeTokenEntitlement(address bidder) private returns (uint256 amount) {
        if (tokensClaimed[bidder]) return 0;
        amount = tokenEntitlement[bidder];
        if (amount != 0) tokensClaimed[bidder] = true;
    }

    function _takeRefundEntitlement(address bidder) private returns (uint256 amount) {
        if (refundClaimed[bidder]) return 0;
        amount = refundEntitlement[bidder];
        if (amount != 0) {
            refundClaimed[bidder] = true;
            totalRefundLiability -= amount;
        }
    }

    function _sendEth(address payable recipient, uint256 amount) private {
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    function _updateProjectedClose(uint256 elapsed) private {
        uint256 reserveCost = wholeTokenSupply * reservePriceWeiPerToken;
        if (totalAcceptedEth < reserveCost) {
            _projectedCloseTime = 0;
            return;
        }

        uint256 low = elapsed;
        uint256 high = DURATION;
        while (low < high) {
            uint256 mid = low + (high - low) / 2;
            uint256 midCost = wholeTokenSupply * priceAtElapsed(mid);
            if (midCost <= totalAcceptedEth) high = mid;
            else low = mid + 1;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        _projectedCloseTime = uint64(uint256(startTime) + low);
    }
}
