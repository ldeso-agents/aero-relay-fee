// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {MockERC20} from './MockERC20.sol';

/// @notice Mirrors the slice of `RelayBase` a skimmer touches, with the same semantics as upstream
///         `RelayBase.pull` + `RelayRewardsLib.pull` (metadex-public b032bb7):
///         - role bits from `RelayRoles` (KEEPER = 1<<0, COMPOUNDER = 1<<2, CONVERTER = 1<<3);
///         - `pull` is gated on COMPOUNDER | CONVERTER, not on KEEPER;
///         - `pull` is bounded by `balanceOf(this) - accountedBalance[token]`, reverting with
///           `RewardExceedsBalance` above it (and panicking on underflow, exactly like upstream);
///         - the tokens go to `msg.sender`.
contract MockRelay {
  uint256 public constant KEEPER = 1 << 0;
  uint256 public constant VOTER_ROLE = 1 << 1;
  uint256 public constant COMPOUNDER = 1 << 2;
  uint256 public constant CONVERTER = 1 << 3;

  error NotAuthorized();
  error RewardExceedsBalance();

  mapping(address account => uint256 roles) public rolesOf;
  mapping(address token => uint256 accounted) public accountedBalance;

  function grantRoles(address _account, uint256 _roles) external {
    rolesOf[_account] |= _roles;
  }

  function revokeRoles(address _account, uint256 _roles) external {
    rolesOf[_account] &= ~_roles;
  }

  function setAccountedBalance(address _token, uint256 _accounted) external {
    accountedBalance[_token] = _accounted;
  }

  function hasAnyRole(address _account, uint256 _roles) public view returns (bool) {
    return rolesOf[_account] & _roles != 0;
  }

  function pull(address _token, uint256 _amount) external virtual {
    if (!hasAnyRole(msg.sender, COMPOUNDER | CONVERTER)) revert NotAuthorized();
    if (_amount > MockERC20(_token).balanceOf(address(this)) - accountedBalance[_token]) {
      revert RewardExceedsBalance();
    }
    (bool _ok, bytes memory _data) =
      _token.call(abi.encodeWithSignature('transfer(address,uint256)', msg.sender, _amount));
    require(_ok && (_data.length == 0 || abi.decode(_data, (bool))), 'pull transfer failed');
  }
}
