// SPDX-License-Identifier: CAL
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {
    OrderV4,
    IOV2,
    EvaluableV4,
    TakeOrderConfigV4,
    TakeOrdersConfigV5,
    SignedContextV1,
    Float
} from "raindex-interface-0.1.7/src/interface/IRaindexV6.sol";
import {HoloLockVault} from "src/HoloLockVault.sol";
import {HoloBridgeDeployer} from "src/HoloBridgeDeployer.sol";
import {
    RAINDEX,
    RAINDEX_SUBPARSER,
    RAINLANG_DEPLOYER,
    RAINLANG_INTERPRETER,
    RAINLANG_STORE,
    MAINNET_HOT,
    HOLO_VAULT_ID,
    MIN_LOCK_AMOUNT,
    CLAIM_IO_RATIO,
    CLAIM_ORDER_NONCE
} from "src/Constants.sol";
import {ClaimOrderScript, AdminInputs} from "script/ClaimOrderScript.sol";
import {CreateSafe} from "script/CreateSafe.s.sol";
import {SAFE_L2_SINGLETON, SAFE_FALLBACK_HANDLER, LibSafeSetup} from "script/Safe.sol";
import {LibCoupon} from "./lib/LibCoupon.sol";
import {ISafe, LibSafe, SAFE_PROXY_FACTORY, SAFE_SINGLETON} from "./rehearsal/Safe.sol";

contract OneSafeHarness is ClaimOrderScript {
    function acceptAdmin(address admin, AdminInputs memory given) external view {
        requireAdmin(admin, given);
    }

    function acceptSigner(address signer) external view {
        requireSigner(claimNetwork("mainnet"), signer);
    }
}

contract CreateSafeHarness is CreateSafe {
    function acceptOwners(address[] memory owners, uint256 threshold) external view {
        requireOwners(owners, threshold);
    }

    function found(address[] memory owners, uint256 threshold, uint256 saltNonce, address singleton)
        external
        view
        returns (address safe)
    {
        bytes memory initializer = LibSafeSetup.setupCall(owners, threshold);
        safe = LibSafeSetup.predict(singleton, initializer, saltNonce);
        requireFound(Plan(owners, threshold, saltNonce, singleton, initializer, safe));
    }
}

