// script/Deploy.s.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {SplitCoordinator} from "../src/SplitCoordinator.sol";

contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        SplitCoordinator c = new SplitCoordinator("Split3", "1");
        vm.stopBroadcast();
        console2.log("SplitCoordinator deployed at:", address(c));
    }
}
