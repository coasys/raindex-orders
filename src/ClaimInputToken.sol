// SPDX-License-Identifier: CAL
pragma solidity =0.8.25;

import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title ClaimInputToken
/// @notice The claim order's input token, which moves nothing.
///
/// A claim is Raindex taking the claim order: the claimer is paid HOT out of the
/// vault, and pays the order's input token at the order's io-ratio. Raindex V6
/// takes an order only at a positive ratio, so the claim order's is 1e-30, and
/// it rounds what it pulls from the taker up to one unit of the input token. A
/// claimer would need a balance and an allowance of a real token for that unit,
/// so the input token is this one: every transfer succeeds and nothing is held.
/// It is deployed with the lock vault and named in the deploy record as
/// CLAIM_INPUT_TOKEN.
contract ClaimInputToken is IERC20Metadata {
    function name() external pure returns (string memory) {
        return "HOT bridge claim input";
    }

    function symbol() external pure returns (string memory) {
        return "CLAIM";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        emit Transfer(from, to, value);
        return true;
    }
}
