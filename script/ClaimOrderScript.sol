// SPDX-License-Identifier: CAL
pragma solidity =0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {
    IRaindexV6,
    OrderConfigV4,
    OrderV4,
    IOV2,
    EvaluableV4
} from "raindex-interface-0.1.7/src/interface/IRaindexV6.sol";
import {HoloLockVault} from "src/HoloLockVault.sol";
import {ClaimInputToken} from "src/ClaimInputToken.sol";
import {
    RAINDEX,
    RAINDEX_CODEHASH,
    RAINDEX_SUBPARSER,
    RAINDEX_SUBPARSER_CODEHASH,
    RAINLANG_DEPLOYER,
    RAINLANG_DEPLOYER_HASH,
    RAINLANG_INTERPRETER,
    RAINLANG_INTERPRETER_HASH,
    RAINLANG_STORE,
    RAINLANG_STORE_HASH,
    TEST_SIGNER_ADDRESS,
    HOLO_VAULT_ID,
    CLAIM_ORDER_NONCE
} from "src/Constants.sol";

interface SafeThreshold {
    function getThreshold() external view returns (uint256);
}

/// One network's claim order: its name, chain, and the variable its lock vault
/// is passed as. Raindex V6 and the Rainlang contracts are at the same address on
/// every chain, so the network names nothing else. The TestNet is Base Sepolia.
struct ClaimNetwork {
    string name;
    uint256 chainId;
    string vaultVar;
}

