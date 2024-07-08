// SPDX-License-Identifier: MIT

/**
 * Contract Elements should be laid out in the following order:
 *     Pragma statements
 *     Import statements
 *     Events
 *     Errors
 *     Interfaces
 *     Libraries
 *     Contracts
 *
 * Inside each contract, library or interface, use the following order:
 *     Type declarations
 *     State variables
 *     Events
 *     Errors
 *     Modifiers
 *     Functions
 *
 *
 * Layout of Functions:
 *     constructor
 *     receive function (if exists)
 *     fallback function (if exists)
 *     external
 *     public
 *     internal
 *     private
 */
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 *     @author 0xNascosta
 *
 *     The system is designed to be as minimial as possible and have the tokens maintain a 1 token == $1 peg.
 *
 *     This stable coin has the properties:
 *     - Exogenous Collateral
 *     - Dollar Pegged
 *     - Algorithmically Stable
 *
 *     It is similar to DAI if DAI had no governance, no fees and was only backed by WETH and WBTC.
 *
 *     Out DSC system should always be "over-collateralized". At no point, should the value of all collateral <= the $ backed value of all DSC.
 *
 *     @notice This contract is the core of the DSC System. It handles all the logic for mining and redeeming DSC, as well as depositing & withdrawing collateral.
 *     @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% over-collaterlized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_PRECISION = 1e10;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus.
    // --- State Variables ---
    DecentralizedStableCoin private immutable i_dsc;
    mapping(address token => address priceFeed) private s_priceFeeds; // priceFeedByToken
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;
    address[] s_collateralTokens;

    // --- Events ---
    event DSCEngine__UpdatedValidCollateral(address indexed token, address priceFeed);
    event DSCEngine__CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event DSCEngine__CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed collateralToken, uint256 amount
    );

    // --- Errors ---
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__MintFailed();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__RequireAtleastOneFormOfCollateral();
    error DSCEngine__InvalidCollateralProvided();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    // --- Modifiers ---
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            // Solidity compiler versions ^0.8.0 automatically revert when uint256 is < 0
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__InvalidCollateralProvided();
        }
        _;
    }

    // --- Functions ---
    constructor(address[] memory validCollateral, address[] memory priceFeeds, address dscAddress)
        moreThanZero(validCollateral.length)
    {
        if (validCollateral.length != priceFeeds.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        if (!(validCollateral.length > 0)) {
            revert DSCEngine__RequireAtleastOneFormOfCollateral();
        }
        for (uint256 i = 0; i < validCollateral.length; i++) {
            s_priceFeeds[validCollateral[i]] = priceFeeds[i];
            s_collateralTokens.push(validCollateral[i]);
            emit DSCEngine__UpdatedValidCollateral(validCollateral[i], priceFeeds[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 collateralAmount,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, collateralAmount);
        mintDsc(amountDscToMint);
    }

    function redeemCollateralForDsc(address collateralToken, uint256 collateralAmount, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(collateralToken, collateralAmount);
    }

    /*
     * @param collateral: The ERC20 token address of the collateral you're using to make the protocol solvent again.
     * This is collateral that you're going to take from the user who is insolvent.
     * In return, you have to burn your DSC to pay off their debt, but you don't pay off your own.
     * @param user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
     * @param debtToCover: The amount of DSC you want to burn to cover the user's debt.
     *
     * @notice: You can partially liquidate a user.
     * @notice: You will get a 10% LIQUIDATION_BONUS for taking the users funds.
    * @notice: This function working assumes that the protocol will be roughly 150% overcollateralized in order for this
    to work.
    * @notice: A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate
    anyone.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 initialUserHealthFactor = _healthFactor(user);
        if (initialUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        _burnDsc(debtToCover, user, msg.sender);

        uint256 finalUserHealthFactor = _healthFactor(user);
        if (finalUserHealthFactor <= initialUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    /**
     * In order to redeem collateral:
     * - 1. Health Factor must be over 1 AFTER collateral has been withdrawn.
     */
    function redeemCollateral(address collateralToken, uint256 collateralAmount)
        public
        moreThanZero(collateralAmount)
        nonReentrant
    {
        _redeemCollateral(collateralToken, collateralAmount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * Removes Debt
     */
    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountDscToMint: The amount of DSC you want to mint
     * @notice This function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateral(address tokenCollateralAddress, uint256 collateralAmount)
        public
        moreThanZero(collateralAmount)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        // Checks
        // Effects
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += collateralAmount;
        emit DSCEngine__CollateralDeposited(msg.sender, tokenCollateralAddress, collateralAmount);
        // Interactions
        // Q: Doesn't this require the user to have approved the DSCEngine to spend their collateral token first? Where is that happening?
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), collateralAmount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += amountDscToMint;
        // If user has minted to much (e.g. attempting to mint $150 DSC with $100 ETH collateral).
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // get price of token  (if price is $/ETH) *
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_PRECISION);
    }

    /**
     * Returns a users account collateral value in USD.
     */
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueUsd) {
        // Iterate through each collateral token address.
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address collateralToken = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][collateralToken];
            if (amount > 0) {
                totalCollateralValueUsd += getUsdValue(collateralToken, amount);
            }
        }
    }

    /**
     * @notice This function will not return the correct USD value for tokens that do not have 18 decimals and a price feed of 8 decimals.
     */
    function getUsdValue(address token, uint256 amount) public view returns (uint256 usdValue) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 answer,,,) = priceFeed.latestRoundData();
        /* 
            ETH / USD = $1000 (8 decimals) = 1000 * 1e8 (This is the returned value). Recall: amount is in WEI (18 decimals).
            answer would be in units of 1e8 we times by 1e10 to get to 1e18 which matches the decimals of the token amount.
        */
        usdValue = ((uint256(answer) * ADDITIONAL_PRECISION) * (amount)) / 1e18;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function _redeemCollateral(address collateralToken, uint256 collateralAmount, address from, address to) private {
        s_collateralDeposited[from][collateralToken] -= collateralAmount;
        emit DSCEngine__CollateralRedeemed(from, to, collateralToken, collateralAmount);
        bool success = IERC20(collateralToken).transfer(to, collateralAmount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_dscMinted[onBehalfOf] -= amountDscToBurn;

        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        // This conditional is hypothetically unreachable
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_dscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjForThreshold * PRECISION) / totalDscMinted;
    }

    function getAccountInformation(address user)
        public
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_dscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    function getCollateralAmountByTokenForUser(address user, address token) public view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getDscMintedByUser(address user) public view returns (uint256) {
        return s_dscMinted[user];
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }
}
