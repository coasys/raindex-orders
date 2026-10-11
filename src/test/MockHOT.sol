// SPDX-License-Identifier: CAL
pragma solidity =0.8.25;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @title MockHOT
/// @notice A mock HOT token for testing the HoloLockVault
/// @dev Exposes mint function for test purposes
contract MockHOT is ERC20 {
    constructor() ERC20("Mock HOT Token", "HOT") {}

    /// @notice Mint tokens to an address (for testing only)
    /// @param to The recipient address
    /// @param amount The amount to mint
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Burn tokens from an address (for testing only)
    /// @param from The address to burn from
    /// @param amount The amount to burn
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
