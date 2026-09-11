// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script, console} from 'forge-std/Script.sol';

import {RelayFeeSkim} from '../src/RelayFeeSkim.sol';

/// @notice Deploys `RelayFeeSkim` through the canonical CREATE2 deployer
///         (0x4e59b44847b379578588920cA78FbF26c0B4956C) with a fixed salt, so the address is a pure
///         function of the bytecode and the constructor arguments and is the same on every chain.
///
///         FEE_BPS  fee in basis points (1..1000)
///         FEE_SINK recipient of skimmed fees
///
///         forge script script/Deploy.s.sol --rpc-url base --broadcast --verify
contract Deploy is Script {
  bytes32 public constant SALT = keccak256('aero-relay-fee/RelayFeeSkim/v1');

  function run() external returns (RelayFeeSkim _skim) {
    uint256 _feeBps = vm.envUint('FEE_BPS');
    address _feeSink = vm.envAddress('FEE_SINK');
    address _predicted = predict(_feeBps, _feeSink);
    console.log('FEE_BPS  ', _feeBps);
    console.log('FEE_SINK ', _feeSink);
    console.log('predicted', _predicted);

    if (_predicted.code.length != 0) {
      console.log('already deployed');
      return RelayFeeSkim(_predicted);
    }

    vm.startBroadcast();
    _skim = new RelayFeeSkim{salt: SALT}(_feeBps, _feeSink);
    vm.stopBroadcast();

    require(address(_skim) == _predicted, 'CREATE2 address mismatch');
    require(_skim.FEE_BPS() == _feeBps && _skim.FEE_SINK() == _feeSink, 'constructor args mismatch');
    console.log('deployed ', address(_skim));
  }

  /// @notice Address the deployment will land on for the given parameters.
  function predict(uint256 _feeBps, address _feeSink) public pure returns (address) {
    bytes32 _initCodeHash = keccak256(abi.encodePacked(type(RelayFeeSkim).creationCode, abi.encode(_feeBps, _feeSink)));
    return vm.computeCreate2Address(SALT, _initCodeHash);
  }
}
