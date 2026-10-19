// SPDX-License-Identifier: CAL
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
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
import {ClaimOrderScript, ClaimNetwork} from "script/ClaimOrderScript.sol";
import {LibCoupon} from "./lib/LibCoupon.sol";
import {SignContext} from "./lib/SignContext.sol";

/// The deploy scripts' order building, callable from a test.
contract ClaimOrderHarness is ClaimOrderScript {
    function checkRainV6() external view {
        requireRainV6();
    }

    function config(address token, address inputToken, address signer) external returns (OrderConfigV4 memory) {
        return claimOrderConfig(claimNetwork("base-sepolia"), token, inputToken, signer);
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
/// its claim order deployed as deploy-base-sepolia.sh deploys them, then a lock
/// and a claim.
contract TestClaimBaseSepolia is Test, SignContext {
    using LibDecimalFloat for Float;

    bytes32 internal constant AGENT = keccak256("a Unyt agent");

    event Lock(address indexed sender, uint256 amount, bytes32 indexed holochainAgent, uint256 lockId);

    ClaimOrderHarness internal scripts;
    address internal admin = makeAddr("admin");
    address internal locker = makeAddr("locker");
    address internal claimer = makeAddr("claimer");
    address internal signer;
    uint256 internal signerKey;
    MockHOT internal token;
    ClaimInputToken internal inputToken;
    HoloLockVault internal vault;
    bytes internal bytecode;
    bytes32 internal orderHash;

    function setUp() public {
        // FORK_BLOCK_BASE_SEPOLIA pins the fork to a block; unset, it is the latest.
        string memory rpc = vm.envOr("RPC_URL_BASE_SEPOLIA", string("https://base-sepolia-rpc.publicnode.com"));
        uint256 forkBlock = vm.envOr("FORK_BLOCK_BASE_SEPOLIA", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        assertEq(block.chainid, 84532, "the fork is not Base Sepolia");
        // Deployed on the fork: a contract made before the fork is selected is not there.
        scripts = new ClaimOrderHarness();
        scripts.checkRainV6();

        (signer, signerKey) = makeAddrAndKey("coupon signer");
        token = new MockHOT();
        inputToken = new ClaimInputToken();
        vault = new HoloLockVault(address(token), address(RAINDEX), HOLO_VAULT_ID, admin, MIN_LOCK_AMOUNT);

        OrderConfigV4 memory config = scripts.config(address(token), address(inputToken), signer);
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

    function words(uint256 amount, uint256 expiry, uint256 nonce) internal view returns (bytes32[] memory) {
        return LibCoupon.words(
            claimer,
            amount,
            expiry,
            orderHash,
            address(vault),
            address(RAINDEX),
            address(token),
            HOLO_VAULT_ID,
            bytes32(nonce),
            block.chainid
        );
    }

    function coupon(uint256 amount, uint256 expiry, uint256 nonce) internal view returns (SignedContextV1 memory) {
        return signContext(signerKey, words(amount, expiry, nonce));
    }

    /// The claim as the website sends it: takeOrders4 for exactly `amount` of HOT.
    function claimConfig(SignedContextV1 memory signedCoupon, uint256 amount)
        internal
        view
        returns (TakeOrdersConfigV5 memory)
    {
        SignedContextV1[] memory signedContexts = new SignedContextV1[](1);
        signedContexts[0] = signedCoupon;
        TakeOrderConfigV4[] memory orders = new TakeOrderConfigV4[](1);
        orders[0] = TakeOrderConfigV4(claimOrder(), 0, 0, signedContexts);
        Float io = LibDecimalFloat.fromFixedDecimalLosslessPacked(amount, 18);
        return TakeOrdersConfigV5(io, io, CLAIM_IO_RATIO, true, orders, "");
    }

    function claim(SignedContextV1 memory signedCoupon, uint256 amount) internal {
        TakeOrdersConfigV5 memory config = claimConfig(signedCoupon, amount);
        vm.prank(claimer);
        RAINDEX.takeOrders4(config);
    }

    function claimFails(SignedContextV1 memory signedCoupon, uint256 amount, string memory reason) internal {
        TakeOrdersConfigV5 memory config = claimConfig(signedCoupon, amount);
        vm.prank(claimer);
        vm.expectRevert(bytes(reason));
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

    function testALockedAmountIsClaimedBackWithACoupon() public {
        lock(100e18);

        claim(coupon(40e18, block.timestamp + 7 days, 1), 40e18);

        assertEq(token.balanceOf(claimer), 40e18);
        assertEq(vault.vaultBalance(), 60e18);
        assertEq(inputToken.balanceOf(claimer), 0);
    }

    function testACouponFromAnotherSignerFails() public {
        lock(100e18);
        (, uint256 otherKey) = makeAddrAndKey("not the coupon signer");
        SignedContextV1 memory other = signContext(otherKey, words(40e18, block.timestamp + 7 days, 2));

        claimFails(other, 40e18, "Wrong signer");
    }

    function testTheSameNonceCannotBeClaimedTwice() public {
        lock(100e18);
        claim(coupon(40e18, block.timestamp + 7 days, 3), 40e18);
        SignedContextV1 memory again = coupon(40e18, block.timestamp + 7 days + 1, 3);

        claimFails(again, 40e18, "Nonce already used");
    }

    /// chain-id() on Base Sepolia is 84532, the coupon's word 9: a coupon for
    /// Ethereum mainnet is refused here.
    function testACouponForMainnetFailsOnBaseSepolia() public {
        lock(100e18);
        bytes32[] memory mainnet = words(40e18, block.timestamp + 7 days, 4);
        assertEq(mainnet[9], bytes32(uint256(84532)));
        mainnet[9] = bytes32(uint256(1));

        claimFails(signContext(signerKey, mainnet), 40e18, "Wrong chain id");
    }

    function testTheAdminRemovesTheClaimOrder() public {
        OrderV4 memory order = claimOrder();
        vm.prank(admin);
        assertTrue(vault.removeOrder(order));

        assertFalse(RAINDEX.orderExists(orderHash));
    }
}
