// SPDX-License-Identifier: CAL
pragma solidity =0.8.25;

import {IRaindexV6} from "raindex-interface-0.1.7/src/interface/IRaindexV6.sol";
import {IParserV2} from "rainlang-interface-0.2.9/src/interface/IParserV2.sol";
import {IInterpreterV4} from "rainlang-interface-0.2.9/src/interface/IInterpreterV4.sol";
import {IInterpreterStoreV3} from "rainlang-interface-0.2.9/src/interface/IInterpreterStoreV3.sol";
import {Float} from "rain-math-float-0.2.1/src/lib/LibDecimalFloat.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// ========== RAIN, AS DEPLOYED ==========
// Rain deploys each release through the Zoltu deterministic deployer, so a
// contract has the same address on every chain it is deployed to, and the
// release freezes it in src/generated/<tag>/. The bridge takes the release Rain
// deployed on Ethereum mainnet: rain.orderbook 0.1.15 (its RaindexV6 and
// subparser are unchanged since 0.1.14, cut 2026-08-23) and rainlang 0.1.9 (cut
// 2026-08-25). Moving to another release is one edit per line below. None of
// these is on Sepolia yet: script/DeployRainV6Suite.s.sol puts them there.
import {DEPLOYED_ADDRESS as RAINDEX_V6_ADDRESS} from "raindex-0.1.15/src/generated/0_1_15/RaindexV6.sol";
import {
    DEPLOYED_ADDRESS as RAINDEX_V6_SUBPARSER_ADDRESS
} from "raindex-0.1.15/src/generated/0_1_15/RaindexV6SubParser.sol";
import {
    DEPLOYED_ADDRESS as RAINLANG_DEPLOYER_ADDRESS
} from "rainlang-0.2.6/src/generated/0_1_9/RainlangExpressionDeployer.sol";
import {
    DEPLOYED_ADDRESS as RAINLANG_INTERPRETER_ADDRESS
} from "rainlang-0.2.6/src/generated/0_1_9/RainlangInterpreter.sol";
import {DEPLOYED_ADDRESS as RAINLANG_STORE_ADDRESS} from "rainlang-0.2.6/src/generated/0_1_9/RainlangStore.sol";

IRaindexV6 constant RAINDEX = IRaindexV6(RAINDEX_V6_ADDRESS);
address constant RAINDEX_SUBPARSER = RAINDEX_V6_SUBPARSER_ADDRESS;
// The expression deployer parses the claim expression (`parse2`) into the
// bytecode the order carries.
IParserV2 constant RAINLANG_DEPLOYER = IParserV2(RAINLANG_DEPLOYER_ADDRESS);
IInterpreterV4 constant RAINLANG_INTERPRETER = IInterpreterV4(RAINLANG_INTERPRETER_ADDRESS);
IInterpreterStoreV3 constant RAINLANG_STORE = IInterpreterStoreV3(RAINLANG_STORE_ADDRESS);

// ========== MAINNET ==========
IERC20 constant MAINNET_HOT = IERC20(0x6c6EE5e31d828De241282B9606C8e98Ea48526E2);

// ========== SEPOLIA ==========
IERC20 constant SEPOLIA_TROT = IERC20(0x72bBeF0c3d23C196D324cF7cF59C083760fFae5b);

// ========== SHARED ==========
bytes32 constant TEST_SIGNER_KEY = 0xdcbe53cbf4cbee212fe6339821058f2787c7726ae0684335118cdea2e8adaafd;
address constant TEST_SIGNER_ADDRESS = 0x8E72b7568738da52ca3DCd9b24E178127A4E7d37;

// Vault ID used by the HoloLockVault
bytes32 constant HOLO_VAULT_ID = 0xeede83a4244afae4fef82c8f5b97df1f18bfe3193e65ba02052e37f6171b334b;

// Minimum lock amount (1 token with 18 decimals)
uint256 constant MIN_LOCK_AMOUNT = 1e18;

// The claim order's io-ratio, `1e-30` in src/holo-claim.rain, as the Float the
// parser makes of it: coefficient 1, exponent -30. Raindex V6 takes an order
// only at a positive ratio, and pulls at least one unit of the input token for
// it, so the input token is a ClaimInputToken that moves nothing. A claim passes
// this as its maximum ratio.
Float constant CLAIM_IO_RATIO =
    Float.wrap(bytes32(uint256(0xffffffe200000000000000000000000000000000000000000000000000000001)));

// The claim order's nonce: one claim order per signer list and threshold.
bytes32 constant CLAIM_ORDER_NONCE = bytes32(0);
