// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20Minimal} from './interfaces/IERC20Minimal.sol';
import {IRelayEntrypoint} from './interfaces/IRelayEntrypoint.sol';

/**
 * @title  RelayFeeSkim
 * @notice A Relay entrypoint that takes a fixed basis-point cut of a Relay's idle token balance and
 *         forwards it to a fixed sink. It is installed as the Relay's `converter` and therefore
 *         holds the CONVERTER role, which is what authorizes `pull`; it never calls `notifyReward`.
 *         The keeper skims first, then runs the official Compounder on what is left.
 * @dev    Stateless and Relay-agnostic: no owner, no storage, both parameters are immutable and
 *         bounded at construction. One deployment can serve many Relays. The fee base is
 *         `balanceOf(relay) - accountedBalance(token)`, the same bound the Relay enforces on
 *         `pull`, so a skim can never move rewards already owed to claimants. Rounds down, so the
 *         fee never exceeds `FEE_BPS / 10_000` of the idle balance.
 */
contract RelayFeeSkim {
  /// @notice Basis-point denominator.
  uint256 public constant BPS_DENOMINATOR = 10_000;

  /// @notice Upper bound on `FEE_BPS` (10%). Enforced in the constructor.
  uint256 public constant MAX_FEE_BPS = 1000;

  /// @notice Fee taken on each skim, in basis points of the idle balance.
  uint256 public immutable FEE_BPS;

  /// @notice Recipient of every skimmed fee.
  address public immutable FEE_SINK;

  /// @notice Emitted on every successful skim.
  /// @param relay Relay the fee was pulled from.
  /// @param token Token skimmed.
  /// @param idle Idle balance the fee was computed on (`balanceOf - accountedBalance`).
  /// @param fee Amount pulled from the Relay.
  /// @param forwarded Amount sent to `FEE_SINK`: `fee` plus any balance this contract already held.
  event Skimmed(address indexed relay, address indexed token, uint256 idle, uint256 fee, uint256 forwarded);

  /// @notice Thrown when `FEE_SINK` is the zero address.
  error ZeroAddress();

  /// @notice Thrown when `FEE_BPS` is zero or above `MAX_FEE_BPS`.
  error FeeOutOfRange();

  /// @notice Thrown when the caller does not hold KEEPER on the Relay.
  error NotKeeper();

  /// @notice Thrown when the computed fee is zero: no idle balance, or one too small to round up.
  error NoFee();

  /// @notice Thrown when the token transfer to the sink reverts or returns false.
  error TransferFailed();

  /// @notice Fix the fee and its recipient for the life of the contract.
  /// @param _feeBps Fee in basis points, `1 <= _feeBps <= MAX_FEE_BPS`.
  /// @param _feeSink Recipient of skimmed fees.
  constructor(uint256 _feeBps, address _feeSink) {
    if (_feeBps == 0 || _feeBps > MAX_FEE_BPS) revert FeeOutOfRange();
    if (_feeSink == address(0)) revert ZeroAddress();
    FEE_BPS = _feeBps;
    FEE_SINK = _feeSink;
  }

  /// @notice Pull `FEE_BPS` of the Relay's idle `_token` balance and forward it to `FEE_SINK`.
  /// @param _relay Relay to skim. This contract must hold COMPOUNDER or CONVERTER on it.
  /// @param _token Token to skim.
  /// @return _fee Amount pulled from the Relay.
  /// @dev Gated on the Relay's KEEPER role, like every upstream entrypoint, so the keeper decides
  ///      when the skim runs relative to the compound. A repeat call skims the remainder again; the
  ///      keeper is the only party who can trigger that. An accounted balance above the token
  ///      balance is treated as zero idle rather than a panic. The whole balance this contract
  ///      holds is forwarded, so nothing can be stranded here.
  function skim(address _relay, address _token) external returns (uint256 _fee) {
    IRelayEntrypoint _relayContract = IRelayEntrypoint(_relay);
    if (!_relayContract.hasAnyRole(msg.sender, _relayContract.KEEPER())) revert NotKeeper();

    uint256 _balance = IERC20Minimal(_token).balanceOf(_relay);
    uint256 _accounted = _relayContract.accountedBalance(_token);
    uint256 _idle = _balance > _accounted ? _balance - _accounted : 0;

    _fee = (_idle * FEE_BPS) / BPS_DENOMINATOR;
    if (_fee == 0) revert NoFee();

    _relayContract.pull(_token, _fee);

    uint256 _forwarded = IERC20Minimal(_token).balanceOf(address(this));
    _safeTransfer(_token, FEE_SINK, _forwarded);

    emit Skimmed(_relay, _token, _idle, _fee, _forwarded);
  }

  /// @notice Transfer that accepts tokens returning nothing (USDT-style) and rejects a `false`.
  /// @param _token Token to move.
  /// @param _to Recipient.
  /// @param _amount Amount to move.
  function _safeTransfer(address _token, address _to, uint256 _amount) private {
    (bool _ok, bytes memory _data) = _token.call(abi.encodeCall(IERC20Minimal.transfer, (_to, _amount)));
    if (!_ok || (_data.length != 0 && !abi.decode(_data, (bool)))) revert TransferFailed();
  }
}
