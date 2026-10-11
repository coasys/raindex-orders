// SPDX-License-Identifier: CAL
pragma solidity =0.8.25;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRaindexV6, OrderConfigV4, OrderV4, TaskV2, Float} from "raindex-interface-0.1.7/src/interface/IRaindexV6.sol";
import {LibDecimalFloat} from "rain-math-float-0.2.1/src/lib/LibDecimalFloat.sol";

/// @title HoloLockVault
/// @notice A wrapper contract that accepts HOT token deposits and forwards them
/// to a Raindex V6 vault. Emits events with Holochain agent public keys
/// to enable cross-chain bridging to HoloFuel.
///
/// This contract is the LOCK side of the HOT <> HoloFuel swap:
/// - LOCK: User sends HOT -> receives HoloFuel (this contract)
/// - UNLOCK: User burns HoloFuel -> receives HOT (via claim coupons)
///
/// Raindex V6 counts every amount as a decimal float. This contract takes and
/// reports amounts in the token's own units (wei for HOT), and converts each one
/// losslessly, refusing an amount a float cannot carry.
contract HoloLockVault {
    using SafeERC20 for IERC20;
    using LibDecimalFloat for Float;

    /// @notice Emitted when HOT is locked for HoloFuel redemption
    /// @param sender The Ethereum address that locked HOT
    /// @param amount The amount of HOT locked (in wei, 18 decimals)
    /// @param holochainAgent The 32-byte Holochain agent public key to receive HoloFuel
    /// @param lockId Unique identifier for this lock operation
    event Lock(address indexed sender, uint256 amount, bytes32 indexed holochainAgent, uint256 lockId);

    /// @notice Emitted when admin withdraws tokens (emergency only)
    /// @param admin The admin address performing the withdrawal
    /// @param amount The amount withdrawn
    /// @param to The recipient of the withdrawn tokens
    event AdminWithdraw(address indexed admin, uint256 amount, address indexed to);

    /// @notice Emitted when admin is changed
    /// @param oldAdmin The previous admin address
    /// @param newAdmin The new admin address
    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);

    /// The largest amount a float carries losslessly: its coefficient is an int224.
    uint256 internal constant MAX_FLOAT_AMOUNT = uint256(uint224(type(int224).max));

    // Storage layout is append-only. This contract is deployed and holds user funds, so
    // a new variable goes after the last one below: nothing already here is reordered,
    // retyped or removed. The live contract keeps reading the same slots, and shifting
    // them makes it read another field's bytes as this one. (The immutables directly
    // below live in bytecode rather than a slot, so they are not part of that layout.)

    /// @notice The token being locked (HOT on mainnet)
    IERC20 public immutable token;

    /// @notice The token's decimals, which every float conversion uses
    uint8 public immutable tokenDecimals;

    /// @notice The Raindex V6 orderbook contract
    IRaindexV6 public immutable orderbook;

    /// @notice The vault ID used in the orderbook for this contract's deposits
    bytes32 public immutable vaultId;

    /// @notice Running counter for unique lock IDs
    uint256 public lockNonce;

    /// @notice Admin address that can perform emergency withdrawals
    address public admin;

    /// @notice Minimum lock amount to prevent dust/spam attacks
    uint256 public minLockAmount;

    /// @dev Restricts function access to admin only
    modifier onlyAdmin() {
        require(msg.sender == admin, "HoloLockVault: only admin");
        _;
    }

    /// @notice Initialize the lock vault
    /// @param _token The ERC20 token to accept (HOT)
    /// @param _orderbook The Raindex V6 address
    /// @param _vaultId The vault ID to deposit into
    /// @param _admin The admin address for emergency functions
    /// @param _minLockAmount Minimum amount that can be locked
    constructor(address _token, address _orderbook, bytes32 _vaultId, address _admin, uint256 _minLockAmount) {
        require(_token != address(0), "HoloLockVault: zero token address");
        require(_orderbook != address(0), "HoloLockVault: zero orderbook address");
        require(_vaultId != bytes32(0), "HoloLockVault: zero vault id");
        require(_admin != address(0), "HoloLockVault: zero admin address");

        token = IERC20(_token);
        tokenDecimals = IERC20Metadata(_token).decimals();
        orderbook = IRaindexV6(_orderbook);
        vaultId = _vaultId;
        admin = _admin;
        minLockAmount = _minLockAmount;

        // Approve orderbook to spend our tokens for deposits
        // Using max approval since we trust the orderbook contract
        IERC20(_token).forceApprove(_orderbook, type(uint256).max);
    }

    /// @notice Lock tokens to receive HoloFuel on Holochain
    /// @dev Requires prior approval of this contract to spend caller's tokens
    /// @param amount Amount of tokens to lock (must meet minimum)
    /// @param holochainAgent The 32-byte Holochain agent public key to receive HoloFuel
    /// @return lockId The unique identifier for this lock operation
    function lock(uint256 amount, bytes32 holochainAgent) external returns (uint256 lockId) {
        require(amount >= minLockAmount, "HoloLockVault: amount below minimum");
        require(holochainAgent != bytes32(0), "HoloLockVault: invalid holochain agent");

        // Transfer tokens from user to this contract
        token.safeTransferFrom(msg.sender, address(this), amount);

        // Deposit into orderbook vault (this contract owns the vault)
        orderbook.deposit4(address(token), vaultId, toFloat(amount), new TaskV2[](0));

        // Generate unique lock ID and emit event
        lockId = lockNonce++;
        emit Lock(msg.sender, amount, holochainAgent, lockId);
    }

    /// @notice Get the current vault balance in the orderbook
    /// @dev Rounded down to the token's units, should a claim ever leave a
    /// fraction of one in the vault
    /// @return balance The amount of tokens in the orderbook vault
    function vaultBalance() external view returns (uint256 balance) {
        (balance,) = orderbook.vaultBalance2(address(this), address(token), vaultId).toFixedDecimalLossy(tokenDecimals);
    }

    /// @notice Admin function for emergency withdrawal from orderbook vault
    /// @dev Only callable by admin, withdraws from orderbook and sends to recipient
    /// @param amount Amount to withdraw
    /// @param to Recipient address
    function adminWithdraw(uint256 amount, address to) external onlyAdmin {
        require(to != address(0), "HoloLockVault: zero recipient");
        require(amount > 0, "HoloLockVault: zero amount");

        // Withdraw from orderbook vault
        orderbook.withdraw4(address(token), vaultId, toFloat(amount), new TaskV2[](0));

        // Transfer to recipient
        token.safeTransfer(to, amount);

        emit AdminWithdraw(msg.sender, amount, to);
    }

    /// @notice Admin function to recover any tokens accidentally sent to this contract
    /// @dev Does NOT withdraw from orderbook, only recovers tokens held directly by contract
    /// @param tokenAddress The token to recover
    /// @param to Recipient address
    function adminRecoverTokens(address tokenAddress, address to) external onlyAdmin {
        require(to != address(0), "HoloLockVault: zero recipient");

        uint256 balance = IERC20(tokenAddress).balanceOf(address(this));
        require(balance > 0, "HoloLockVault: no balance");

        IERC20(tokenAddress).safeTransfer(to, balance);
    }

    /// @notice Transfer admin role to a new address
    /// @param newAdmin The new admin address
    function setAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "HoloLockVault: zero admin address");

        address oldAdmin = admin;
        admin = newAdmin;

        emit AdminChanged(oldAdmin, newAdmin);
    }

    /// @notice Update the minimum lock amount
    /// @param _minLockAmount New minimum amount
    function setMinLockAmount(uint256 _minLockAmount) external onlyAdmin {
        minLockAmount = _minLockAmount;
    }

    /// @notice Admin function to add an order to the orderbook
    /// @dev This makes HoloLockVault the order owner, so claim outputs come from its vault
    /// @param config The order configuration
    /// @return stateChanged True if the order was added
    function addOrder(OrderConfigV4 calldata config) external onlyAdmin returns (bool stateChanged) {
        return orderbook.addOrder4(config, new TaskV2[](0));
    }

    /// @notice Admin function to remove an order from the orderbook
    /// @param order The order to remove
    /// @return stateChanged True if the order was removed
    function removeOrder(OrderV4 calldata order) external onlyAdmin returns (bool stateChanged) {
        return orderbook.removeOrder3(order, new TaskV2[](0));
    }

    /// `amount` of the token as the float Raindex counts it: the amount in the
    /// token's units as the coefficient, and minus its decimals as the exponent,
    /// so converting back loses nothing.
    function toFloat(uint256 amount) internal view returns (Float) {
        require(amount <= MAX_FLOAT_AMOUNT, "HoloLockVault: amount too large for a float");
        return LibDecimalFloat.fromFixedDecimalLosslessPacked(amount, tokenDecimals);
    }
}
