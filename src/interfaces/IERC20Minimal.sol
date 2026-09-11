// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title  IERC20Minimal
/// @notice The two ERC-20 members the skimmer needs: a balance read and a transfer. `transfer` is
///         never called through this interface (it would reject tokens that return no data); the
///         skimmer issues it as a raw call and only uses the selector from here.
interface IERC20Minimal {
  /// @notice Balance of `_account`.
  /// @param _account Account to read.
  /// @return _balance The balance.
  function balanceOf(address _account) external view returns (uint256 _balance);

  /// @notice Move `_amount` to `_to`.
  /// @param _to Recipient.
  /// @param _amount Amount to move.
  /// @return _success True on success for tokens that follow the standard.
  function transfer(address _to, uint256 _amount) external returns (bool _success);
}