/// The launch shape, on a fork of Ethereum mainnet against the RaindexV6 and
/// Safe 1.4.1 contracts there: one Safe of three owners that needs two
/// signatures is the vault admin from the deploy's transaction and the claim
/// order's coupon signer.
contract TestOneSafeAdminAndSigner is Test {
    error InvalidSignature(uint256 i);

    uint256[] internal ownerKeys;
    address[] internal owners;
    ISafe internal safe;
    HoloBridgeDeployer internal bridge;
    HoloLockVault internal vault;
    bytes internal bytecode;
    address internal claimer = makeAddr("claimer");
    OneSafeHarness internal harness;

    function setUp() public {
        vm.createSelectFork(vm.envOr("RPC_URL_ETH", string("https://ethereum-rpc.publicnode.com")));
        for (uint256 i = 0; i < 3; i++) {
            (address owner, uint256 key) = makeAddrAndKey(string.concat("owner ", vm.toString(i)));
            owners.push(owner);
            ownerKeys.push(key);
        }
        safe = ISafe(SAFE_PROXY_FACTORY.createProxyWithNonce(SAFE_SINGLETON, LibSafe.setupCall(owners, 2), 1));
        harness = new OneSafeHarness();

        bytecode = RAINLANG_DEPLOYER.parse2(composed(address(safe)));
        bridge = new HoloBridgeDeployer(
            address(MAINNET_HOT),
            address(RAINDEX),
            HOLO_VAULT_ID,
            MIN_LOCK_AMOUNT,
            EvaluableV4(RAINLANG_INTERPRETER, RAINLANG_STORE, bytecode),
            CLAIM_ORDER_NONCE,
            address(safe)
        );
        vault = bridge.vault();

        address locker = makeAddr("locker");
        deal(address(MAINNET_HOT), locker, 100e18);
        vm.startPrank(locker);
        MAINNET_HOT.approve(address(vault), 100e18);
        vault.lock(100e18, keccak256("agent"));
        vm.stopPrank();
    }

    function composed(address validSigner) internal returns (bytes memory) {
        string[] memory compose = new string[](8);
        compose[0] = "node";
        compose[1] = "compose-rainlang.mjs";
        compose[2] = "--network";
        compose[3] = "mainnet";
        compose[4] = "--subparser";
        compose[5] = vm.toString(RAINDEX_SUBPARSER);
        compose[6] = "--signer";
        compose[7] = vm.toString(validSigner);
        return vm.ffi(compose);
    }

    function order() internal view returns (OrderV4 memory) {
        IOV2[] memory inputs = new IOV2[](1);
        inputs[0] = IOV2(address(bridge.inputToken()), HOLO_VAULT_ID);
        IOV2[] memory outputs = new IOV2[](1);
        outputs[0] = IOV2(address(MAINNET_HOT), HOLO_VAULT_ID);
        return OrderV4(
            address(vault),
            EvaluableV4(RAINLANG_INTERPRETER, RAINLANG_STORE, bytecode),
            inputs,
            outputs,
            CLAIM_ORDER_NONCE
        );
    }

    function words(uint256 amount, uint256 withdrawal) internal view returns (bytes32[] memory) {
        return LibCoupon.words(
            claimer,
            amount,
            block.timestamp + 7 days,
            keccak256(abi.encode(order())),
            address(vault),
            address(RAINDEX),
            address(MAINNET_HOT),
            HOLO_VAULT_ID,
            keccak256(abi.encode("withdrawal", withdrawal))
        );
    }

    function keys(uint256 a, uint256 b) internal view returns (uint256[] memory two) {
        two = new uint256[](2);
        (two[0], two[1]) = (ownerKeys[a], ownerKeys[b]);
    }

    /// A coupon for `c` carrying the signatures `signingKeys` make of its
    /// SafeMessage hash, in ascending owner order.
    function coupon(bytes32[] memory c, uint256[] memory signingKeys) internal view returns (SignedContextV1 memory) {
        return
            SignedContextV1(
                address(safe), c, LibSafe.couponSignature(vm, address(safe), signingKeys, LibCoupon.digest(c))
            );
    }

    function claimConfig(SignedContextV1 memory signed) internal view returns (TakeOrdersConfigV5 memory) {
        SignedContextV1[] memory contexts = new SignedContextV1[](1);
        contexts[0] = signed;
        TakeOrderConfigV4[] memory orders = new TakeOrderConfigV4[](1);
        orders[0] = TakeOrderConfigV4(order(), 0, 0, contexts);
        Float amount = Float.wrap(signed.context[1]);
        return TakeOrdersConfigV5(amount, amount, CLAIM_IO_RATIO, true, orders, "");
    }

    function claim(SignedContextV1 memory signed) internal {
        TakeOrdersConfigV5 memory config = claimConfig(signed);
        vm.prank(claimer);
        RAINDEX.takeOrders4(config);
    }

    function expectInvalidSignature(SignedContextV1 memory signed) internal {
        TakeOrdersConfigV5 memory config = claimConfig(signed);
        vm.prank(claimer);
        vm.expectRevert(abi.encodeWithSelector(InvalidSignature.selector, 0));
        RAINDEX.takeOrders4(config);
    }

    /// The deploy's checks take one Safe for both roles: as the admin, with its
    /// stated threshold and owners, and as the coupon signer.
    function testTheDeployChecksTakeOneSafeAsTheAdminAndTheCouponSigner() public view {
        harness.acceptAdmin(address(safe), AdminInputs(false, 2, owners));
        harness.acceptSigner(address(safe));
        assertEq(vault.admin(), address(safe));
        assertTrue(RAINDEX.orderExists(keccak256(abi.encode(order()))));
    }

    function testACouponCarryingTwoOwnerSignaturesClaims() public {
        claim(coupon(words(40e18, 1), keys(2, 0)));
        assertEq(MAINNET_HOT.balanceOf(claimer), 40e18);
        assertEq(vault.vaultBalance(), 60e18);
    }

    function testACouponCarryingOneOwnerSignatureFails() public {
        uint256[] memory one = new uint256[](1);
        one[0] = ownerKeys[1];
        expectInvalidSignature(coupon(words(40e18, 2), one));
    }

    function testACouponCarryingAnOwnersAndAStrangersSignatureFails() public {
        (, uint256 stranger) = makeAddrAndKey("not an owner");
        uint256[] memory two = keys(0, 0);
        two[1] = stranger;
        expectInvalidSignature(coupon(words(40e18, 3), two));
    }

    function testACouponCarryingOneOwnersSignatureTwiceFails() public {
        expectInvalidSignature(coupon(words(40e18, 4), keys(1, 1)));
    }

    /// A Safe transaction is signed over its SafeTx hash, a coupon over its
    /// SafeMessage hash: both EIP-712 under the Safe's domain, with different
    /// type hashes. The owner signatures of a coupon do not execute an admin
    /// call, and an admin call's signatures are no coupon.
    function testACouponsOwnerSignaturesDoNotExecuteAnAdminTransactionNorTheReverse() public {
        bytes memory call = abi.encodeCall(HoloLockVault.setMinLockAmount, (5e18));
        bytes32[] memory c = words(40e18, 5);
        bytes memory couponSignatures = coupon(c, keys(0, 1)).signature;

        vm.expectRevert(bytes("GS026"));
        safe.execTransaction(address(vault), 0, call, 0, 0, 0, 0, address(0), payable(address(0)), couponSignatures);
        assertEq(vault.minLockAmount(), MIN_LOCK_AMOUNT);

        bytes memory adminSignatures = LibSafe.sign(vm, keys(0, 1), LibSafe.transactionHash(safe, address(vault), call));
        expectInvalidSignature(SignedContextV1(address(safe), c, adminSignatures));

        assertTrue(
            LibSafe.transactionHash(safe, address(vault), call)
                != LibSafe.messageHash(1, address(safe), LibCoupon.digest(c))
        );
    }

    function testAnAdminCallNeedsTwoOwnerSignaturesAsBefore() public {
        bytes memory call = abi.encodeCall(HoloLockVault.setMinLockAmount, (5e18));
        uint256[] memory one = new uint256[](1);
        one[0] = ownerKeys[0];
        bytes memory signature = LibSafe.sign(vm, one, LibSafe.transactionHash(safe, address(vault), call));
        vm.expectRevert(bytes("GS020"));
        safe.execTransaction(address(vault), 0, call, 0, 0, 0, 0, address(0), payable(address(0)), signature);

        signature = LibSafe.sign(vm, keys(0, 2), LibSafe.transactionHash(safe, address(vault), call));
        assertTrue(
            safe.execTransaction(address(vault), 0, call, 0, 0, 0, 0, address(0), payable(address(0)), signature)
        );
        assertEq(vault.minLockAmount(), 5e18);
    }

    function testAnOwnerAloneNeitherAdministersNorClaims() public {
        OrderV4 memory claimOrder = order();
        vm.startPrank(owners[0]);
        vm.expectRevert("HoloLockVault: only admin");
        vault.adminWithdraw(1e18, owners[0]);
        vm.expectRevert("HoloLockVault: only admin");
        vault.removeOrder(claimOrder);
        vm.stopPrank();

        bytes32[] memory c = words(40e18, 6);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKeys[0], LibCoupon.digest(c));
        expectInvalidSignature(SignedContextV1(address(safe), c, abi.encodePacked(r, s, v)));
    }

    /// A Safe whose fallback handler is not the CompatibilityFallbackHandler
    /// refuses every coupon, so the deploy refuses it as the coupon signer.
    function testASafeWithoutTheFallbackHandlerIsRefusedAsTheCouponSigner() public {
        bytes memory noHandler =
            abi.encodeCall(ISafe.setup, (owners, 2, address(0), "", address(0), address(0), 0, payable(address(0))));
        address bare = SAFE_PROXY_FACTORY.createProxyWithNonce(SAFE_SINGLETON, noHandler, 2);
        vm.expectRevert(
            bytes(
                "VALID_SIGNER is a Safe whose fallback handler does not hash coupons as Safe's CompatibilityFallbackHandler does, so it would refuse every coupon: set that handler on it (docs/enable-multisig.md)"
            )
        );
        harness.acceptSigner(bare);
    }
}

