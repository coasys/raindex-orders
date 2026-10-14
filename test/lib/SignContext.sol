// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {SignedContextV1} from "rainlang-interface-0.2.9/src/interface/IInterpreterCallerV4.sol";
import {LibCoupon} from "./LibCoupon.sol";

contract SignContext is Test {
    /// `context` signed by one key: what one of a claim's M signers contributes.
    function signContext(uint256 privateKey, bytes32[] memory context)
        public
        pure
        returns (SignedContextV1 memory signedContext)
    {
        // Store the signer's address in the struct
        signedContext.signer = vm.addr(privateKey);
        signedContext.context = context; // copy the context data into the struct

        // Create the signature using the cheatcode 'sign'
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, LibCoupon.digest(context));
        signedContext.signature = abi.encodePacked(r, s, v);
    }

    /// The same `context` signed by each key in turn: a claim carrying M coupons.
    function signContexts(uint256[] memory privateKeys, bytes32[] memory context)
        public
        pure
        returns (SignedContextV1[] memory signed)
    {
        signed = new SignedContextV1[](privateKeys.length);
        for (uint256 i = 0; i < privateKeys.length; i++) {
            signed[i] = signContext(privateKeys[i], context);
        }
    }
}
