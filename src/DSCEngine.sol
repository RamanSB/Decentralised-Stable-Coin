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
    uint256 private constant LIQUIDIATION_THRESHOLD = 50; // 200% over-collaterlized
    uint256 private constant LIQUIDIATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;
    uint256 private constant PRECISION = 18;
    // --- State Variables ---
    DecentralizedStableCoin private immutable i_dsc;
    mapping(address token => address priceFeed) private s_priceFeeds; // priceFeedByToken
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;
    address[] s_collateralTokens;

    // --- Events ---
    event DSCEngine__UpdatedValidCollateral(address indexed token, address priceFeed);
    event DSCEngine__CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    // --- Errors ---
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__MintFailed();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__RequireAtleastOneFormOfCollateral();
    error DSCEngine__InvalidCollateralProvided();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);

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
        address tokenCollateralADdress,
        uint256 collateralAmount,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, collateralAmount);
        mintDsc(amountDscToMint);
    }

    function redeemCollateralForDsc() external {}
    function redeemCollateral() external {}

    function burnDsc() external {}
    function liquidate() external {}
    function getHealthFactor() external view {}

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
        uint256 additionalPrecision = 1e10;
        usdValue = ((uint256(answer) * additionalPrecision) * (amount)) / 1e18;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
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
        uint256 collateralAdjForThreshold = (collateralValueInUsd * LIQUIDIATION_THRESHOLD) / LIQUIDIATION_PRECISION;
        return (collateralAdjForThreshold * PRECISION) / totalDscMinted;
    }
}
