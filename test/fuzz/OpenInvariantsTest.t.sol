// // SPDX-License-Identifier: MIT
// // Have our invariants aka properties

// // What our invariants?

// // 1. The total supply of DSC should be less than the total value of collateral.

// // 2. Getter view functions should never revert. (Evergreen Invariant).

// pragma solidity ^0.8.26;

// import {Test, console} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DeployDSCEngine} from "../../script/DeployDSCEngine.s.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// contract InvariantsTest is StdInvariant, Test {
//     DeployDSCEngine deployer;
//     DSCEngine dscEngine;
//     HelperConfig helperConfig;
//     DecentralizedStableCoin dsc;
//     address weth;
//     address wbtc;
//     /* address wethUsdPriceFeed;
//     address wbtcUsdPriceFeed;
//     uint256 deployerKey; */

//     function setUp() external {
//         deployer = new DeployDSCEngine();
//         (dsc, dscEngine, helperConfig) = deployer.run();
//         (,, weth, wbtc,) = helperConfig.s_activeNetworkConfig();
//         console.log(weth);
//         console.log(wbtc);
//         targetContract(address(dscEngine));
//     }

//     function invariant_protocolMustHaveMoreCollateralValueThanTotalSupply() public view {
//         // get the value of all collateral in the protocol
//         // compare it to all the debt.
//         uint256 totalSupply = dsc.totalSupply();
//         console.log("Total Supply: ", totalSupply);
//         uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dscEngine));
//         uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dscEngine));

//         uint256 wethValue = dscEngine.getUsdValue(weth, totalWethDeposited);
//         uint256 wbtcValue = dscEngine.getUsdValue(wbtc, totalWbtcDeposited);
//         console.log("weth: ", weth);
//         console.log("wbtc: ", wbtc);
//         console.log("weth value: ", wethValue);
//         console.log("wbtc value: ", wbtcValue);
//         assert(wethValue + wbtcValue >= totalSupply);
//     }
// }
