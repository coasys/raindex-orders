// SPDX-License-Identifier: CAL
pragma solidity =0.8.25;

import {OrderV4} from "raindex-interface-0.1.7/src/interface/IRaindexV6.sol";
import {HoloLockVault} from "src/HoloLockVault.sol";
import {RAINDEX} from "src/Constants.sol";
import {ClaimOrderScript, ClaimNetwork, ClaimSigners} from "./ClaimOrderScript.sol";

/// Replaces the vault's claim order with one that accepts coupons signed by
/// SIGNER_THRESHOLD of VALID_SIGNERS: adds the new order, then removes the
/// current one. The signers and the threshold are written into the order's
/// expression, so this is how either changes. It reads the current order from
/// the deploy record's variables, under the names the record prints them.
/// VALID_SIGNERS and SIGNER_THRESHOLD, the new ones, have no default.
/// rotate-claim-signer.sh runs it.
contract RotateClaimSigner is ClaimOrderScript {
    function run() external {
        ClaimNetwork memory net = networkFromEnv();
        requireRainV6();
        HoloLockVault vault = HoloLockVault(vm.envAddress(net.vaultVar));
        ClaimSigners memory signers = requiredSignersFromEnv(net);
        requireSigners(net, signers);
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
        calls[0] = abi.encodeCall(
            HoloLockVault.addOrder, (claimOrderConfig(net, address(vault.token()), inputToken, signers))
        );
        calls[1] = abi.encodeCall(HoloLockVault.removeOrder, (current));
        asAdmin(vault, calls);
    }

    /// Prints the deploy record of the claim order the vault added from
    /// `fromBlock` on, once the previous one, ORDER_HASH, is removed.
    function record(uint256 fromBlock) external {
        ClaimNetwork memory net = networkFromEnv();
        HoloLockVault vault = HoloLockVault(vm.envAddress(net.vaultVar));
        ClaimSigners memory signers = requiredSignersFromEnv(net);
        (OrderV4 memory order, bytes32 orderHash) = findClaimOrder(net, vault, signers, fromBlock);
        require(
            !RAINDEX.orderExists(vm.envBytes32("ORDER_HASH")),
            "the previous claim order ORDER_HASH is still on the orderbook"
        );
        printRecord(net, vault, signers, order, orderHash);
    }

    /// The new signers, with no TestNet default: a rotation states them.
    function requiredSignersFromEnv(ClaimNetwork memory net) private view returns (ClaimSigners memory) {
        require(vm.envExists("VALID_SIGNERS"), "VALID_SIGNERS is required: the new coupon signers, separated by commas");
        require(
            vm.envExists("SIGNER_THRESHOLD"), "SIGNER_THRESHOLD is required: how many of VALID_SIGNERS sign each coupon"
        );
        return signersFromEnv(net);
    }
}