abstract contract ClaimOrderScript is Script {
    bytes32 private constant ADD_ORDER_V3 = keccak256(
        "AddOrderV3(address,bytes32,(address,(address,address,bytes),(address,bytes32)[],(address,bytes32)[],bytes32))"
    );

    function claimNetwork(string memory name) internal pure returns (ClaimNetwork memory) {
        bytes32 key = keccak256(bytes(name));
        if (key == keccak256("mainnet")) {
            return ClaimNetwork("mainnet", 1, "MAINNET_LOCK_VAULT_ADDRESS");
        }
        if (key == keccak256("base-sepolia")) {
            return ClaimNetwork("base-sepolia", 84532, "BASE_SEPOLIA_LOCK_VAULT_ADDRESS");
        }
        revert(string.concat("NETWORK must be base-sepolia or mainnet, not ", name));
    }

    /// NETWORK's claim order, base-sepolia when NETWORK is unset.
    function networkFromEnv() internal view returns (ClaimNetwork memory net) {
        net = claimNetwork(vm.envOr("NETWORK", string("base-sepolia")));
        requireChain(net);
    }

    function requireChain(ClaimNetwork memory net) internal view {
        require(
            block.chainid == net.chainId,
            string.concat(
                "the RPC answers for chain ",
                vm.toString(block.chainid),
                ", and NETWORK=",
                net.name,
                " is chain ",
                vm.toString(net.chainId)
            )
        );
    }

    /// The Raindex V6 and Rainlang release src/Constants.sol names must be on the
    /// chain, byte for byte. Rain deploys each through its deterministic deployer
    /// to the same address on every chain, on Ethereum mainnet and Base Sepolia
    /// among them.
    function requireRainV6() internal view {
        requireRelease("RaindexV6", address(RAINDEX), RAINDEX_CODEHASH);
        requireRelease("RaindexV6SubParser", RAINDEX_SUBPARSER, RAINDEX_SUBPARSER_CODEHASH);
        requireRelease("RainlangExpressionDeployer", address(RAINLANG_DEPLOYER), RAINLANG_DEPLOYER_HASH);
        requireRelease("RainlangInterpreter", address(RAINLANG_INTERPRETER), RAINLANG_INTERPRETER_HASH);
        requireRelease("RainlangStore", address(RAINLANG_STORE), RAINLANG_STORE_HASH);
    }

    function requireRelease(string memory name, address at, bytes32 codehash) private view {
        require(
            at.code.length > 0,
            string.concat(
                name,
                " is not deployed at ",
                vm.toString(at),
                " on chain ",
                vm.toString(block.chainid),
                ": Rain has not deployed this release there (DEPLOY.md)"
            )
        );
        require(
            at.codehash == codehash,
            string.concat(name, " at ", vm.toString(at), " is not the release src/Constants.sol names")
        );
    }

    /// An EIP-7702 delegation leaves a key a key.
    function isContract(address account) internal view returns (bool) {
        bytes memory code = account.code;
        bool delegatedKey = code.length == 23 && code[0] == 0xef && code[1] == 0x01 && code[2] == 0x00;
        return code.length > 0 && !delegatedKey;
    }

    /// Refuses the test signer on mainnet, and a contract signer whose signatures the
    /// website cannot read: it reads a Safe's 2 to 20 owner signatures, and 65 bytes
    /// as a key's.
    function requireSigner(ClaimNetwork memory net, address signer) internal view {
        require(signer != address(0), "VALID_SIGNER must be a nonzero address");
        require(
            net.chainId != 1 || signer != TEST_SIGNER_ADDRESS,
            "VALID_SIGNER is the test signer, whose key is public: mainnet refuses it"
        );
        if (isContract(signer)) {
            (bool answered, bytes memory threshold) = signer.staticcall(abi.encodeCall(SafeThreshold.getThreshold, ()));
            require(
                answered && threshold.length == 32 && abi.decode(threshold, (uint256)) >= 2
                    && abi.decode(threshold, (uint256)) <= 20,
                "VALID_SIGNER is a contract but not a Safe whose threshold is 2 to 20"
            );
        }
    }

    /// The claim order paying `token` out of HOLO_VAULT_ID against `inputToken`,
    /// accepting coupons from `signer`, composed and parsed before anything is
    /// sent.
    function claimOrderConfig(ClaimNetwork memory net, address token, address inputToken, address signer)
        internal
        returns (OrderConfigV4 memory)
    {
        return OrderConfigV4(
            EvaluableV4(RAINLANG_INTERPRETER, RAINLANG_STORE, parseClaim(net, signer)),
            claimIO(inputToken),
            claimIO(token),
            CLAIM_ORDER_NONCE,
            bytes32(0),
            ""
        );
    }

    function claimOrder(address vault, address token, address inputToken, bytes memory bytecode)
        internal
        pure
        returns (OrderV4 memory)
    {
        return OrderV4(
            vault,
            EvaluableV4(RAINLANG_INTERPRETER, RAINLANG_STORE, bytecode),
            claimIO(inputToken),
            claimIO(token),
            CLAIM_ORDER_NONCE
        );
    }

    function orderHashOf(OrderV4 memory order) internal pure returns (bytes32) {
        return keccak256(abi.encode(order));
    }

    function claimIO(address token) private pure returns (IOV2[] memory io) {
        io = new IOV2[](1);
        io[0] = IOV2(token, HOLO_VAULT_ID);
    }

    /// The claim expression for `signer`, composed by compose-rainlang.mjs and
    /// parsed by the network's expression deployer into the order's bytecode.
    function parseClaim(ClaimNetwork memory net, address signer) private returns (bytes memory) {
        string[] memory command = new string[](8);
        command[0] = "node";
        command[1] = "compose-rainlang.mjs";
        command[2] = "--network";
        command[3] = net.name;
        command[4] = "--subparser";
        command[5] = vm.toString(RAINDEX_SUBPARSER);
        command[6] = "--signer";
        command[7] = vm.toString(signer);
        Vm.FfiResult memory composed = vm.tryFfi(command);
        require(composed.exitCode == 0, string.concat("compose-rainlang.mjs failed: ", string(composed.stderr)));
        return RAINLANG_DEPLOYER.parse2(composed.stdout);
    }

    /// Sends `calls` to the vault as its admin, each of which must change the
    /// orderbook. An admin that is a contract, such as a Safe, cannot sign here:
    /// its calls are printed for it to execute.
    function asAdmin(HoloLockVault vault, bytes[] memory calls) internal {
        address admin = vault.admin();
        if (isContract(admin)) {
            console2.log(
                string.concat(
                    "The vault admin ",
                    vm.toString(admin),
                    " is a contract. Nothing was sent. Execute these calls from it, in this order:"
                )
            );
            for (uint256 i = 0; i < calls.length; i++) {
                console2.log(
                    string.concat(
                        vm.toString(i + 1),
                        ". to ",
                        vm.toString(address(vault)),
                        ", value 0, data ",
                        vm.toString(calls[i])
                    )
                );
            }
            return;
        }
        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        require(sender == admin, string.concat("pass the vault admin's wallet: the admin is ", vm.toString(admin)));
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory result) = address(vault).call(calls[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(result, 0x20), mload(result))
                }
            }
            require(abi.decode(result, (bool)), "the orderbook already held that order, or no longer did");
        }
        vm.stopBroadcast();
    }

    /// The claim order `vault` added last from `fromBlock` on, read from the chain
    /// and checked against it: the only order the vault added since that is still on
    /// the orderbook, paying the vault's token out of HOLO_VAULT_ID against a
    /// ClaimInputToken, run by the network's interpreter and store, and carrying
    /// the claim expression that accepts coupons from `signer` and nothing else.
    function findClaimOrder(ClaimNetwork memory net, HoloLockVault vault, address signer, uint256 fromBlock)
        internal
        returns (OrderV4 memory order, bytes32 orderHash)
    {
        requireSigner(net, signer);
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = ADD_ORDER_V3;
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(fromBlock, block.number, address(RAINDEX), topics);
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            (address sender, bytes32 addedHash, OrderV4 memory added) =
                abi.decode(logs[i].data, (address, bytes32, OrderV4));
            if (sender != address(vault)) continue;
            if (found) {
                require(
                    !RAINDEX.orderExists(orderHash),
                    string.concat("the vault holds another order added since block ", vm.toString(fromBlock))
                );
            }
            (order, orderHash, found) = (added, addedHash, true);
        }
        require(found, string.concat("the vault added no order from block ", vm.toString(fromBlock)));
        require(
            order.evaluable.interpreter == RAINLANG_INTERPRETER && order.evaluable.store == RAINLANG_STORE,
            "the claim order is not run by the network's interpreter and store"
        );
        require(orderHashOf(order) == orderHash, "the AddOrderV3 event's order does not hash to its order hash");
        require(RAINDEX.orderExists(orderHash), "the vault's last claim order is no longer on the orderbook");
        require(
            order.validInputs.length == 1 && order.validOutputs.length == 1
                && orderHashOf(
                    claimOrder(
                        address(vault), address(vault.token()), order.validInputs[0].token, order.evaluable.bytecode
                    )
                ) == orderHash,
            "the vault's last order is not a claim order paying its token out of HOLO_VAULT_ID"
        );
        require(
            order.validInputs[0].token.codehash == keccak256(type(ClaimInputToken).runtimeCode),
            "the claim order's input token is not a ClaimInputToken"
        );
        require(
            keccak256(order.evaluable.bytecode) == keccak256(parseClaim(net, signer)),
            "the claim order's expression is not the claim expression for VALID_SIGNER"
        );
    }

    /// The values the orchestrator and the website take, under their names.
    function printRecord(
        ClaimNetwork memory net,
        HoloLockVault vault,
        address signer,
        OrderV4 memory order,
        bytes32 orderHash
    ) internal view {
        string memory vaultAddress = vm.toString(address(vault));
        string memory token = vm.toString(order.validOutputs[0].token);
        string memory orderbook = vm.toString(address(vault.orderbook()));
        string memory hash = vm.toString(orderHash);
        string memory bytecode = vm.toString(order.evaluable.bytecode);
        console2.log("Deploy record");
        console2.log("bridge-orchestrator:");
        console2.log(string.concat("NETWORK=", net.name));
        console2.log(string.concat(net.vaultVar, "=", vaultAddress));
        console2.log(string.concat("TOKEN_ADDRESS=", token));
        console2.log(string.concat("ORDERBOOK_ADDRESS=", orderbook));
        console2.log(string.concat("VAULT_ID=", vm.toString(order.validOutputs[0].vaultId)));
        console2.log(string.concat("ORDER_HASH=", hash));
        console2.log(string.concat("ORDER_OWNER=", vm.toString(order.owner)));
        console2.log(string.concat("CLAIM_SIGNER=", vm.toString(signer)));
        console2.log(string.concat("CLAIM_INTERPRETER=", vm.toString(address(order.evaluable.interpreter))));
        console2.log(string.concat("CLAIM_STORE=", vm.toString(address(order.evaluable.store))));
        console2.log(string.concat("CLAIM_BYTECODE=", bytecode));
        console2.log(string.concat("CLAIM_INPUT_TOKEN=", vm.toString(order.validInputs[0].token)));
        console2.log("website:");
        console2.log(string.concat("PUBLIC_NETWORK=", net.name));
        console2.log(string.concat("PUBLIC_TOKEN_ADDRESS=", token));
        console2.log(string.concat("PUBLIC_LOCK_VAULT_ADDRESS=", vaultAddress));
        console2.log(string.concat("PUBLIC_ORDERBOOK_ADDRESS=", orderbook));
        console2.log(string.concat("PUBLIC_CLAIM_ORDER_HASH=", hash));
        console2.log(string.concat("PUBLIC_CLAIM_SIGNER=", vm.toString(signer)));
        console2.log(string.concat("PUBLIC_CLAIM_INTERPRETER=", vm.toString(address(order.evaluable.interpreter))));
        console2.log(string.concat("PUBLIC_CLAIM_STORE=", vm.toString(address(order.evaluable.store))));
        console2.log(string.concat("PUBLIC_CLAIM_BYTECODE=", bytecode));
        console2.log(string.concat("PUBLIC_CLAIM_INPUT_TOKEN=", vm.toString(order.validInputs[0].token)));
    }
}
