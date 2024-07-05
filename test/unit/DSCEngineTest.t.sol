// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSCEngine} from "../../script/DeployDSCEngine.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "@chainlink/contracts/v0.8/tests/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSCEngine deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address weth;
    address btcUsdPriceFeed;
    address wbtc;

    address private USER = makeAddr("User");
    address private ZE_LIQUIDATOR = makeAddr("Liquidator");
    uint256 private constant COLLATERAL_AMOUNT = 10 ether;
    uint256 private constant INITIAL_WETH_BALANCE = 1000 ether;
    uint8 private constant PRICE_FEED_DECIMALS = 8;

    function setUp() public {
        deployer = new DeployDSCEngine();
        (dsc, dscEngine, config) = deployer.run();
        (ethUsdPriceFeed,, weth,,) = config.s_activeNetworkConfig();
    }

    address[] tokenAddresses;
    address[] priceFeedAddresses;
    // Constructor test

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmountInWei = 100 ether; // $100 worth of ETH, Suppose 1 ETH is worth $2000
        uint256 expectedWeth = 0.05 ether; // $100 of ETH when ETH is $2000 is 0.05 ether.
        uint256 actualWeth = dscEngine.getTokenAmountFromUsd(weth, usdAmountInWei);
        assertEq(expectedWeth, actualWeth);
    }

    // Price Tests
    function testGetUsdValue() public {
        // Given - Collateral tokens and an amount + Mock PriceFeed
        uint256 ethAmount = 15 ether; // 15e18 (15 ether)
        uint256 expectedUsdValue = ethAmount * 2000; // (2000 from the mock price feed).
        // When - Determining the USD value
        uint256 actualUsdValue = dscEngine.getUsdValue(weth, ethAmount);
        // Then - Assert we have the correct USD value associated with the provided collateral
        assertEq(actualUsdValue, expectedUsdValue);
    }

    function testRevertsIfZeroCollateral() public {
        // Given - user has funds approved for spending for DSCEngine
        ERC20Mock wethToken = ERC20Mock(weth);
        wethToken.mint(USER, 1000 ether);
        vm.prank(USER);
        wethToken.approve(address(dscEngine), 5 ether);
        uint256 approvedAmount = wethToken.allowance(USER, address(dscEngine));
        assertEq(approvedAmount, 5 ether);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0 ether);
    }

    function testRevertsWithUnapprovedCollateral() public {}

    modifier depositedCollateral() {
        ERC20Mock(weth).mint(USER, INITIAL_WETH_BALANCE);
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);
        dscEngine.depositCollateral(weth, COLLATERAL_AMOUNT);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateralAndMintedDsc(uint256 dscAmountToMint) {
        ERC20Mock(weth).mint(USER, INITIAL_WETH_BALANCE);
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);
        dscEngine.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, dscAmountToMint);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(COLLATERAL_AMOUNT, expectedDepositAmount);
    }

    function testDepositCollateralAndMint() public {
        ERC20Mock(weth).mint(USER, INITIAL_WETH_BALANCE);
        vm.startPrank(USER);
        // Collateral amount in USD when depositing 10 ETH is $20000 (We have a liquidation threshold of 50).
        // This means we can only mint at most 50% of our collateral amount max amount to mint is 10_000DSC.
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);
        uint256 amountOfDscToMint = 1000e18;
        dscEngine.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, amountOfDscToMint);
        uint256 dscBalance = dsc.balanceOf(USER);
        assertEq(dscBalance, amountOfDscToMint);
        uint256 healthFactor = dscEngine.getHealthFactor(USER);
        console.log("Users health factor: ", healthFactor); // 1000000000000000000000000000000000000 - Strange?
    }

    function testRevertIfDepositCollateralAndMintExceedsLiquidationThreshold() public {
        ERC20Mock(weth).mint(USER, INITIAL_WETH_BALANCE);
        vm.startPrank(USER);
        // Collateral amount in USD when depositing 10 ETH is $20000 (We have a liquidation threshold of 50).
        // This means we can only mint at most 50% of our collateral amount max amount to mint is 10_000DSC.
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT); // $20,000
        uint256 amountOfDscToMint = 15000e18; // Remember we expect for a given Collateral Amount you can only borrow 50% of that, i.e. the debt must at most 50% of what you are providing as collateral
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 909090909090909090));
        dscEngine.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, amountOfDscToMint);
    }

    uint256 dscAmountToMint = 2000 ether;

    function testShouldRedeemCollateralForDsc() public depositedCollateralAndMintedDsc(dscAmountToMint) {
        // given - 2 ether of DSC is minted (collateral value is 10 ether = $20000 USD)
        uint256 initialWethBalance = ERC20Mock(weth).balanceOf(USER); // Expecting this to increase if we are redeeming colalteral.
        uint256 initialDscBalance = dsc.balanceOf(USER);
        uint256 dscMinted = dscEngine.getDscMintedByUser(USER);
        uint256 initialWethCollateralDeposited = dscEngine.getCollateralAmountByTokenForUser(USER, weth);
        assertEq(initialWethCollateralDeposited, COLLATERAL_AMOUNT);
        assertEq(initialDscBalance, dscAmountToMint);
        assertEq(dscMinted, dscAmountToMint);
        // when - Redeeming collateral ($10k worth of collateral - should still be over collateralized).
        uint256 dscAmountToBurn = 1000 ether;
        uint256 collateralRedemptionAmount = 5 ether;
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), dscAmountToBurn);
        dscEngine.redeemCollateralForDsc(weth, collateralRedemptionAmount, dscAmountToBurn);
        // then
        uint256 finalWethCollateralDeposited = dscEngine.getCollateralAmountByTokenForUser(USER, weth);
        assertEq(finalWethCollateralDeposited, COLLATERAL_AMOUNT - collateralRedemptionAmount);
        uint256 finalWethBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(finalWethBalance, initialWethBalance + collateralRedemptionAmount);
        uint256 finalDscBalance = dsc.balanceOf(USER);
        assertEq(finalDscBalance, initialDscBalance - dscAmountToBurn);
    }

    function testRevertIfRedeemingCollateralBreaksHealthFactor() public depositedCollateralAndMintedDsc(10000 ether) {
        // given - User has 10000 DSC and $20000 worth of ETH as collateral
        uint256 initialWethCollateralDeposited = dscEngine.getCollateralAmountByTokenForUser(USER, weth);
        assertEq(initialWethCollateralDeposited, COLLATERAL_AMOUNT);
        uint256 initialDscBalance = dsc.balanceOf(USER);
        assertEq(initialDscBalance, 10000 ether);
        // when - Attempting to redeem collateral say (2 ether - $4000 USD we would breach our health factor as we have borrowed $10000 debt and only have $16000 collateral)
        // then - revert because health factor is broken.
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 800000000000000000)); // 0.8 HF.
        dscEngine.redeemCollateral(weth, 2 ether);
    }

    function testRevertIfLiquidatingHealthyUser() public depositedCollateralAndMintedDsc(10000 ether) {
        // given - User has 10000 DSC and $20000 worth of ETH as collateral
        uint256 initialWethCollateralDeposited = dscEngine.getCollateralAmountByTokenForUser(USER, weth);
        assertEq(initialWethCollateralDeposited, COLLATERAL_AMOUNT);
        uint256 initialDscBalance = dsc.balanceOf(USER);
        assertEq(initialDscBalance, 10000 ether);
        uint256 healthFactor = dscEngine.getHealthFactor(USER); // 100000000000000000
        assertEq(healthFactor, 1 ether);
        // when - Attempting to redeem collateral say (2 ether - $4000 USD we would breach our health factor as we have borrowed $10000 debt and only have $16000 collateral)
        // then - revert because health factor is broken.
        uint256 debtToCover = 10000 ether;
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dscEngine.liquidate(weth, USER, debtToCover); // Attempting to pay back 10000 DSC (18 decimals, hence ether).
    }

    function testLiquidate() public depositedCollateralAndMintedDsc(10000 ether) {
        // given - User has 10000 DSC and $20000 worth of ETH as collateral - liquidator has enough DSC.
        vm.prank(address(dscEngine));
        dsc.mint(ZE_LIQUIDATOR, 10000 ether);
        uint256 initialWethCollateralDeposited = dscEngine.getCollateralAmountByTokenForUser(USER, weth);
        assertEq(initialWethCollateralDeposited, COLLATERAL_AMOUNT);
        uint256 initialDscBalance = dsc.balanceOf(USER);
        assertEq(initialDscBalance, 10000 ether);
        uint256 healthFactor = dscEngine.getHealthFactor(USER); // 100000000000000000
        assertEq(healthFactor, 1 ether);
        // when - Eth price drops to $1500 - Collateral value would be $15000 (our health factor is below the minimum)
        int256 updatedUsdPrice = 1500e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(updatedUsdPrice);
        console.log(dscEngine.getHealthFactor(USER)); // HF would be < 1.
        vm.startPrank(ZE_LIQUIDATOR);
        dsc.approve(address(dscEngine), 10000 ether);
        uint256 debtToCover = 3000 ether;
        dscEngine.liquidate(weth, USER, debtToCover);
        vm.stopPrank();
        // then - HF > 1 for User and liquidator has bonus collateral.
        uint256 redeemedBalance = ERC20Mock(weth).balanceOf(ZE_LIQUIDATOR);
        assertEq(redeemedBalance, 2 ether + (2 ether * 0.1));
    }
}
