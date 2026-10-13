// SPDX-License-Identifier: CAL
pragma solidity =0.8.25;

import {Test, Vm, console2, stdError} from "forge-std/Test.sol";
import {
    OrderV4,
    IOV2,
    EvaluableV4,
    TakeOrderConfigV4,
    TakeOrdersConfigV5,
    SignedContextV1,
    Float
} from "raindex-interface-0.1.7/src/interface/IRaindexV6.sol";
import {IInterpreterV4} from "rainlang-interface-0.2.9/src/interface/IInterpreterV4.sol";
import {IInterpreterStoreV3} from "rainlang-interface-0.2.9/src/interface/IInterpreterStoreV3.sol";
import {LibDecimalFloat} from "rain-math-float-0.2.1/src/lib/LibDecimalFloat.sol";
import {HoloLockVault} from "src/HoloLockVault.sol";
import {
    RAINDEX,
    MAINNET_HOT,
    HOLO_VAULT_ID,
    MIN_LOCK_AMOUNT,
    CLAIM_IO_RATIO,
    CLAIM_ORDER_NONCE
} from "src/Constants.sol";
import {LibCoupon} from "../lib/LibCoupon.sol";
import {SignContext} from "../lib/SignContext.sol";
import {ISafe, LibSafe} from "./Safe.sol";

