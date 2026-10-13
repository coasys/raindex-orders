// SPDX-License-Identifier: CAL
pragma solidity =0.8.25;

import {Test, stdError} from "forge-std/Test.sol";
import {
    OrderConfigV4,
    OrderV4,
    TakeOrderConfigV4,
    TakeOrdersConfigV5,
    SignedContextV1,
    Float
} from "raindex-interface-0.1.7/src/interface/IRaindexV6.sol";
import {LibDecimalFloat} from "rain-math-float-0.2.1/src/lib/LibDecimalFloat.sol";
import {HoloLockVault} from "src/HoloLockVault.sol";
import {ClaimInputToken} from "src/ClaimInputToken.sol";
import {MockHOT} from "src/test/MockHOT.sol";
import {RAINDEX, HOLO_VAULT_ID, MIN_LOCK_AMOUNT, CLAIM_IO_RATIO} from "src/Constants.sol";
import {ClaimOrderScript, ClaimNetwork, ClaimSigners} from "script/ClaimOrderScript.sol";
import {LibCoupon} from "./lib/LibCoupon.sol";
import {SignContext} from "./lib/SignContext.sol";
import {ISafe, LibSafe, SAFE_PROXY_FACTORY, SAFE_SINGLETON} from "./rehearsal/Safe.sol";

/// The deploy scripts' order building, callable from a test.
contract ClaimOrderHarness is ClaimOrderScript {
    function checkRainV6() external view {
        requireRainV6();
    }

    function acceptSigners(ClaimSigners memory signers) external view {
        requireSigners(claimNetwork("base-sepolia"), signers);
    }

    function config(address token, address inputToken, ClaimSigners memory signers)
        external
        returns (OrderConfigV4 memory)
    {
        return claimOrderConfig(claimNetwork("base-sepolia"), token, inputToken, signers);
    }

    function order(address vault, address token, address inputToken, bytes memory bytecode)
        external
        pure
        returns (OrderV4 memory)
    {
        return claimOrder(vault, token, inputToken, bytecode);
    }
}