/// CreateSafe on a fork of Ethereum mainnet: the address it predicts is the one
/// Safe's factory creates, and it finds that Safe again only while it is
/// unchanged.
contract TestCreateSafe is Test {
    CreateSafeHarness internal harness;
    address[] internal owners;

    function setUp() public {
        vm.createSelectFork(vm.envOr("RPC_URL_ETH", string("https://ethereum-rpc.publicnode.com")));
        harness = new CreateSafeHarness();
        for (uint256 i = 0; i < 3; i++) {
            owners.push(makeAddr(string.concat("owner ", vm.toString(i))));
        }
    }

    function testThePredictedAddressIsTheOneTheFactoryCreatesForSafeAndSafeL2() public {
        bytes memory initializer = LibSafeSetup.setupCall(owners, 2);
        address predicted = LibSafeSetup.predict(SAFE_SINGLETON, initializer, 42);
        assertEq(SAFE_PROXY_FACTORY.createProxyWithNonce(SAFE_SINGLETON, initializer, 42), predicted);
        assertEq(harness.found(owners, 2, 42, SAFE_SINGLETON), predicted);

        address predictedL2 = LibSafeSetup.predict(SAFE_L2_SINGLETON, initializer, 42);
        assertTrue(predictedL2 != predicted);
        assertEq(SAFE_PROXY_FACTORY.createProxyWithNonce(SAFE_L2_SINGLETON, initializer, 42), predictedL2);
        assertEq(harness.found(owners, 2, 42, SAFE_L2_SINGLETON), predictedL2);
        assertEq(address(uint160(uint256(vm.load(predictedL2, bytes32(0))))), SAFE_L2_SINGLETON);
    }

    function testAFoundSafeWhoseThresholdChangedIsRefused() public {
        bytes memory initializer = LibSafeSetup.setupCall(owners, 2);
        address created = SAFE_PROXY_FACTORY.createProxyWithNonce(SAFE_SINGLETON, initializer, 43);
        vm.prank(created);
        (bool ok,) = created.call(abi.encodeWithSignature("changeThreshold(uint256)", 3));
        assertTrue(ok);
        vm.expectRevert();
        harness.found(owners, 2, 43, SAFE_SINGLETON);
    }

    function testTheOwnersAreTwoToTwentyKeysNoneTwiceAndTheThresholdTwoOrMore() public {
        harness.acceptOwners(owners, 2);
        harness.acceptOwners(owners, 3);

        vm.expectRevert(
            bytes(
                "SAFE_THRESHOLD is how many owners must sign, 2 to the 3 SAFE_OWNERS lists, so that no one key acts as the Safe"
            )
        );
        harness.acceptOwners(owners, 1);
        vm.expectRevert(
            bytes(
                "SAFE_THRESHOLD is how many owners must sign, 2 to the 3 SAFE_OWNERS lists, so that no one key acts as the Safe"
            )
        );
        harness.acceptOwners(owners, 4);

        address[] memory one = new address[](1);
        one[0] = owners[0];
        vm.expectRevert(bytes("SAFE_OWNERS lists the Safe's owners, 2 to 20, separated by commas"));
        harness.acceptOwners(one, 1);

        address[] memory twice = new address[](2);
        (twice[0], twice[1]) = (owners[0], owners[0]);
        vm.expectRevert(bytes(string.concat("SAFE_OWNERS lists ", vm.toString(owners[0]), " twice")));
        harness.acceptOwners(twice, 2);

        address[] memory withContract = new address[](2);
        (withContract[0], withContract[1]) = (owners[0], address(SAFE_FALLBACK_HANDLER));
        vm.expectRevert(
            bytes(
                string.concat(
                    "SAFE_OWNERS lists ",
                    vm.toString(address(SAFE_FALLBACK_HANDLER)),
                    ", a contract: each owner signs as a key"
                )
            )
        );
        harness.acceptOwners(withContract, 2);
    }
}