/// Proofs that test/fork-rehearsal.sh runs against its anvil fork of mainnet,
/// after it has deployed the bridge there. Skipped unless REHEARSAL is set.
abstract contract ForkRehearsal is Test, SignContext {
    using LibDecimalFloat for Float;

    event Lock(address indexed sender, uint256 amount, bytes32 indexed holochainAgent, uint256 lockId);

    bytes32 internal constant AGENT = keccak256("a Unyt agent");
    bytes32 internal constant ADMIN_CHANGED = keccak256("AdminChanged(address,address)");

    HoloLockVault internal vault;
    IInterpreterV4 internal interpreter;
    IInterpreterStoreV3 internal store;
    bytes internal bytecode;
    address internal inputToken;
    bytes32 internal orderHash;
    address internal locker = makeAddr("locker");
    address internal claimer = makeAddr("claimer");

    modifier onFork() {
        vm.skip(!vm.envOr("REHEARSAL", false));
        _;
    }

    function setUp() public {
        if (!vm.envOr("REHEARSAL", false)) return;
        vm.createSelectFork(vm.envString("REHEARSAL_RPC_URL"));
        vault = HoloLockVault(vm.envAddress("MAINNET_LOCK_VAULT_ADDRESS"));
        orderHash = vm.envBytes32("ORDER_HASH");
        interpreter = IInterpreterV4(vm.envAddress("PUBLIC_CLAIM_INTERPRETER"));
        store = IInterpreterStoreV3(vm.envAddress("PUBLIC_CLAIM_STORE"));
        bytecode = vm.envBytes("PUBLIC_CLAIM_BYTECODE");
        inputToken = vm.envAddress("PUBLIC_CLAIM_INPUT_TOKEN");
        require(keccak256(abi.encode(order())) == orderHash, "the deploy record does not rebuild ORDER_HASH");
    }

    function order() internal view returns (OrderV4 memory) {
        return OrderV4(
            address(vault),
            EvaluableV4(interpreter, store, bytecode),
            claimIO(inputToken),
            claimIO(address(MAINNET_HOT)),
            CLAIM_ORDER_NONCE
        );
    }

    function claimIO(address token) private pure returns (IOV2[] memory io) {
        io = new IOV2[](1);
        io[0] = IOV2(token, HOLO_VAULT_ID);
    }

    function fundLocker(uint256 amount) internal {
        deal(address(MAINNET_HOT), locker, amount);
        vm.prank(locker);
        MAINNET_HOT.approve(address(vault), amount);
    }

    function lock(uint256 amount) internal {
        fundLocker(amount);
        vm.prank(locker);
        vault.lock(amount, AGENT);
    }

    /// The nine context words the orchestrator signs for a withdrawal of `amount`
    /// to `claimer`. The nonce is the keccak of a 39-byte action hash, as the
    /// orchestrator's is, though its last 4 bytes are not a real DHT location.
    function context(uint256 amount, uint256 expiry, uint256 withdrawal) internal view returns (bytes32[] memory) {
        return contextFor(claimer, amount, expiry, withdrawal);
    }

    function contextFor(address recipient, uint256 amount, uint256 expiry, uint256 withdrawal)
        internal
        view
        returns (bytes32[] memory)
    {
        return LibCoupon.words(
            recipient,
            amount,
            expiry,
            orderHash,
            address(vault),
            address(RAINDEX),
            address(MAINNET_HOT),
            HOLO_VAULT_ID,
            keccak256(abi.encodePacked(hex"842924", bytes32(withdrawal), bytes4(0)))
        );
    }

    function inAWeek() internal view returns (uint256) {
        return block.timestamp + 7 days;
    }

    /// Key `i` of REHEARSAL_SIGNER_KEYS, the three keys the launch's claim order
    /// lists, in its order.
    function signerKey(uint256 i) internal view returns (uint256) {
        return vm.envUint("REHEARSAL_SIGNER_KEYS", ",")[i];
    }

    /// Seat `i` of a claim: `c` signed by key `i` of REHEARSAL_SIGNER_KEYS.
    function keySeat(uint256 i, bytes32[] memory c) internal view returns (SignedContextV1 memory) {
        return signContext(signerKey(i), c);
    }

    function seats(SignedContextV1 memory a) internal pure returns (SignedContextV1[] memory s) {
        s = new SignedContextV1[](1);
        s[0] = a;
    }

    function seats(SignedContextV1 memory a, SignedContextV1 memory b)
        internal
        pure
        returns (SignedContextV1[] memory s)
    {
        s = new SignedContextV1[](2);
        (s[0], s[1]) = (a, b);
    }

    function seats(SignedContextV1 memory a, SignedContextV1 memory b, SignedContextV1 memory c)
        internal
        pure
        returns (SignedContextV1[] memory s)
    {
        s = new SignedContextV1[](3);
        (s[0], s[1], s[2]) = (a, b, c);
    }

    /// The claim as the website sends it: takeOrders4 for exactly the coupon's
    /// amount, every seat a signed context, in order.
    function claimConfig(SignedContextV1[] memory signed) internal view returns (TakeOrdersConfigV5 memory) {
        TakeOrderConfigV4[] memory orders = new TakeOrderConfigV4[](1);
        orders[0] = TakeOrderConfigV4(order(), 0, 0, signed);
        Float amount = Float.wrap(signed[0].context[1]);
        return TakeOrdersConfigV5(amount, amount, CLAIM_IO_RATIO, true, orders, "");
    }

    function claim(SignedContextV1[] memory signed) internal {
        TakeOrdersConfigV5 memory config = claimConfig(signed);
        vm.prank(claimer);
        RAINDEX.takeOrders4(config);
    }

    /// `signer1,signature1,...,signerK,signatureK,c0..c8` as the orchestrator
    /// writes a coupon, the words as decimal numbers.
    function serialized(SignedContextV1[] memory signed) internal pure returns (string memory text) {
        for (uint256 i = 0; i < signed.length; i++) {
            text = string.concat(
                text, i == 0 ? "" : ",", vm.toString(signed[i].signer), ",", vm.toString(signed[i].signature)
            );
        }
        for (uint256 i = 0; i < signed[0].context.length; i++) {
            text = string.concat(text, ",", vm.toString(uint256(signed[0].context[i])));
        }
    }

    /// The vault's admin changed once since `fromBlock`: from `bridge`, the
    /// HoloBridgeDeployer, to `admin`, inside the deploy's one transaction.
    function assertHandedOverOnce(uint256 fromBlock, address bridge, address admin) internal {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = ADMIN_CHANGED;
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(fromBlock, block.number, address(vault), topics);
        assertEq(logs.length, 1, "AdminChanged events");
        assertEq(address(uint160(uint256(logs[0].topics[1]))), bridge, "from the HoloBridgeDeployer");
        assertEq(address(uint160(uint256(logs[0].topics[2]))), admin, "to the admin");
        assertEq(logs[0].blockNumber, fromBlock, "in the deploy's block");
    }

    function assertOnlyAdmin(address account) internal {
        OrderV4 memory claimOrder = order();
        vm.startPrank(account);
        vm.expectRevert("HoloLockVault: only admin");
        vault.setAdmin(account);
        vm.expectRevert("HoloLockVault: only admin");
        vault.adminWithdraw(1e18, account);
        vm.expectRevert("HoloLockVault: only admin");
        vault.setMinLockAmount(0);
        vm.expectRevert("HoloLockVault: only admin");
        vault.removeOrder(claimOrder);
        vm.stopPrank();
    }

    /// `data` sent to the vault by `safe`, signed by `keys` of its owners.
    function throughSafe(ISafe safe, uint256[] memory keys, bytes memory data) internal returns (bool) {
        bytes memory signatures = LibSafe.sign(vm, keys, LibSafe.transactionHash(safe, address(vault), data));
        return safe.execTransaction(address(vault), 0, data, 0, 0, 0, 0, address(0), payable(address(0)), signatures);
    }

    function assertTwoOfThree(address safe) internal view {
        assertEq(ISafe(safe).getThreshold(), 2);
        assertEq(ISafe(safe).getOwners().length, 3);
    }

    /// The vault's admin Safe acts with two owner signatures and not with one.
    function assertSafeAdministers(ISafe safe, uint256[] memory twoOwnerKeys) internal {
        bytes memory call = abi.encodeCall(HoloLockVault.setMinLockAmount, (3e18));
        uint256 before = vault.minLockAmount();
        uint256[] memory one = new uint256[](1);
        one[0] = twoOwnerKeys[0];
        bytes memory signature = LibSafe.sign(vm, one, LibSafe.transactionHash(safe, address(vault), call));
        vm.expectRevert(bytes("GS020"));
        safe.execTransaction(address(vault), 0, call, 0, 0, 0, 0, address(0), payable(address(0)), signature);
        assertEq(vault.minLockAmount(), before);

        assertTrue(throughSafe(safe, twoOwnerKeys, call));
        assertEq(vault.minLockAmount(), 3e18);
    }
}

