// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSCEngine} from "../../script/DeployDSCEngine.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSCEngine deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address weth;
    address btcUsdPriceFeed;
    address wbtc;

    address private USER = makeAddr("USER");

    function setUp() public {
        deployer = new DeployDSCEngine();
        (dsc, dscEngine, config) = deployer.run();
        (ethUsdPriceFeed,, weth,,) = config.s_activeNetworkConfig();
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
}
