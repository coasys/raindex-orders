// SPDX-License-Identifier: CAL
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {SignedContextV1} from "rainlang-interface-0.2.9/src/interface/IInterpreterCallerV4.sol";
import {Float, LibDecimalFloat} from "rain-math-float-0.2.1/src/lib/LibDecimalFloat.sol";
import {
    IRaindexV6,
    OrderV4,
    IOV2,
    EvaluableV4,
    TakeOrderConfigV4,
    TakeOrdersConfigV5
} from "raindex-interface-0.1.7/src/interface/IRaindexV6.sol";
import {
    HOLO_VAULT_ID,
    RAINDEX,
    MAINNET_HOT,
    RAINLANG_INTERPRETER,
    RAINLANG_STORE,
    CLAIM_ORDER_NONCE,
    CLAIM_IO_RATIO
} from "src/Constants.sol";
import {LibCoupon} from "./lib/LibCoupon.sol";
import {SignContext} from "./lib/SignContext.sol";

/// The coupon test vector: fixed inputs, and the nine words and the signature
/// they must give in every language. bridge-orchestrator/src/signer.rs
/// (`a_key_signs_the_coupon_the_claim_order_checks`) and ui/src/lib/coupon.test.ts
/// hold the same values, so the three agree on the encoding src/holo-claim.rain
/// reads. The rehearsals sign coupons with SignContext, which this pins too.
contract TestCouponSignature is Test, SignContext {
    using LibDecimalFloat for Float;

    /// Anvil's third account.
    uint256 internal constant SIGNER_KEY = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;

    function vector() internal pure returns (bytes32[] memory) {
        return LibCoupon.words(
            0x1111111111111111111111111111111111111111,
            1.5e18,
            1_750_000_000 + 7 days,
            0x5eeff397dac16f82057e20da98cf183daf95a0695980a196270e9e0922a275f9,
            0xE3E064e3C2EEf66cb93dA8D8114F5084E92F48D6,
            address(RAINDEX),
            address(MAINNET_HOT),
            HOLO_VAULT_ID,
            bytes32(uint256(8496889498503184870230947373316602526857109467185425766089433217409414560631))
        );
    }

    function testTheAmountWordIsTheWeiWithExponentMinus18() external pure {
        bytes32 word = LibCoupon.amountWord(1.5e18);

        assertEq(word, bytes32(uint256(0xffffffee << 224) | 1.5e18));
        assertEq(word, bytes32(0xffffffee000000000000000000000000000000000000000014d1120d7b160000));
        (int256 coefficient, int256 exponent) = Float.wrap(word).unpack();
        assertEq(coefficient, 1.5e18);
        assertEq(exponent, -18);
        assertEq(Float.wrap(word).toFixedDecimalLossless(18), 1.5e18);
    }

    function testTheWordsOfTheVector() external pure {
        bytes32[] memory words = vector();

        assertEq(words.length, 9);
        assertEq(words[0], bytes32(0x0000000000000000000000001111111111111111111111111111111111111111));
        assertEq(words[1], bytes32(0xffffffee000000000000000000000000000000000000000014d1120d7b160000));
        assertEq(words[2], bytes32(uint256(1750604800)));
        assertEq(words[3], bytes32(0x5eeff397dac16f82057e20da98cf183daf95a0695980a196270e9e0922a275f9));
        assertEq(words[4], bytes32(0x000000000000000000000000e3e064e3c2eef66cb93da8d8114f5084e92f48d6));
        assertEq(words[5], bytes32(0x00000000000000000000000037fc0efec37d19f8a221aa4f8f7600c9ba2acd20));
        assertEq(words[6], bytes32(0x0000000000000000000000006c6ee5e31d828de241282b9606c8e98ea48526e2));
        assertEq(words[7], bytes32(0xeede83a4244afae4fef82c8f5b97df1f18bfe3193e65ba02052e37f6171b334b));
        assertEq(words[8], bytes32(0x12c911abe545a1669fcbcdaeeede5352ee5a6743f59dbacdc0251b1e4c2f7b77));
        assertEq(LibCoupon.digest(words), 0xf32a9e86bb3d75c00acec45f208001679a5f2a7976c5ce3327b6de7cecb0781f);
    }

    function testSignContextSignsTheCouponTheOrchestratorSigns() external pure {
        SignedContextV1 memory coupon = signContext(SIGNER_KEY, vector());

        assertEq(coupon.signer, 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC);
        assertEq(
            coupon.signature,
            hex"452449c0ce920f0e30878832f19e55a7ad3c173dfb7074cef53cc1cc1db54cd43df1a26a92e096b59ba413f28cd2c0c1f4aa6276b56ea14eb612c07fcd76eb191b"
        );
    }
}

