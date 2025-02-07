// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IHook} from "../interfaces/IHook.sol";

/// @notice Minimal Chainlink AggregatorV3 interface
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function decimals() external view returns (uint8);
}

/// @title OracleHook
/// @notice Hook that gates escrow actions based on oracle price feeds
/// @dev Use Chainlink price feeds to enforce minimum/maximum price conditions
contract OracleHook is IHook {
    // ============================================
    // ENUMS
    // ============================================

    enum Condition {
        None,
        MinPrice,
        MaxPrice,
        PriceRange
    }

    // ============================================
    // ERRORS
    // ============================================

    error PriceTooLow(int256 current, int256 required);
    error PriceTooHigh(int256 current, int256 required);
    error PriceOutOfRange(int256 current, int256 min, int256 max);
    error StalePrice(uint256 updatedAt, uint256 maxAge);
    error InvalidPrice(int256 price);
    error NotOwner();
    error ZeroAddress();

    // ============================================
    // EVENTS
    // ============================================

    event PriceChecked(
        int256 price,
        uint256 timestamp,
        Condition condition,
        bool passed
    );
    event ConditionUpdated(
        Condition condition,
        int256 minPrice,
        int256 maxPrice
    );

    // ============================================
    // STATE VARIABLES
    // ============================================

    AggregatorV3Interface public immutable priceFeed;
    address public owner;
    uint8 public immutable feedDecimals;

    // Price conditions
    Condition public fundCondition;
    Condition public releaseCondition;
    Condition public refundCondition;

    int256 public fundMinPrice;
    int256 public fundMaxPrice;
    int256 public releaseMinPrice;
    int256 public releaseMaxPrice;
    int256 public refundMinPrice;
    int256 public refundMaxPrice;

    // Staleness check
    uint256 public maxPriceAge; // Maximum age of price data in seconds

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /// @notice Initialize oracle hook
    /// @param _priceFeed Chainlink price feed address
    /// @param _owner Owner address
    /// @param _maxPriceAge Maximum age of price data (0 = no check)
    constructor(
        address _priceFeed,
        address _owner,
        uint256 _maxPriceAge
    ) {
        if (_priceFeed == address(0) || _owner == address(0)) revert ZeroAddress();

        priceFeed = AggregatorV3Interface(_priceFeed);
        owner = _owner;
        maxPriceAge = _maxPriceAge;
        feedDecimals = priceFeed.decimals();

        // Default: no conditions
        fundCondition = Condition.None;
        releaseCondition = Condition.None;
        refundCondition = Condition.None;
    }

    // ============================================
    // CONFIGURATION FUNCTIONS
    // ============================================

    /// @notice Set minimum price for release
    /// @param minPrice Minimum price required (in feed decimals)
    function setReleaseMinPrice(int256 minPrice) external onlyOwner {
        releaseCondition = Condition.MinPrice;
        releaseMinPrice = minPrice;
        emit ConditionUpdated(releaseCondition, minPrice, 0);
    }

    /// @notice Set maximum price for release
    /// @param maxPrice Maximum price allowed (in feed decimals)
    function setReleaseMaxPrice(int256 maxPrice) external onlyOwner {
        releaseCondition = Condition.MaxPrice;
        releaseMaxPrice = maxPrice;
        emit ConditionUpdated(releaseCondition, 0, maxPrice);
    }

    /// @notice Set price range for release
    /// @param minPrice Minimum price
    /// @param maxPrice Maximum price
    function setReleasePriceRange(int256 minPrice, int256 maxPrice) external onlyOwner {
        releaseCondition = Condition.PriceRange;
        releaseMinPrice = minPrice;
        releaseMaxPrice = maxPrice;
        emit ConditionUpdated(releaseCondition, minPrice, maxPrice);
    }

    /// @notice Clear release condition
    function clearReleaseCondition() external onlyOwner {
        releaseCondition = Condition.None;
        emit ConditionUpdated(Condition.None, 0, 0);
    }

    /// @notice Update max price age
    /// @param _maxPriceAge New maximum age in seconds
    function setMaxPriceAge(uint256 _maxPriceAge) external onlyOwner {
        maxPriceAge = _maxPriceAge;
    }

    // ============================================
    // HOOK FUNCTIONS
    // ============================================

    function beforeFund(address /*from*/, uint256 /*amount*/) external view override {
        if (fundCondition == Condition.None) return;
        _checkPrice(fundCondition, fundMinPrice, fundMaxPrice);
    }

    function beforeRelease(address /*to*/) external view override {
        if (releaseCondition == Condition.None) return;
        _checkPrice(releaseCondition, releaseMinPrice, releaseMaxPrice);
    }

    function beforeRefund(address /*to*/) external view override {
        if (refundCondition == Condition.None) return;
        _checkPrice(refundCondition, refundMinPrice, refundMaxPrice);
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    function _checkPrice(
        Condition condition,
        int256 minPrice,
        int256 maxPrice
    ) internal view {
        (int256 price, uint256 updatedAt) = _getLatestPrice();

        // Check staleness
        if (maxPriceAge > 0) {
            if (block.timestamp - updatedAt > maxPriceAge) {
                revert StalePrice(updatedAt, maxPriceAge);
            }
        }

        // Check price validity
        if (price <= 0) revert InvalidPrice(price);

        // Check condition
        bool passed = false;

        if (condition == Condition.MinPrice) {
            if (price < minPrice) revert PriceTooLow(price, minPrice);
            passed = true;
        } else if (condition == Condition.MaxPrice) {
            if (price > maxPrice) revert PriceTooHigh(price, maxPrice);
            passed = true;
        } else if (condition == Condition.PriceRange) {
            if (price < minPrice || price > maxPrice) {
                revert PriceOutOfRange(price, minPrice, maxPrice);
            }
            passed = true;
        }

        emit PriceChecked(price, block.timestamp, condition, passed);
    }

    function _getLatestPrice() internal view returns (int256 price, uint256 updatedAt) {
        (
            /*uint80 roundId*/,
            int256 answer,
            /*uint256 startedAt*/,
            uint256 _updatedAt,
            /*uint80 answeredInRound*/
        ) = priceFeed.latestRoundData();

        return (answer, _updatedAt);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /// @notice Get current price from oracle
    function getCurrentPrice() external view returns (int256 price, uint256 updatedAt) {
        return _getLatestPrice();
    }

    /// @notice Check if current price meets release condition
    function canReleaseAtCurrentPrice() external view returns (bool) {
        if (releaseCondition == Condition.None) return true;

        try this.beforeRelease(address(0)) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice Transfer ownership
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }
}
