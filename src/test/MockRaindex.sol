// SPDX-License-Identifier: CAL
pragma solidity =0.8.25;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    IRaindexV6,
    OrderConfigV4,
    OrderV4,
    TaskV2,
    QuoteV2,
    ClearConfigV2,
    SignedContextV1,
    TakeOrdersConfigV5,
    Float
} from "raindex-interface-0.1.7/src/interface/IRaindexV6.sol";
import {IERC3156FlashBorrower} from "raindex-interface-0.1.7/src/interface/ierc3156/IERC3156FlashBorrower.sol";
import {LibDecimalFloat} from "rain-math-float-0.2.1/src/lib/LibDecimalFloat.sol";

/// @title MockRaindex
/// @notice A minimal mock of Raindex V6 for testing HoloLockVault
/// @dev Only implements deposit4, withdraw4 and vaultBalance2, converting
/// between floats and token units as Raindex V6 does: a deposit's float must
/// be a whole number of the token's units, and a withdrawal rounds down to one.
contract MockRaindex is IRaindexV6 {
    using SafeERC20 for IERC20;
    using LibDecimalFloat for Float;

    /// @dev Mapping: owner -> token -> vaultId -> balance
    mapping(address => mapping(address => mapping(bytes32 => Float))) private _vaultBalances;

    /// @inheritdoc IRaindexV6
    function deposit4(address token, bytes32 vaultId, Float depositAmount, TaskV2[] calldata) external override {
        require(depositAmount.gt(LibDecimalFloat.FLOAT_ZERO), "ZeroDepositAmount");

        uint8 decimals = IERC20Metadata(token).decimals();
        uint256 amount = depositAmount.toFixedDecimalLossless(decimals);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        _vaultBalances[msg.sender][token][vaultId] = _vaultBalances[msg.sender][token][vaultId].add(depositAmount);

        emit DepositV2(msg.sender, token, vaultId, amount);
    }

    /// @inheritdoc IRaindexV6
    function withdraw4(address token, bytes32 vaultId, Float targetAmount, TaskV2[] calldata) external override {
        require(targetAmount.gt(LibDecimalFloat.FLOAT_ZERO), "ZeroWithdrawTargetAmount");

        Float currentBalance = _vaultBalances[msg.sender][token][vaultId];
        Float withdrawAmount = targetAmount.min(currentBalance);
        uint8 decimals = IERC20Metadata(token).decimals();
        (uint256 amount,) = withdrawAmount.toFixedDecimalLossy(decimals);

        if (amount > 0) {
            _vaultBalances[msg.sender][token][vaultId] = currentBalance.sub(withdrawAmount);
            IERC20(token).safeTransfer(msg.sender, amount);
        }

        emit WithdrawV2(msg.sender, token, vaultId, targetAmount, withdrawAmount, amount);
    }

    /// @inheritdoc IRaindexV6
    function vaultBalance2(address owner, address token, bytes32 vaultId) external view override returns (Float) {
        return _vaultBalances[owner][token][vaultId];
    }

    // Stub implementations for other functions (not used by HoloLockVault)

    /// @inheritdoc IRaindexV6
    function entask2(TaskV2[] calldata) external pure override {
        revert("Not implemented");
    }

    /// @inheritdoc IRaindexV6
    function orderExists(bytes32) external pure override returns (bool) {
        revert("Not implemented");
    }

    /// @inheritdoc IRaindexV6
    function quote2(QuoteV2 calldata) external pure override returns (bool, Float, Float) {
        revert("Not implemented");
    }

    /// @inheritdoc IRaindexV6
    function addOrder4(OrderConfigV4 calldata, TaskV2[] calldata) external pure override returns (bool) {
        revert("Not implemented");
    }

    /// @inheritdoc IRaindexV6
    function removeOrder3(OrderV4 calldata, TaskV2[] calldata) external pure override returns (bool) {
        revert("Not implemented");
    }

    /// @inheritdoc IRaindexV6
    function takeOrders4(TakeOrdersConfigV5 calldata) external pure override returns (Float, Float) {
        revert("Not implemented");
    }

    /// @inheritdoc IRaindexV6
    function clear3(
        OrderV4 memory,
        OrderV4 memory,
        ClearConfigV2 calldata,
        SignedContextV1[] memory,
        SignedContextV1[] memory
    ) external pure override {
        revert("Not implemented");
    }

    function flashLoan(IERC3156FlashBorrower, address, uint256, bytes calldata) external pure override returns (bool) {
        revert("Not implemented");
    }

    function flashFee(address, uint256) external pure override returns (uint256) {
        revert("Not implemented");
    }

    function maxFlashLoan(address) external pure override returns (uint256) {
        revert("Not implemented");
    }
}
