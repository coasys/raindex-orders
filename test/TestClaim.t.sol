// SPDX-License-Identifier: CAL
pragma solidity =0.8.25;

import {Test, stdError} from "forge-std/Test.sol";
import {
    OrderConfigV4,
    OrderV4,
    IOV2,
    EvaluableV4,
    TaskV2,
    TakeOrderConfigV4,
    TakeOrdersConfigV5,
    SignedContextV1,
    Float
} from "raindex-interface-0.1.7/src/interface/IRaindexV6.sol";
import {LibDecimalFloat} from "rain-math-float-0.2.1/src/lib/LibDecimalFloat.sol";
import {UnknownWord, SourceTotalOpsOverflow} from "rainlang-0.2.6/src/error/ErrParse.sol";
import {ClaimInputToken} from "src/ClaimInputToken.sol";
import {
    RAINDEX,
    RAINDEX_SUBPARSER,
    RAINLANG_DEPLOYER,
    RAINLANG_INTERPRETER,
    RAINLANG_STORE,
    MAINNET_HOT,
    HOLO_VAULT_ID,
    CLAIM_IO_RATIO,
    CLAIM_ORDER_NONCE
} from "src/Constants.sol";
import {LibCoupon} from "./lib/LibCoupon.sol";
import {SignContext} from "./lib/SignContext.sol";
import {ISafe, LibSafe, SAFE_PROXY_FACTORY, SAFE_SINGLETON} from "./rehearsal/Safe.sol";

