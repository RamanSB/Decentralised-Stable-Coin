// SPDX-License-Identifier: MIT

/**
Contract Elements should be laid out in the following order:
    Pragma statements
    Import statements
    Events
    Errors
    Interfaces
    Libraries
    Contracts

Inside each contract, library or interface, use the following order:
    Type declarations
    State variables
    Events
    Errors
    Modifiers
    Functions

 
Layout of Functions:
    constructor
    receive function (if exists)
    fallback function (if exists)
    external
    public
    internal
    private
*/

pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
    @title DSCEngine
    @author 0xNascosta

    The system is designed to be as minimial as possible and have the tokens maintain a 1 token == $1 peg.

    This stable coin has the properties:
    - Exogenous Collateral
    - Dollar Pegged
    - Algorithmically Stable

    It is similar to DAI if DAI had no governance, no fees and was only backed by WETH and WBTC.

    Out DSC system should always be "overcollateralized". At no point, should the value of all collateral <= the $ backed value of all DSC.

    @notice This contract is the core of the DSC System. It handles all the logic for mining and redeeming DSC, as well as depositing & withdrawing collateral.
    @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    // --- State Variables ---
    mapping(address token => address priceFeed) private s_priceFeeds; // priceFeedByToken
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;

    // --- Events ---
    event DSCEngine__UpdatedValidCollateral(
        address indexed token,
        address priceFeed
    );
    event DSCEngine__CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );

    // --- Errors ---
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__RequireAtleastOneFormOfCollateral();
    error DSCEngine__InvalidCollateralProvided();
    error DSCEngine__TransferFailed();

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
    constructor(
        address[] memory validCollateral,
        address[] memory priceFeeds
    ) moreThanZero(validCollateral.length) {
        if (validCollateral.length != priceFeeds.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        if (!(validCollateral.length > 0)) {
            revert DSCEngine__RequireAtleastOneFormOfCollateral();
        }
        for (uint256 i = 0; i < validCollateral.length; i++) {
            s_priceFeeds[validCollateral[i]] = priceFeeds[i];
            emit DSCEngine__UpdatedValidCollateral(
                validCollateral[i],
                priceFeeds[i]
            );
        }
    }

    function depositCollateralAndMintDsc() external {}

    function depositCollateral(
        address tokenCollateralAddress,
        uint256 collateralAmount
    )
        external
        moreThanZero(collateralAmount)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        // Checks
        // Effects
        s_collateralDeposited[msg.sender][
            tokenCollateralAddress
        ] += collateralAmount;
        emit DSCEngine__CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            collateralAmount
        );
        // Interactions
        // Q: Doesn't this require the user to have approved the DSCEngine to spend their collateral token first? Where is that happening?
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            collateralAmount
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollateralForDsc() external {}
    function redeemCollateral() external {}
    function mintDsc() external {}
    function burnDsc() external {}
    function liquidate() external {}
    function getHealthFactor() external view {}
}