/// The bridge as deploy-mainnet.sh launches it: a Safe of three owners that
/// needs two signatures is the vault admin from the deploy's one transaction,
/// and the claim order takes coupons signed by 2 of 3 keys, REHEARSAL_SIGNER_KEYS.
contract LaunchRehearsal is ForkRehearsal {
    function testTheVaultHoldsWhatTheDeployRecordSays() external onFork {
        assertEq(address(vault.token()), address(MAINNET_HOT));
        assertEq(address(vault.orderbook()), address(RAINDEX));
        assertEq(vault.vaultId(), HOLO_VAULT_ID);
        assertEq(vault.minLockAmount(), MIN_LOCK_AMOUNT);
        assertTrue(RAINDEX.orderExists(orderHash));
    }

    function testALockLandsInTheVaultAndEmitsLock() external onFork {
        uint256 before = vault.vaultBalance();
        uint256 lockId = vault.lockNonce();

        fundLocker(250e18);
        vm.expectEmit(true, true, false, true, address(vault));
        emit Lock(locker, 250e18, AGENT, lockId);
        vm.prank(locker);
        vault.lock(250e18, AGENT);

        assertEq(vault.vaultBalance(), before + 250e18);
    }

    function testACouponSignedByTwoOfTheThreeKeysClaimsTheLockedHot() external onFork {
        lock(100e18);
        uint256 before = vault.vaultBalance();
        bytes32[] memory c = context(40e18, inAWeek(), 1);

        claim(seats(keySeat(0, c), keySeat(1, c)));

        assertEq(MAINNET_HOT.balanceOf(claimer), 40e18);
        assertEq(vault.vaultBalance(), before - 40e18);
    }

    function testAnyTwoOfTheThreeClaimInAnyOrder() external onFork {
        lock(100e18);
        bytes32[] memory c = context(10e18, inAWeek(), 2);
        claim(seats(keySeat(2, c), keySeat(0, c)));
        c = context(10e18, inAWeek(), 3);
        claim(seats(keySeat(1, c), keySeat(2, c)));

        assertEq(MAINNET_HOT.balanceOf(claimer), 20e18);
    }

    function testACouponSignedByAllThreeClaims() external onFork {
        lock(100e18);
        bytes32[] memory c = context(40e18, inAWeek(), 4);

        claim(seats(keySeat(0, c), keySeat(1, c), keySeat(2, c)));

        assertEq(MAINNET_HOT.balanceOf(claimer), 40e18);
    }

    function testACouponSignedByOneKeyFails() external onFork {
        lock(100e18);

        vm.expectRevert(stdError.indexOOBError);
        claim(seats(keySeat(0, context(40e18, inAWeek(), 5))));
    }

    function testOneKeyInBothSeatsFails() external onFork {
        lock(100e18);
        bytes32[] memory c = context(40e18, inAWeek(), 6);

        vm.expectRevert(bytes("Duplicate signer"));
        claim(seats(keySeat(1, c), keySeat(1, c)));
    }

    function testAKeyTheOrderDoesNotListFails() external onFork {
        lock(100e18);
        (, uint256 otherKey) = makeAddrAndKey("not a coupon signer");
        bytes32[] memory c = context(40e18, inAWeek(), 7);

        vm.expectRevert(bytes("Wrong signer"));
        claim(seats(keySeat(0, c), signContext(otherKey, c)));
    }

    function testSeatsSigningDifferentCouponsFail() external onFork {
        lock(100e18);
        bytes32[] memory c = context(40e18, inAWeek(), 8);

        vm.expectRevert(bytes("Coupons differ"));
        claim(seats(keySeat(0, c), keySeat(1, context(80e18, inAWeek(), 8))));
    }

    function testASecondClaimWithTheSameNonceFails() external onFork {
        lock(100e18);
        bytes32[] memory c = context(40e18, inAWeek(), 9);
        claim(seats(keySeat(0, c), keySeat(1, c)));

        c = context(40e18, inAWeek() + 1, 9);
        vm.expectRevert(bytes("Nonce already used"));
        claim(seats(keySeat(1, c), keySeat(2, c)));
    }

    function testAnExpiredCouponFails() external onFork {
        lock(100e18);
        bytes32[] memory c = context(40e18, block.timestamp + 60, 10);
        SignedContextV1[] memory coupon = seats(keySeat(0, c), keySeat(1, c));
        vm.warp(block.timestamp + 60);

        vm.expectRevert(bytes("Order expired"));
        claim(coupon);
    }

    /// The admin Safe held the vault from the deploy's block: the one
    /// AdminChanged is the HoloBridgeDeployer handing it over in that block.
    function testTheAdminIsTheSafeFromTheDeploysBlockAndNoKeyEverHeldIt() external onFork {
        address safe = vm.envAddress("ADMIN_SAFE");
        assertEq(vault.admin(), safe);
        assertTwoOfThree(safe);
        assertHandedOverOnce(vm.envUint("REHEARSAL_DEPLOY_BLOCK"), vm.envAddress("HOLO_BRIDGE_DEPLOYER"), safe);
    }

    function testNeitherTheDeployerNorTheDeployerContractNorAnOwnerAloneAdministers() external onFork {
        lock(10e18);
        assertOnlyAdmin(vm.envAddress("REHEARSAL_DEPLOYER"));
        assertOnlyAdmin(vm.envAddress("HOLO_BRIDGE_DEPLOYER"));
        address[] memory owners = ISafe(vm.envAddress("ADMIN_SAFE")).getOwners();
        for (uint256 i = 0; i < owners.length; i++) {
            assertOnlyAdmin(owners[i]);
        }
    }

    function testTheAdminSafeActsWithTwoOwnerSignaturesAndNotWithOne() external onFork {
        assertSafeAdministers(ISafe(vm.envAddress("ADMIN_SAFE")), vm.envUint("REHEARSAL_ADMIN_OWNER_KEYS", ","));
    }
}