/// The claim order on a fork of Ethereum mainnet, against the Raindex V6 and
/// Rainlang contracts Rain deployed there: 2 of 3 signers, two keys and a Safe,
/// and every way a claim must fail.
contract TestClaim is Test, SignContext {
    using LibDecimalFloat for Float;

    /// Raindex's refusal of signed context `i` whose signature its signer does
    /// not give (rainlang-interface LibContext).
    error InvalidSignature(uint256 i);

    uint256 internal constant THRESHOLD = 2;
    /// Signers 0 and 1 of the order's list are keys, signer 2 the Safe.
    uint256 internal constant SAFE_SIGNER = 2;

    address internal orderOwner = makeAddr("owner");
    address internal claimer = makeAddr("claimer");
    uint256[] internal signerKeys;
    /// The order's N signers: two keys, then a Safe of threshold 2.
    address[] internal signers;
    uint256[] internal safeOwnerKeys;
    ISafe internal safe;
    uint256 internal outsiderKey;
    ClaimInputToken internal inputToken;
    bytes internal bytecode;
    bytes32 internal orderHash;

    function setUp() public {
        vm.createSelectFork(vm.envOr("RPC_URL_ETH", string("https://ethereum-rpc.publicnode.com")));

        for (uint256 i = 1; i <= 2; i++) {
            (address signer, uint256 key) = makeAddrAndKey(string.concat("coupon signer ", vm.toString(i)));
            signers.push(signer);
            signerKeys.push(key);
        }
        address[] memory owners = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            (address owner, uint256 key) = makeAddrAndKey(string.concat("safe owner ", vm.toString(i)));
            owners[i] = owner;
            safeOwnerKeys.push(key);
        }
        safe = ISafe(SAFE_PROXY_FACTORY.createProxyWithNonce(SAFE_SINGLETON, LibSafe.setupCall(owners, 2), 31));
        signers.push(address(safe));
        (, outsiderKey) = makeAddrAndKey("not a coupon signer");
        inputToken = new ClaimInputToken();

        bytecode = RAINLANG_DEPLOYER.parse2(composed(signers, THRESHOLD));
        OrderV4 memory claimOrder = order();

        vm.startPrank(orderOwner);
        assertTrue(
            RAINDEX.addOrder4(
                OrderConfigV4(
                    claimOrder.evaluable,
                    claimOrder.validInputs,
                    claimOrder.validOutputs,
                    CLAIM_ORDER_NONCE,
                    bytes32(0),
                    ""
                ),
                new TaskV2[](0)
            )
        );
        orderHash = keccak256(abi.encode(claimOrder));
        assertTrue(RAINDEX.orderExists(orderHash));

        deal(address(MAINNET_HOT), orderOwner, 100e18);
        MAINNET_HOT.approve(address(RAINDEX), 100e18);
        RAINDEX.deposit4(
            address(MAINNET_HOT),
            HOLO_VAULT_ID,
            LibDecimalFloat.fromFixedDecimalLosslessPacked(100e18, 18),
            new TaskV2[](0)
        );
        vm.stopPrank();
        assertEq(vaultBalance(), 100e18);
    }

    /// The claim order as the vault adds it and a claim names it.
    function order() internal view returns (OrderV4 memory) {
        IOV2[] memory inputs = new IOV2[](1);
        inputs[0] = IOV2(address(inputToken), HOLO_VAULT_ID);
        IOV2[] memory outputs = new IOV2[](1);
        outputs[0] = IOV2(address(MAINNET_HOT), HOLO_VAULT_ID);
        return OrderV4(
            orderOwner, EvaluableV4(RAINLANG_INTERPRETER, RAINLANG_STORE, bytecode), inputs, outputs, CLAIM_ORDER_NONCE
        );
    }

    function composed(address[] memory list, uint256 threshold) internal returns (bytes memory) {
        string memory joined;
        for (uint256 i = 0; i < list.length; i++) {
            joined = string.concat(joined, i == 0 ? "" : ",", vm.toString(list[i]));
        }
        string[] memory compose = new string[](10);
        compose[0] = "node";
        compose[1] = "compose-rainlang.mjs";
        compose[2] = "--network";
        compose[3] = "mainnet";
        compose[4] = "--subparser";
        compose[5] = vm.toString(RAINDEX_SUBPARSER);
        compose[6] = "--signers";
        compose[7] = joined;
        compose[8] = "--threshold";
        compose[9] = vm.toString(threshold);
        return vm.ffi(compose);
    }

    function vaultBalance() internal view returns (uint256 balance) {
        (balance,) = RAINDEX.vaultBalance2(orderOwner, address(MAINNET_HOT), HOLO_VAULT_ID).toFixedDecimalLossy(18);
    }

    function coupon(uint256 amount, uint256 expiry, uint256 nonce) internal view returns (bytes32[] memory) {
        return LibCoupon.words(
            claimer,
            amount,
            expiry,
            orderHash,
            orderOwner,
            address(RAINDEX),
            address(MAINNET_HOT),
            HOLO_VAULT_ID,
            bytes32(nonce)
        );
    }

    function inAWeek() internal view returns (uint256) {
        return block.timestamp + 7 days;
    }

    /// Signer `signer` of the order's list signing `words`: a key, or the Safe
    /// through two of its owners.
    function seat(uint256 signer, bytes32[] memory words) internal view returns (SignedContextV1 memory) {
        if (signer == SAFE_SIGNER) return safeSigned(2, words);
        return signContext(signerKeys[signer], words);
    }

    /// The Safe signing `words` through its first `owners` owners.
    function safeSigned(uint256 owners, bytes32[] memory words) internal view returns (SignedContextV1 memory) {
        uint256[] memory keys = new uint256[](owners);
        for (uint256 i = 0; i < owners; i++) {
            keys[i] = safeOwnerKeys[i];
        }
        return SignedContextV1(
            address(safe), words, LibSafe.couponSignature(vm, address(safe), keys, LibCoupon.digest(words))
        );
    }

    /// A claim's two seats: signers `a` and `b` of the list, in that order.
    function seats(uint256 a, uint256 b, bytes32[] memory words) internal view returns (SignedContextV1[] memory s) {
        s = new SignedContextV1[](2);
        s[0] = seat(a, words);
        s[1] = seat(b, words);
    }

    /// The claim: takeOrders4 for exactly `amount` of HOT, as the website sends it.
    function claim(SignedContextV1[] memory signed, uint256 amount) internal {
        TakeOrderConfigV4[] memory orders = new TakeOrderConfigV4[](1);
        orders[0] = TakeOrderConfigV4(order(), 0, 0, signed);
        Float io = LibDecimalFloat.fromFixedDecimalLosslessPacked(amount, 18);
        vm.prank(claimer);
        RAINDEX.takeOrders4(TakeOrdersConfigV5(io, io, CLAIM_IO_RATIO, true, orders, ""));
    }

    function testTwoOfThreeKeysPay() public {
        claim(seats(0, 1, coupon(40e18, inAWeek(), 1)), 40e18);

        assertEq(MAINNET_HOT.balanceOf(claimer), 40e18);
        assertEq(vaultBalance(), 60e18);
    }

    function testAnyTwoOfTheThreePayInAnyOrder() public {
        claim(seats(1, 0, coupon(10e18, inAWeek(), 2)), 10e18);
        claim(seats(0, SAFE_SIGNER, coupon(10e18, inAWeek(), 3)), 10e18);
        claim(seats(SAFE_SIGNER, 1, coupon(10e18, inAWeek(), 4)), 10e18);

        assertEq(MAINNET_HOT.balanceOf(claimer), 30e18);
    }

    /// The Safe is one of the N: its seat carries what its EIP-1271
    /// isValidSignature accepts, its threshold of owners' signatures.
    function testASafeFillsOneSeat() public {
        claim(seats(SAFE_SIGNER, 0, coupon(40e18, inAWeek(), 5)), 40e18);

        assertEq(MAINNET_HOT.balanceOf(claimer), 40e18);
    }

    function testAllThreeSignaturesPay() public {
        bytes32[] memory words = coupon(40e18, inAWeek(), 6);
        SignedContextV1[] memory three = new SignedContextV1[](3);
        for (uint256 i = 0; i < 3; i++) {
            three[i] = seat(i, words);
        }
        claim(three, 40e18);

        assertEq(MAINNET_HOT.balanceOf(claimer), 40e18);
    }

    function testOneSignatureFails() public {
        SignedContextV1[] memory one = new SignedContextV1[](1);
        one[0] = seat(0, coupon(40e18, inAWeek(), 7));

        // The order reads seat 1, which the claim does not carry: an index past
        // the end of the signers column.
        vm.expectRevert(stdError.indexOOBError);
        claim(one, 40e18);
        assertEq(MAINNET_HOT.balanceOf(claimer), 0);
    }

    function testAClaimWithNoCouponFails() public {
        // The order reads seat 0, and a claim with no coupon has no signers column.
        vm.expectRevert(stdError.indexOOBError);
        claim(new SignedContextV1[](0), 40e18);
    }

    function testTheSameSignerTwiceFails() public {
        vm.expectRevert(bytes("Duplicate signer"));
        claim(seats(1, 1, coupon(40e18, inAWeek(), 8)), 40e18);
    }

    /// The Safe in two seats, each with its own valid signature, is one signer.
    function testTheSafeTwiceFails() public {
        bytes32[] memory words = coupon(40e18, inAWeek(), 9);
        SignedContextV1[] memory twice = new SignedContextV1[](2);
        twice[0] = safeSigned(2, words);
        twice[1] = safeSigned(3, words);

        vm.expectRevert(bytes("Duplicate signer"));
        claim(twice, 40e18);
    }

    function testASignerOutsideTheListFails() public {
        bytes32[] memory words = coupon(40e18, inAWeek(), 10);
        SignedContextV1[] memory signed = new SignedContextV1[](2);
        signed[0] = seat(0, words);
        signed[1] = signContext(outsiderKey, words);

        vm.expectRevert(bytes("Wrong signer"));
        claim(signed, 40e18);

        (signed[0], signed[1]) = (signed[1], signed[0]);
        vm.expectRevert(bytes("Wrong signer"));
        claim(signed, 40e18);
    }

    /// A seat naming a listed signer must carry that signer's signature, which
    /// Raindex checks before the order runs.
    function testASeatNamingAListedSignerItDidNotSignFails() public {
        bytes32[] memory words = coupon(40e18, inAWeek(), 11);
        SignedContextV1[] memory signed = seats(0, 1, words);
        signed[1].signature = signContext(outsiderKey, words).signature;

        vm.expectRevert(abi.encodeWithSelector(InvalidSignature.selector, 1));
        claim(signed, 40e18);
    }

    function testASafeSeatWithFewerOwnersThanItsThresholdFails() public {
        bytes32[] memory words = coupon(40e18, inAWeek(), 12);
        SignedContextV1[] memory signed = new SignedContextV1[](2);
        signed[0] = seat(0, words);
        signed[1] = safeSigned(1, words);

        vm.expectRevert(abi.encodeWithSelector(InvalidSignature.selector, 1));
        claim(signed, 40e18);
    }

    function testCouponsThatDifferBetweenSeatsFail() public {
        SignedContextV1[] memory signed = new SignedContextV1[](2);
        signed[0] = seat(0, coupon(40e18, inAWeek(), 13));
        signed[1] = seat(1, coupon(41e18, inAWeek(), 13));

        vm.expectRevert(bytes("Coupons differ"));
        claim(signed, 40e18);

        // Only the nonce differs: the second signer signed another withdrawal.
        signed[1] = seat(1, coupon(40e18, inAWeek(), 14));
        vm.expectRevert(bytes("Coupons differ"));
        claim(signed, 40e18);
    }

    function testACouponForAnotherOrderFails() public {
        bytes32[] memory words = coupon(40e18, inAWeek(), 15);
        words[3] = keccak256("another claim order");

        vm.expectRevert(bytes("Wrong order hash"));
        claim(seats(0, 1, words), 40e18);
    }

    function testTheSameNonceCannotBeClaimedTwice() public {
        claim(seats(0, 1, coupon(40e18, inAWeek(), 16)), 40e18);

        // Signed again, by another pair of signers and with another expiry.
        SignedContextV1[] memory again = seats(1, SAFE_SIGNER, coupon(40e18, inAWeek() + 1, 16));
        vm.expectRevert(bytes("Nonce already used"));
        claim(again, 40e18);
        assertEq(MAINNET_HOT.balanceOf(claimer), 40e18);
    }

    function testAnExpiredCouponFails() public {
        SignedContextV1[] memory signed = seats(0, 1, coupon(40e18, block.timestamp + 60, 17));
        vm.warp(block.timestamp + 60);

        vm.expectRevert(bytes("Order expired"));
        claim(signed, 40e18);
    }

    function testACouponForAnotherRecipientFails() public {
        bytes32[] memory words = coupon(40e18, inAWeek(), 18);
        words[0] = bytes32(uint256(uint160(makeAddr("someone else"))));

        vm.expectRevert(bytes("Wrong recipient"));
        claim(seats(0, 1, words), 40e18);
    }

    function testAClaimForLessThanTheCouponFails() public {
        SignedContextV1[] memory forty = seats(0, 1, coupon(40e18, inAWeek(), 19));

        vm.expectRevert(bytes("Wrong output amount"));
        claim(forty, 30e18);
    }

    function testAClaimForMoreThanTheVaultHoldsFails() public {
        SignedContextV1[] memory tooMuch = seats(0, 1, coupon(140e18, inAWeek(), 20));

        vm.expectRevert(bytes("Wrong output amount"));
        claim(tooMuch, 140e18);
    }

    /// The claim pays to the wei: the float the coupon carries converts back
    /// to the amount it was made from.
    function testAnOddNumberOfWeiPaysExactly() public {
        uint256 amount = 12345678901234567891;
        claim(seats(0, 1, coupon(amount, inAWeek(), 21)), amount);

        assertEq(MAINNET_HOT.balanceOf(claimer), amount);
        assertEq(vaultBalance(), 100e18 - amount);
    }

    function testTheClaimerPaysNoInputToken() public {
        claim(seats(0, 1, coupon(40e18, inAWeek(), 22)), 40e18);

        assertEq(inputToken.balanceOf(claimer), 0);
        assertEq(inputToken.balanceOf(address(RAINDEX)), 0);
    }

    /// The words st0x.attest's M-of-N example uses came after the Rainlang
    /// release deployed here, whose parser refuses them: the claim expression
    /// spells them in words it knows (compose-rainlang.mjs, signerChecks).
    function testTheDeployedParserRefusesBinaryInAndBinaryUnique() public {
        vm.expectRevert(abi.encodeWithSelector(UnknownWord.selector, "binary-unique"));
        RAINLANG_DEPLOYER.parse2("_: binary-unique(1 2);");
        vm.expectRevert(abi.encodeWithSelector(UnknownWord.selector, "binary-in"));
        RAINLANG_DEPLOYER.parse2("_: binary-in(1 1 2);");
    }

    /// The largest shapes compose-rainlang.mjs composes parse, and the smallest
    /// it refuses for their size the parser refuses too: the operation count the
    /// composer keeps is the parser's.
    function testTheComposersSizeLimitIsTheParsers() public {
        for (uint256 i = 0; i < 2; i++) {
            (uint256 n, uint256 m) = i == 0 ? (15, 3) : (8, 4);
            address[] memory list = new address[](n);
            for (uint256 j = 0; j < n; j++) {
                list[j] = address(uint160(j + 1));
            }
            RAINLANG_DEPLOYER.parse2(composed(list, m));
        }
        for (uint256 i = 0; i < 2; i++) {
            string[] memory command = new string[](4);
            command[0] = "node";
            command[1] = "test/lib/compose-unchecked.mjs";
            (command[2], command[3]) = i == 0 ? ("9", "4") : ("5", "5");
            bytes memory rainlang = vm.ffi(command);
            vm.expectRevert(SourceTotalOpsOverflow.selector);
            RAINLANG_DEPLOYER.parse2(rainlang);
        }
    }
}
