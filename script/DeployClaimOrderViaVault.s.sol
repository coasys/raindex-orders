// SPDX-License-Identifier: CAL
pragma solidity =0.8.25;

import {HoloLockVault} from "src/HoloLockVault.sol";
import {RAINDEX} from "src/Constants.sol";
import {ClaimOrderScript, ClaimNetwork, ClaimSigners} from "./ClaimOrderScript.sol";

/// @title DeployClaimOrderViaVault
/// @notice Adds the claim order through NETWORK's lock vault, so the
/// vault owns it and claims pay out of the vault locks deposit into. Each coupon
/// must carry the signatures of SIGNER_THRESHOLD of VALID_SIGNERS, and the
/// order's input token is CLAIM_INPUT_TOKEN, the ClaimInputToken deployed with
/// the vault. On base-sepolia, NETWORK and the signers default to TestNet's:
/// the test signer alone.
contract DeployClaimOrderViaVault is ClaimOrderScript {
    function run() external {
        ClaimNetwork memory net = networkFromEnv();
        requireRainV6();
        HoloLockVault vault = HoloLockVault(vm.envAddress(net.vaultVar));
        address inputToken = vm.envAddress("CLAIM_INPUT_TOKEN");
        ClaimSigners memory signers = signersFromEnv(net);
        requireSigners(net, signers);
        require(address(vault.orderbook()) == address(RAINDEX), "the vault's orderbook is not RaindexV6");

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(
            HoloLockVault.addOrder, (claimOrderConfig(net, address(vault.token()), inputToken, signers))
        );
        asAdmin(vault, calls);
    }
}