/// The order hash test vector: a claim order with a two-byte stand-in bytecode,
/// hashed as Raindex V6 hashes it (keccak256 of abi.encode(OrderV4)).
/// bridge-orchestrator/src/preflight.rs (`hashes_the_claim_order_as_raindex_does`)
/// and ui/src/lib/network.test.ts rebuild the same hash.
contract TestOrderHashVector is Test {
    function testTheOrderHashOfTheVector() external pure {
        IOV2[] memory inputs = new IOV2[](1);
        inputs[0] = IOV2(0x1234567890123456789012345678901234567890, HOLO_VAULT_ID);
        IOV2[] memory outputs = new IOV2[](1);
        outputs[0] = IOV2(address(MAINNET_HOT), HOLO_VAULT_ID);
        OrderV4 memory order = OrderV4(
            0xE3E064e3C2EEf66cb93dA8D8114F5084E92F48D6,
            EvaluableV4(RAINLANG_INTERPRETER, RAINLANG_STORE, hex"00ab"),
            inputs,
            outputs,
            CLAIM_ORDER_NONCE
        );

        assertEq(keccak256(abi.encode(order)), 0xaa24ef105ecbfc39695b240de6baeb09278fd4ebf75674b29bcbd2c7ef72ff0b);
    }
}

/// The claim test vector: the takeOrders4 call the website sends for the coupon
/// of the test vector, signed by anvil's third account, against the vector's
/// order. ui/src/lib/claim.test.ts pins this calldata.
contract TestClaimCalldataVector is Test, SignContext {
    function testTheClaimCalldataOfTheVector() external view {
        IOV2[] memory inputs = new IOV2[](1);
        inputs[0] = IOV2(0x1234567890123456789012345678901234567890, HOLO_VAULT_ID);
        IOV2[] memory outputs = new IOV2[](1);
        outputs[0] = IOV2(address(MAINNET_HOT), HOLO_VAULT_ID);
        OrderV4 memory order = OrderV4(
            0xE3E064e3C2EEf66cb93dA8D8114F5084E92F48D6,
            EvaluableV4(RAINLANG_INTERPRETER, RAINLANG_STORE, hex"00ab"),
            inputs,
            outputs,
            CLAIM_ORDER_NONCE
        );
        bytes32[] memory words = LibCoupon.words(
            0x1111111111111111111111111111111111111111,
            1.5e18,
            1_750_000_000 + 7 days,
            keccak256(abi.encode(order)),
            0xE3E064e3C2EEf66cb93dA8D8114F5084E92F48D6,
            address(RAINDEX),
            address(MAINNET_HOT),
            HOLO_VAULT_ID,
            bytes32(uint256(8496889498503184870230947373316602526857109467185425766089433217409414560631))
        );
        SignedContextV1[] memory signed = new SignedContextV1[](1);
        signed[0] = signContext(0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a, words);
        TakeOrderConfigV4[] memory orders = new TakeOrderConfigV4[](1);
        orders[0] = TakeOrderConfigV4(order, 0, 0, signed);
        Float amount = Float.wrap(words[1]);

        bytes memory calldata_ = abi.encodeCall(
            IRaindexV6.takeOrders4, (TakeOrdersConfigV5(amount, amount, CLAIM_IO_RATIO, true, orders, ""))
        );

        assertEq(
            signed[0].signature,
            hex"f3a686a6e1eccbfba52fbcde8a66bd2eca7bfd5b88bb326cb5486f6c4596e5bf7abe61d43b8e825201362259d527971715ee2d362460c97006ca29cb1355515a1b"
        );
        assertEq(keccak256(calldata_), 0x9c90a13c518aa17629ca92bb5947f54e0fcfb1c0ef65376c17d8ea02e7763522);
    }
}
