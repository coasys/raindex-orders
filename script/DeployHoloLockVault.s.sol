// SPDX-License-Identifier: CAL
pragma solidity =0.8.25;

import {console2} from "forge-std/Script.sol";
import {HoloLockVault} from "src/HoloLockVault.sol";
import {ClaimInputToken} from "src/ClaimInputToken.sol";
import {RAINDEX, HOLO_VAULT_ID, MIN_LOCK_AMOUNT} from "src/Constants.sol";
import {ClaimOrderScript} from "./ClaimOrderScript.sol";

/// Deploys HoloLockVault on Base Sepolia, the TestNet, against the RaindexV6
/// at Rain's deterministic address, and the ClaimInputToken its claim order
/// takes as input. TOKEN_ADDRESS is the mock HOT deploy-base-sepolia.sh
/// deployed first. Mainnet deploys through deploy-mainnet.sh.
contract DeployBaseSepoliaHoloLockVault is ClaimOrderScript {
    function run() external {
        requireChain(claimNetwork("base-sepolia"));
        requireRainV6();
        address token = vm.envAddress("TOKEN_ADDRESS");
        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);

        console2.log("Deploying HoloLockVault to Base Sepolia...");
        console2.log("Token:", token);
        console2.log("Orderbook:", address(RAINDEX));
        console2.log("Vault ID:", vm.toString(HOLO_VAULT_ID));
        console2.log("Admin:", admin);
        console2.log("Min Lock Amount:", MIN_LOCK_AMOUNT);

        vm.startBroadcast();

        ClaimInputToken inputToken = new ClaimInputToken();
        HoloLockVault lockVault = new HoloLockVault(token, address(RAINDEX), HOLO_VAULT_ID, admin, MIN_LOCK_AMOUNT);

        vm.stopBroadcast();

        console2.log("HoloLockVault deployed at:", address(lockVault));
        console2.log("ClaimInputToken deployed at:", address(inputToken));
    }
}
