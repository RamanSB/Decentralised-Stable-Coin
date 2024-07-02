// SDPX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {DSCEngine} from "../src/DSCEngine.sol";

contract DeployDSCEngine is Script {
    function run() external returns (DSCEngine) {
        vm.startBroadcast();
        address[] memory validCollaterals;
        address[] memory priceFeeds;
        DSCEngine dscEngine = new DSCEngine(validCollaterals, priceFeeds);
        vm.stopBroadcast();
        return dscEngine;
    }
}
