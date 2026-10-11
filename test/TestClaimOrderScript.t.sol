// SPDX-License-Identifier: CAL
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {IRaindexV6, OrderConfigV4} from "raindex-interface-0.1.7/src/interface/IRaindexV6.sol";
import {HoloLockVault} from "src/HoloLockVault.sol";
import {MockHOT} from "src/test/MockHOT.sol";
import {MockRaindex} from "src/test/MockRaindex.sol";
import {ClaimOrderScript} from "script/ClaimOrderScript.sol";

contract AdminHarness is ClaimOrderScript {
    function contractAt(address account) external view returns (bool) {
        return isContract(account);
    }

    function sendAsAdmin(HoloLockVault vault, bytes[] memory calls) external {
        asAdmin(vault, calls);
    }
}

contract TestClaimOrderScript is Test {
    AdminHarness internal harness = new AdminHarness();
    address internal constant ACCOUNT = address(0xA11CE);

    function hasContractCode(bytes memory runtime) internal returns (bool) {
        vm.etch(ACCOUNT, runtime);
        return harness.contractAt(ACCOUNT);
    }

    function testAKeyWithOrWithoutAnEip7702DelegationIsAKey() public {
        assertFalse(hasContractCode(""));
        assertFalse(hasContractCode(abi.encodePacked(hex"ef0100", address(0xBEEF))));
    }

    function testAnyOtherCodeIsAContract() public {
        assertTrue(hasContractCode(abi.encodePacked(hex"600100", address(0xBEEF))));
        assertTrue(hasContractCode(address(harness).code));
    }

    /// A vault whose admin is the broadcaster a test sends as, with `adminCode` at it.
    function vaultAdministeredBy(bytes memory adminCode) internal returns (HoloLockVault vault, bytes[] memory calls) {
        MockRaindex orderbook = new MockRaindex();
        vault = new HoloLockVault(address(new MockHOT()), address(orderbook), bytes32(uint256(1)), DEFAULT_SENDER, 1);
        vm.etch(DEFAULT_SENDER, adminCode);
        vm.mockCall(address(orderbook), abi.encodeWithSelector(IRaindexV6.addOrder4.selector), abi.encode(true));
        OrderConfigV4 memory config;
        calls = new bytes[](1);
        calls[0] = abi.encodeCall(HoloLockVault.addOrder, (config));
    }

    function testADelegatedAdminKeySendsItsCalls() public {
        (HoloLockVault vault, bytes[] memory calls) =
            vaultAdministeredBy(abi.encodePacked(hex"ef0100", address(0xBEEF)));
        vm.expectCall(address(vault), calls[0], 1);
        harness.sendAsAdmin(vault, calls);
    }

    function testAContractAdminSendsNothing() public {
        (HoloLockVault vault, bytes[] memory calls) = vaultAdministeredBy(address(harness).code);
        vm.expectCall(address(vault), calls[0], 0);
        harness.sendAsAdmin(vault, calls);
    }
}