/// The bridge after the rotation of its claim order: the vault admin is a Safe
/// of three owners that needs two signatures, and the claim order takes coupons
/// signed by 2 of keys 0 and 1 of REHEARSAL_SIGNER_KEYS and SIGNER_SAFE, a Safe
/// of three owners that needs two signatures. Key 2 is no longer listed.
contract SafeSignerRehearsal is ForkRehearsal {
    error InvalidSignature(uint256 i);

    function safe() private view returns (address) {
        return vm.envAddress("SIGNER_SAFE");
    }

    function safeSeat(bytes32[] memory c, uint256[] memory ownerKeys) private view returns (SignedContextV1 memory) {
        return SignedContextV1(safe(), c, LibSafe.couponSignature(vm, safe(), ownerKeys, LibCoupon.digest(c)));
    }

    function safeSeat(bytes32[] memory c, string memory ownerKeys) private view returns (SignedContextV1 memory) {
        return safeSeat(c, vm.envUint(ownerKeys, ","));
    }

    function oneOwnerAndAStranger() private returns (uint256[] memory keys) {
        (, uint256 stranger) = makeAddrAndKey("not an owner");
        keys = new uint256[](2);
        (keys[0], keys[1]) = (vm.envUint("REHEARSAL_SIGNER_ONE_OWNER_KEY"), stranger);
    }

    /// A claim whose seat 1, the Safe's, carries a signature the Safe refuses.
    function expectSafeSeatRefused(bytes32[] memory c, SignedContextV1 memory safeSeat_) private {
        lock(100e18);
        vm.expectRevert(abi.encodeWithSelector(InvalidSignature.selector, 1));
        claim(seats(keySeat(0, c), safeSeat_));
    }

    function testTheAdminIsASafeWhoseOwnersActedThroughIt() external onFork {
        address admin = vm.envAddress("ADMIN_SAFE");
        assertEq(vault.admin(), admin);
        assertTwoOfThree(admin);
        assertEq(vault.minLockAmount(), vm.envUint("REHEARSAL_MIN_LOCK_AMOUNT"));
        assertOnlyAdmin(ISafe(admin).getOwners()[0]);
    }

    function testTheRotationReplacedTheClaimOrder() external onFork {
        assertTwoOfThree(safe());
        assertTrue(RAINDEX.orderExists(orderHash));
        assertFalse(RAINDEX.orderExists(vm.envBytes32("PREVIOUS_ORDER_HASH")));
    }

    function testAKeyAndTheSafeWithTwoOwnerSignaturesClaim() external onFork {
        lock(100e18);
        uint256 before = vault.vaultBalance();
        bytes32[] memory c = context(40e18, inAWeek(), 20);

        claim(seats(keySeat(0, c), safeSeat(c, "REHEARSAL_SIGNER_OWNER_KEYS")));

        assertEq(MAINNET_HOT.balanceOf(claimer), 40e18);
        assertEq(vault.vaultBalance(), before - 40e18);
    }

    function testTheSafeInSeatZeroAndTheTwoKeysClaim() external onFork {
        lock(100e18);
        bytes32[] memory c = context(10e18, inAWeek(), 21);
        claim(seats(safeSeat(c, "REHEARSAL_SIGNER_OWNER_KEYS"), keySeat(1, c)));
        c = context(10e18, inAWeek(), 22);
        claim(seats(keySeat(1, c), keySeat(0, c)));

        assertEq(MAINNET_HOT.balanceOf(claimer), 20e18);
    }

    function testTheSafeWithOneOwnerSignatureFails() external onFork {
        bytes32[] memory c = context(40e18, inAWeek(), 23);
        expectSafeSeatRefused(c, safeSeat(c, "REHEARSAL_SIGNER_ONE_OWNER_KEY"));
    }

    function testTheSafeWithAnOwnersAndANonOwnersSignatureFails() external onFork {
        bytes32[] memory c = context(40e18, inAWeek(), 24);
        expectSafeSeatRefused(c, safeSeat(c, oneOwnerAndAStranger()));
    }

    function testTheSafeWithOneOwnersSignatureTwiceFails() external onFork {
        uint256[] memory keys = new uint256[](2);
        keys[0] = vm.envUint("REHEARSAL_SIGNER_ONE_OWNER_KEY");
        keys[1] = keys[0];
        bytes32[] memory c = context(40e18, inAWeek(), 25);
        expectSafeSeatRefused(c, safeSeat(c, keys));
    }

    function testTheOwnersOfTheAdminSafeCannotSignForTheSignerSafe() external onFork {
        bytes32[] memory c = context(40e18, inAWeek(), 26);
        expectSafeSeatRefused(c, safeSeat(c, "REHEARSAL_ADMIN_OWNER_KEYS"));
    }

    function testTheSafeInBothSeatsFails() external onFork {
        lock(100e18);
        bytes32[] memory c = context(40e18, inAWeek(), 27);
        SignedContextV1 memory seat = safeSeat(c, "REHEARSAL_SIGNER_OWNER_KEYS");

        vm.expectRevert(bytes("Duplicate signer"));
        claim(seats(seat, seat));
    }

    function testAKeyThePreviousOrderListedAndThisOneDoesNotFails() external onFork {
        lock(100e18);
        bytes32[] memory c = context(40e18, inAWeek(), 28);

        vm.expectRevert(bytes("Wrong signer"));
        claim(seats(keySeat(0, c), keySeat(2, c)));
    }

    /// Coupons for the website's coupon-status proof, in the form the
    /// orchestrator writes them, each paying REHEARSAL_WEBSITE_CLAIMER, and the
    /// claim of WEBSITE_ACCEPTED as calldata for the rehearsal to send.
    /// WEBSITE_ACCEPTED and WEBSITE_UNCLAIMED_* the order takes; WEBSITE_REFUSED_*
    /// it refuses, as the website must read them.
    function testPrintsCouponsForTheWebsite() external onFork {
        address recipient = vm.envAddress("REHEARSAL_WEBSITE_CLAIMER");
        bytes32[] memory c = contextFor(recipient, 40e18, inAWeek(), 100);
        SignedContextV1 memory key0 = keySeat(0, c);
        SignedContextV1 memory safeOk = safeSeat(c, "REHEARSAL_SIGNER_OWNER_KEYS");
        SignedContextV1[] memory accepted = seats(key0, safeOk);
        // Seat 1 names key 1, a listed signer, and carries another key's signature.
        (, uint256 otherKey) = makeAddrAndKey("not a coupon signer");
        SignedContextV1 memory forged = signContext(otherKey, c);
        forged.signer = vm.addr(signerKey(1));

        console2.log(string.concat("WEBSITE_ACCEPTED=", serialized(accepted)));
        console2.log(
            string.concat(
                "WEBSITE_REFUSED_ONE_OWNER=", serialized(seats(key0, safeSeat(c, "REHEARSAL_SIGNER_ONE_OWNER_KEY")))
            )
        );
        console2.log(
            string.concat("WEBSITE_REFUSED_NON_OWNER=", serialized(seats(key0, safeSeat(c, oneOwnerAndAStranger()))))
        );
        console2.log(string.concat("WEBSITE_REFUSED_ONE_SEAT=", serialized(seats(key0))));
        console2.log(string.concat("WEBSITE_REFUSED_KEY_TWICE=", serialized(seats(key0, key0))));
        console2.log(string.concat("WEBSITE_REFUSED_UNLISTED=", serialized(seats(key0, keySeat(2, c)))));
        console2.log(string.concat("WEBSITE_REFUSED_FORGED=", serialized(seats(key0, forged))));
        bytes32[] memory other = contextFor(recipient, 10e18, inAWeek(), 101);
        console2.log(string.concat("WEBSITE_UNCLAIMED_KEYS=", serialized(seats(keySeat(1, other), keySeat(0, other)))));
        other = contextFor(recipient, 10e18, inAWeek(), 102);
        console2.log(
            string.concat(
                "WEBSITE_UNCLAIMED_THREE_SEATS=",
                serialized(seats(safeSeat(other, "REHEARSAL_SIGNER_OWNER_KEYS"), keySeat(0, other), keySeat(1, other)))
            )
        );
        console2.log(
            string.concat("CLAIM_CALLDATA=", vm.toString(abi.encodeCall(RAINDEX.takeOrders4, (claimConfig(accepted)))))
        );

        // On this test's own fork: the order refuses the forged seat and takes the
        // accepted coupon.
        lock(100e18);
        TakeOrdersConfigV5 memory config = claimConfig(seats(key0, forged));
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(InvalidSignature.selector, 1));
        RAINDEX.takeOrders4(config);
        config = claimConfig(accepted);
        vm.prank(recipient);
        RAINDEX.takeOrders4(config);
        assertEq(MAINNET_HOT.balanceOf(recipient), 40e18);
    }
}

