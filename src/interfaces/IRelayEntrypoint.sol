// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title  IRelayEntrypoint
/// @notice The slice of the Relay surface a fee skimmer drives: the role gate, the accounting read
///         and the pull. Re-declared from the MIT-licensed `IRelayEntrypoint` in
///         dromos-labs/metadex-public (`V3/src/interfaces/relay/IRelayEntrypoint.sol`, commit
///         b032bb7f55eff31e081196754e0fdbc217f978d2, version 1.0.0-provisional.3). Only the four
///         members this repository calls are kept; every signature and selector is identical to
///         upstream and pinned by `test/Selectors.t.sol`.
interface IRelayEntrypoint {
  /// @notice Pull `_amount` of `_token` from the Relay to the caller (entrypoint role gated).
  /// @param _token Token to pull.
  /// @param _amount Amount to pull.
  function pull(address _token, uint256 _amount) external;

  /// @notice Balance of `_token` already notified to holders and not yet claimed. The Relay's own
  ///         bound for `pull`, `compound` and `notifyReward` is `balanceOf - accountedBalance`, so
  ///         an idle-balance path has to subtract this to leave claimants whole.
  /// @param _token Token to read.
  /// @return _accounted Amount owed to reward claimants.
  function accountedBalance(address _token) external view returns (uint256 _accounted);

  /// @notice The KEEPER role bit, checked against the entrypoint caller.
  /// @return _role The KEEPER role bit.
  function KEEPER() external view returns (uint256 _role);

  /// @notice Whether `_account` holds any of the `_roles` bits on the Relay.
  /// @param _account Account to check.
  /// @param _roles Role bits to check.
  /// @return _has True when the account holds at least one of the bits.
  function hasAnyRole(address _account, uint256 _roles) external view returns (bool _has);
}
