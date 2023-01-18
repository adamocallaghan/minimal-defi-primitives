// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Lending {

    // ########################################
    // ###            variables             ###
    // ########################################

    mapping(address => address) public s_tokenToPriceFeed;
    address[] public s_allowedTokens;

    mapping(address => mapping(address => uint256)) public s_accountToTokenDeposits; // Account -> Token -> Amount
    mapping(address => mapping(address => uint256)) public s_accountToTokenBorrows; // Account -> Token -> Amount

    uint256 public constant LIQUIDATION_REWARD = 5; // 5% Liquidation Reward
    uint256 public constant LIQUIDATION_THRESHOLD = 80; // At 80% Loan to Value Ratio, the loan can be liquidated
    uint256 public constant MIN_HEALH_FACTOR = 1e18;

    // ########################################
    // ###             functions            ###
    // ########################################

    // ===== DEPOSIT (external) =====
    function deposit(address token, uint256 amount) external {
        s_accountToTokenDeposits[msg.sender][token] += amount;
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }

    // ===== WITHDRAW (external) =====
    function withdraw(address token, uint256 amount) external {
        _pullFunds(msg.sender, token, amount);
    }

    // *****  _PULLFUNDS (private) *****
    function _pullFunds(address account, address token, uint256 amount) private {
        s_accountToTokenDeposits[account][token] -= amount;
        IERC20(token).transfer(msg.sender, amount);
    }

    // ===== BORROW (external) =====
    function borrow(address token, uint256 amount) external {
        s_accountToTokenBorrows[msg.sender][token] += amount;
        IERC20(token).transfer(msg.sender, amount);
    }

    // ===== LIQUIDATE (external) =====
    function liquidate(address account, address repayToken, address rewardToken) external {
        require(healthFactor(account) < MIN_HEALH_FACTOR, "Account can't be liquidated!");
        uint256 halfDebt = s_accountToTokenBorrows[account][repayToken] / 2; // gets half value of the tokens the borrower has borrowed
        uint256 halfDebtInEth = getEthValue(repayToken, halfDebt); // converts the half value of the debt to ETH
        require(halfDebtInEth > 0, "Choose a different repayToken!");
        uint256 rewardAmountInEth = (halfDebtInEth * LIQUIDATION_REWARD) / 100;
        uint256 totalRewardAmountInRewardToken = getTokenValueFromEth(
            rewardToken,
            rewardAmountInEth + halfDebtInEth
        );
        _repay(account, repayToken, halfDebt);
        _pullFunds(account, rewardToken, totalRewardAmountInRewardToken);
    }

    // ===== REPAY (external) =====
    function repay(address token, uint256 amount) external {
        _repay(msg.sender, token, amount);
    }

    // ***** _REPAY (private) *****
    function _repay(address account, address token, uint256 amount) private {
        s_accountToTokenBorrows[account][token] -= amount;
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }

    // ########################################
    // ###          view functions          ###
    // ########################################

    function getAccountInformation(address user) public view returns (uint256 borrowedValueInETH, uint256 collateralValueInETH) {
        borrowedValueInETH = getAccountBorrowedValue(user);
        collateralValueInETH = getAccountCollateralValue(user);
    }

    function getAccountCollateralValue(address user) public view returns (uint256) {
        uint256 totalCollateralValueInETH = 0;
        for (uint256 index = 0; index < s_allowedTokens.length; index++) {
            address token = s_allowedTokens[index];
            uint256 amount = s_accountToTokenDeposits[user][token];
            uint256 valueInEth = getEthValue(token, amount);
            totalCollateralValueInETH += valueInEth;
        }
        return totalCollateralValueInETH;
    }

    function getAccountBorrowedValue(address user) public view returns (uint256) {
        uint256 totalBorrowsValueInETH = 0;
        for (uint256 index = 0; index < s_allowedTokens.length; index++) {
            address token = s_allowedTokens[index];
            uint256 amount = s_accountToTokenBorrows[user][token];
            uint256 valueInEth = getEthValue(token, amount);
            totalBorrowsValueInETH += valueInEth;
        }
        return totalBorrowsValueInETH;
    }

    function getEthValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeed[token]);
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return (uint256(price) * amount) / 1e18;
    }

    function getTokenValueFromEth(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeed[token]);
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return (amount * 1e18) / uint256(price);
    }

    function healthFactor(address account) public view returns (uint256) {
        (uint256 borrowedValueInEth, uint256 collateralValueInEth) = getAccountInformation(account);
        uint256 collateralAdjustedForThreshold = (collateralValueInEth * LIQUIDATION_THRESHOLD) /
            100;
        if (borrowedValueInEth == 0) return 100e18;
        return (collateralAdjustedForThreshold * 1e18) / borrowedValueInEth;
    }
}