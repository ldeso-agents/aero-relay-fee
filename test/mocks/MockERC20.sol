// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Minimal ERC-20 that follows the standard: `transfer` returns true.
contract MockERC20 {
  mapping(address => uint256) public balanceOf;

  function mint(address _to, uint256 _amount) external {
    balanceOf[_to] += _amount;
  }

  function transfer(address _to, uint256 _amount) external virtual returns (bool) {
    _move(msg.sender, _to, _amount);
    return true;
  }

  function _move(address _from, address _to, uint256 _amount) internal {
    require(balanceOf[_from] >= _amount, 'insufficient');
    balanceOf[_from] -= _amount;
    balanceOf[_to] += _amount;
  }
}

/// @notice USDT-style token: `transfer` moves the balance but returns no data.
contract NoReturnERC20 is MockERC20 {
  function transfer(address _to, uint256 _amount) external override returns (bool) {
    _move(msg.sender, _to, _amount);
    assembly {
      return(0, 0)
    }
  }
}

/// @notice Token whose `transfer` returns false instead of reverting.
contract FalseReturnERC20 is MockERC20 {
  function transfer(address, uint256) external pure override returns (bool) {
    return false;
  }
}
