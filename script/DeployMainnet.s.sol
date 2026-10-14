// SPDX-License-Identifier: CAL
pragma solidity =0.8.25;

import {OrderV4} from "raindex-interface-0.1.7/src/interface/IRaindexV6.sol";
import {HoloLockVault} from "src/HoloLockVault.sol";
import {ClaimInputToken} from "src/ClaimInputToken.sol";
import {MAINNET_HOT, RAINDEX, HOLO_VAULT_ID, MIN_LOCK_AMOUNT} from "src/Constants.sol";
import {ClaimOrderScript, ClaimNetwork} from "./ClaimOrderScript.sol";

/// Deploys the HOT bridge on Ethereum mainnet against the RaindexV6 Rain
/// deployed there: the claim input token, HoloLockVault, then the claim order
/// through it, then hands the vault to ADMIN_ADDRESS. deploy-mainnet.sh runs
/// it, then `record`.
contract DeployMainnet is ClaimOrderScript {
    function run() external {
        ClaimNetwork memory net = claimNetwork("mainnet");
        requireChain(net);
        requireRainV6();
        address admin = vm.envAddress("ADMIN_ADDRESS");
        address signer = vm.envAddress("VALID_SIGNER");
        require(admin != address(0), "ADMIN_ADDRESS must be a nonzero address");
        requireSigner(net, signer);

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        require(deployer != DEFAULT_SENDER, "pass the deployer as a forge wallet option: --ledger or --account");
        require(admin != deployer, "ADMIN_ADDRESS is the deployer, which would stay admin after the handover");
        ClaimInputToken inputToken = new ClaimInputToken();
        HoloLockVault vault =
            new HoloLockVault(address(MAINNET_HOT), address(RAINDEX), HOLO_VAULT_ID, deployer, MIN_LOCK_AMOUNT);
        require(
            vault.addOrder(claimOrderConfig(net, address(MAINNET_HOT), address(inputToken), signer)),
            "the orderbook already holds this claim order"
        );
        vault.setAdmin(admin);
        vm.stopBroadcast();
    }

    /// Prints the deploy record of `vault`, read from the chain, and of the claim
    /// order it added from `fromBlock` on.
    function record(HoloLockVault vault, uint256 fromBlock) external {
        ClaimNetwork memory net = claimNetwork("mainnet");
        requireChain(net);
        require(address(vault.token()) == address(MAINNET_HOT), "the vault's token is not HOT");
        require(address(vault.orderbook()) == address(RAINDEX), "the vault's orderbook is not RaindexV6");
        require(vault.vaultId() == HOLO_VAULT_ID, "the vault's vault ID is not HOLO_VAULT_ID");
        require(vault.admin() == vm.envAddress("ADMIN_ADDRESS"), "the vault's admin is not ADMIN_ADDRESS");
        address signer = vm.envAddress("VALID_SIGNER");
        (OrderV4 memory order, bytes32 orderHash) = findClaimOrder(net, vault, signer, fromBlock);
        printRecord(net, vault, signer, order, orderHash);
    }
}
