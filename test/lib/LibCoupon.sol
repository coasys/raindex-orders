// SPDX-License-Identifier: CAL
pragma solidity =0.8.25;

import {MessageHashUtils} from "openzeppelin-contracts/contracts/utils/cryptography/MessageHashUtils.sol";
import {Float, LibDecimalFloat} from "rain-math-float-0.2.1/src/lib/LibDecimalFloat.sol";

/// The nine words of a claim coupon, as src/holo-claim.rain reads them and as
/// bridge-orchestrator/src/signer.rs and ui/src/lib/coupon.ts write them.
library LibCoupon {
    /// Word 1: the amount of HOT as the decimal float Raindex V6 pays out. Its
    /// coefficient is the wei and its exponent -18, so the word is 0xffffffee
    /// followed by the wei in the low 224 bits. It is lossless for any wei an
    /// int224 holds.
    function amountWord(uint256 amountInWei) internal pure returns (bytes32) {
        return Float.unwrap(LibDecimalFloat.fromFixedDecimalLosslessPacked(amountInWei, 18));
    }

    function words(
        address recipient,
        uint256 amountInWei,
        uint256 expiry,
        bytes32 orderHash,
        address orderOwner,
        address raindex,
        address token,
        bytes32 vaultId,
        bytes32 nonce
    ) internal pure returns (bytes32[] memory coupon) {
        coupon = new bytes32[](9);
        coupon[0] = bytes32(uint256(uint160(recipient)));
        coupon[1] = amountWord(amountInWei);
        // A float with exponent 0 is its integer, which is what block-timestamp() is.
        coupon[2] = bytes32(expiry);
        coupon[3] = orderHash;
        coupon[4] = bytes32(uint256(uint160(orderOwner)));
        coupon[5] = bytes32(uint256(uint160(raindex)));
        coupon[6] = bytes32(uint256(uint160(token)));
        coupon[7] = vaultId;
        coupon[8] = nonce;
    }

    /// What each signer signs: the EIP-191 hash of the packed words, as
    /// Raindex's LibContext.build checks it.
    function digest(bytes32[] memory coupon) internal pure returns (bytes32) {
        return MessageHashUtils.toEthSignedMessageHash(keccak256(abi.encodePacked(coupon)));
    }
}
