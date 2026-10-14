// SPDX-License-Identifier: CAL
pragma solidity =0.8.25;

import {OrderV4} from "raindex-interface-0.1.7/src/interface/IRaindexV6.sol";
import {HoloLockVault} from "src/HoloLockVault.sol";
import {RAINDEX} from "src/Constants.sol";
import {ClaimOrderScript, ClaimNetwork} from "./ClaimOrderScript.sol";

/// Replaces the vault's claim order with one that accepts coupons from
/// VALID_SIGNER: adds the new order, then removes the current one. It reads the
/// current one from the deploy record's variables, under the names the record
/// prints them. VALID_SIGNER, the new signer, has no default.
/// rotate-claim-signer.sh runs it.
contract RotateClaimSigner is ClaimOrderScript {
    function run() external {
        ClaimNetwork memory net = networkFromEnv();
        requireRainV6();
        HoloLockVault vault = HoloLockVault(vm.envAddress(net.vaultVar));
        address signer = vm.envAddress("VALID_SIGNER");
        requireSigner(net, signer);
        require(address(vault.orderbook()) == address(RAINDEX), "the vault's orderbook is not RaindexV6");

        address inputToken = vm.envAddress("PUBLIC_CLAIM_INPUT_TOKEN");
        OrderV4 memory current =
            claimOrder(address(vault), address(vault.token()), inputToken, vm.envBytes("PUBLIC_CLAIM_BYTECODE"));
        bytes32 currentHash = orderHashOf(current);
        require(
            currentHash == vm.envBytes32("ORDER_HASH"),
            "PUBLIC_CLAIM_BYTECODE and PUBLIC_CLAIM_INPUT_TOKEN do not rebuild ORDER_HASH"
        );
        require(RAINDEX.orderExists(currentHash), "ORDER_HASH is not an order on the orderbook");

        bytes[] memory calls = new bytes[](2);
        calls[0] =
            abi.encodeCall(HoloLockVault.addOrder, (claimOrderConfig(net, address(vault.token()), inputToken, signer)));
        calls[1] = abi.encodeCall(HoloLockVault.removeOrder, (current));
        asAdmin(vault, calls);
    }

    /// Prints the deploy record of the claim order the vault added from
    /// `fromBlock` on, once the previous one, ORDER_HASH, is removed.
    function record(uint256 fromBlock) external {
        ClaimNetwork memory net = networkFromEnv();
        HoloLockVault vault = HoloLockVault(vm.envAddress(net.vaultVar));
        address signer = vm.envAddress("VALID_SIGNER");
        (OrderV4 memory order, bytes32 orderHash) = findClaimOrder(net, vault, signer, fromBlock);
        require(
            !RAINDEX.orderExists(vm.envBytes32("ORDER_HASH")),
            "the previous claim order ORDER_HASH is still on the orderbook"
        );
        printRecord(net, vault, signer, order, orderHash);
    }
}