/// The TestNet bridge on a fork of Base Sepolia, where Rain deployed the same
/// Raindex V6 and Rainlang release as on mainnet: a mock HOT, the lock vault and
/// its claim order for 2 of 3 signers, two keys and a Safe, deployed as
/// deploy-base-sepolia.sh deploys them, then locks and claims.
contract TestClaimBaseSepolia is Test, SignContext {
    using LibDecimalFloat for Float;

    bytes32 internal constant AGENT = keccak256("a Unyt agent");
    /// Signers 0 and 1 of the order's list are keys, signer 2 the Safe.
    uint256 internal constant SAFE_SIGNER = 2;

    event Lock(address indexed sender, uint256 amount, bytes32 indexed holochainAgent, uint256 lockId);

    ClaimOrderHarness internal scripts;
    address internal admin = makeAddr("admin");
    address internal locker = makeAddr("locker");
    address internal claimer = makeAddr("claimer");
    uint256[] internal signerKeys;
    uint256[] internal safeOwnerKeys;
    ISafe internal safe;
    MockHOT internal token;
    ClaimInputToken internal inputToken;
    HoloLockVault internal vault;
    bytes internal bytecode;
    bytes32 internal orderHash;

    function setUp() public {
        vm.createSelectFork(vm.envOr("RPC_URL_BASE_SEPOLIA", string("https://base-sepolia-rpc.publicnode.com")));
        assertEq(block.chainid, 84532, "the fork is not Base Sepolia");
        // Deployed on the fork: a contract made before the fork is selected is not there.
        scripts = new ClaimOrderHarness();
        scripts.checkRainV6();

        ClaimSigners memory signers = ClaimSigners(new address[](3), 2);
        for (uint256 i = 0; i < 2; i++) {
            (address signer, uint256 key) = makeAddrAndKey(string.concat("coupon signer ", vm.toString(i)));
            signers.list[i] = signer;
            signerKeys.push(key);
        }
        address[] memory owners = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            (address owner, uint256 key) = makeAddrAndKey(string.concat("safe owner ", vm.toString(i)));
            owners[i] = owner;
            safeOwnerKeys.push(key);
        }
        safe = ISafe(SAFE_PROXY_FACTORY.createProxyWithNonce(SAFE_SINGLETON, LibSafe.setupCall(owners, 2), 31));
        signers.list[SAFE_SIGNER] = address(safe);
        scripts.acceptSigners(signers);

        token = new MockHOT();
        inputToken = new ClaimInputToken();
        vault = new HoloLockVault(address(token), address(RAINDEX), HOLO_VAULT_ID, admin, MIN_LOCK_AMOUNT);

        OrderConfigV4 memory config = scripts.config(address(token), address(inputToken), signers);
        vm.prank(admin);
        assertTrue(vault.addOrder(config));
        bytecode = config.evaluable.bytecode;
        orderHash = keccak256(abi.encode(claimOrder()));
        assertTrue(RAINDEX.orderExists(orderHash));
    }

    function claimOrder() internal view returns (OrderV4 memory) {
        return scripts.order(address(vault), address(token), address(inputToken), bytecode);
    }

    function lock(uint256 amount) internal {
        token.mint(locker, amount);
        vm.startPrank(locker);
        token.approve(address(vault), amount);
        vault.lock(amount, AGENT);
        vm.stopPrank();
    }

    function coupon(uint256 amount, uint256 nonce) internal view returns (bytes32[] memory) {
        return LibCoupon.words(
            claimer,
            amount,
            block.timestamp + 7 days,
            orderHash,
            address(vault),
            address(RAINDEX),
            address(token),
            HOLO_VAULT_ID,
            bytes32(nonce)
        );
    }

    /// Signer `signer` of the order's list signing `words`: a key, or the Safe
    /// through two of its owners, who sign its SafeMessage on Base Sepolia.
    function seat(uint256 signer, bytes32[] memory words) internal view returns (SignedContextV1 memory) {
        if (signer != SAFE_SIGNER) return signContext(signerKeys[signer], words);
        uint256[] memory keys = new uint256[](2);
        (keys[0], keys[1]) = (safeOwnerKeys[0], safeOwnerKeys[1]);
        bytes32 hash = LibSafe.messageHash(block.chainid, address(safe), LibCoupon.digest(words));
        return SignedContextV1(address(safe), words, LibSafe.sign(vm, keys, hash));
    }

    function seats(uint256 a, uint256 b, bytes32[] memory words) internal view returns (SignedContextV1[] memory s) {
        s = new SignedContextV1[](2);
        s[0] = seat(a, words);
        s[1] = seat(b, words);
    }

    /// The claim as the website sends it: takeOrders4 for exactly `amount` of HOT.
    function claimConfig(SignedContextV1[] memory signed, uint256 amount)
        internal
        view
        returns (TakeOrdersConfigV5 memory)
    {
        TakeOrderConfigV4[] memory orders = new TakeOrderConfigV4[](1);
        orders[0] = TakeOrderConfigV4(claimOrder(), 0, 0, signed);
        Float io = LibDecimalFloat.fromFixedDecimalLosslessPacked(amount, 18);
        return TakeOrdersConfigV5(io, io, CLAIM_IO_RATIO, true, orders, "");
    }

    function claim(SignedContextV1[] memory signed, uint256 amount) internal {
        TakeOrdersConfigV5 memory config = claimConfig(signed, amount);
        vm.prank(claimer);
        RAINDEX.takeOrders4(config);
    }

    function claimFails(SignedContextV1[] memory signed, uint256 amount, bytes memory reason) internal {
        TakeOrdersConfigV5 memory config = claimConfig(signed, amount);
        vm.prank(claimer);
        vm.expectRevert(reason);
        RAINDEX.takeOrders4(config);
    }

    function testALockLandsInTheVaultOnBaseSepolia() public {
        token.mint(locker, 100e18);
        vm.startPrank(locker);
        token.approve(address(vault), 100e18);
        vm.expectEmit(true, true, false, true, address(vault));
        emit Lock(locker, 100e18, AGENT, 0);
        vault.lock(100e18, AGENT);
        vm.stopPrank();

        assertEq(vault.vaultBalance(), 100e18);
        assertEq(token.balanceOf(address(RAINDEX)), 100e18);
    }

    function testALockedAmountIsClaimedBackWithTwoOfTheThreeSignatures() public {
        lock(100e18);

        claim(seats(0, 1, coupon(40e18, 1)), 40e18);

        assertEq(token.balanceOf(claimer), 40e18);
        assertEq(vault.vaultBalance(), 60e18);
        assertEq(inputToken.balanceOf(claimer), 0);
    }

    function testASafeFillsOneOfTheTwoSeats() public {
        lock(100e18);

        claim(seats(SAFE_SIGNER, 1, coupon(40e18, 2)), 40e18);

        assertEq(token.balanceOf(claimer), 40e18);
    }

    function testOneSignatureFails() public {
        lock(100e18);
        SignedContextV1[] memory one = new SignedContextV1[](1);
        one[0] = seat(0, coupon(40e18, 3));

        claimFails(one, 40e18, stdError.indexOOBError);
    }

    function testTheSameSignerTwiceFails() public {
        lock(100e18);

        claimFails(seats(SAFE_SIGNER, SAFE_SIGNER, coupon(40e18, 4)), 40e18, bytes("Duplicate signer"));
    }

    function testASignerOutsideTheListFails() public {
        lock(100e18);
        (, uint256 otherKey) = makeAddrAndKey("not a coupon signer");
        bytes32[] memory words = coupon(40e18, 5);
        SignedContextV1[] memory signed = seats(0, 1, words);
        signed[1] = signContext(otherKey, words);

        claimFails(signed, 40e18, bytes("Wrong signer"));
    }

    function testACouponForAnotherOrderFails() public {
        lock(100e18);
        bytes32[] memory words = coupon(40e18, 6);
        words[3] = keccak256("another claim order");

        claimFails(seats(0, 1, words), 40e18, bytes("Wrong order hash"));
    }

    function testCouponsThatDifferBetweenSeatsFail() public {
        lock(100e18);
        SignedContextV1[] memory signed = new SignedContextV1[](2);
        signed[0] = seat(0, coupon(40e18, 7));
        signed[1] = seat(SAFE_SIGNER, coupon(40e18, 8));

        claimFails(signed, 40e18, bytes("Coupons differ"));
    }

    function testTheSameNonceCannotBeClaimedTwice() public {
        lock(100e18);
        claim(seats(0, 1, coupon(40e18, 9)), 40e18);

        claimFails(seats(SAFE_SIGNER, 0, coupon(40e18, 9)), 40e18, bytes("Nonce already used"));
    }

    function testTheAdminRemovesTheClaimOrder() public {
        OrderV4 memory order = claimOrder();
        vm.prank(admin);
        assertTrue(vault.removeOrder(order));

        assertFalse(RAINDEX.orderExists(orderHash));
    }
}