/// The bridge deployed with UNSAFE_ALLOW_SINGLE_KEY_ADMIN=yes: a key is the
/// vault admin, and the claim order lists keys 0 and 1 of REHEARSAL_SIGNER_KEYS
/// and SIGNER_SAFE, 2 of them signing each coupon, from the deploy.
contract SingleKeyAdminRehearsal is ForkRehearsal {
    function testTheAdminIsTheKeyFromTheDeploysBlock() external onFork {
        address admin = vm.envAddress("ADMIN_ADDRESS");
        assertEq(vault.admin(), admin);
        // A key, with or without an EIP-7702 delegation, as anvil's accounts carry one on mainnet.
        assertTrue(admin.code.length == 0 || (admin.code.length == 23 && admin.code[0] == 0xef), "the admin is a key");
        assertHandedOverOnce(vm.envUint("REHEARSAL_DEPLOY_BLOCK"), vm.envAddress("HOLO_BRIDGE_DEPLOYER"), admin);
        assertOnlyAdmin(vm.envAddress("REHEARSAL_DEPLOYER"));
        assertOnlyAdmin(vm.envAddress("HOLO_BRIDGE_DEPLOYER"));
    }

    function testTheSignerSafeAndAKeyClaim() external onFork {
        lock(100e18);
        address safe = vm.envAddress("SIGNER_SAFE");
        bytes32[] memory c = context(40e18, inAWeek(), 30);
        uint256[] memory keys = vm.envUint("REHEARSAL_SIGNER_OWNER_KEYS", ",");

        claim(
            seats(SignedContextV1(safe, c, LibSafe.couponSignature(vm, safe, keys, LibCoupon.digest(c))), keySeat(1, c))
        );

        assertEq(MAINNET_HOT.balanceOf(claimer), 40e18);
    }

    function testTheSignerSafeAloneFails() external onFork {
        lock(100e18);
        address safe = vm.envAddress("SIGNER_SAFE");
        bytes32[] memory c = context(40e18, inAWeek(), 31);
        uint256[] memory keys = vm.envUint("REHEARSAL_SIGNER_OWNER_KEYS", ",");
        // Signed before expectRevert: the Safe's signature reads the Safe.
        SignedContextV1[] memory one =
            seats(SignedContextV1(safe, c, LibSafe.couponSignature(vm, safe, keys, LibCoupon.digest(c))));

        vm.expectRevert(stdError.indexOOBError);
        claim(one);
    }
}
