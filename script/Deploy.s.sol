// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PrioUpdateRegistry} from "../src/PrioUpdateRegistry.sol";

contract Deploy is Script {
    address constant SAFE_SINGLETON_FACTORY = 0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7;

    function run(bytes32 salt, uint256 maxUpdateAge, uint256 maxUpdateLeadTime) external {
        bytes memory initcode =
            abi.encodePacked(type(PrioUpdateRegistry).creationCode, abi.encode(maxUpdateAge, maxUpdateLeadTime));
        address predicted = vm.computeCreate2Address(salt, keccak256(initcode), SAFE_SINGLETON_FACTORY);

        console.log("Factory:        ", SAFE_SINGLETON_FACTORY);
        console.log("Salt:           ", vm.toString(salt));
        console.log("Predicted addr: ", predicted);

        require(predicted.code.length == 0, "already deployed");

        vm.startBroadcast();
        (bool ok,) = SAFE_SINGLETON_FACTORY.call(abi.encodePacked(salt, initcode));
        vm.stopBroadcast();

        require(ok, "factory call reverted");
        require(predicted.code.length != 0, "no code at predicted address after deploy");

        console.log("Deployed at:    ", predicted);
    }
}
