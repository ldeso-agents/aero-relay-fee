// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from 'forge-std/Test.sol';

import {RelayFeeSkim} from '../src/RelayFeeSkim.sol';
import {IRelayEntrypoint} from '../src/interfaces/IRelayEntrypoint.sol';
import {IRelayEntrypoint as UpstreamIRelayEntrypoint} from './upstream/IRelayEntrypoint.sol';

/// @notice Pins the four Relay selectors the skimmer calls against the upstream interface at
///         dromos-labs/metadex-public b032bb7f55eff31e081196754e0fdbc217f978d2 (1.0.0-provisional.3),
///         both as literals and against the byte-identical vendored copy in `test/upstream/`.
contract SelectorsTest is Test {
  bytes4 internal constant PULL = 0xf2d5d56b; // pull(address,uint256)
  bytes4 internal constant ACCOUNTED_BALANCE = 0xa7838c8a; // accountedBalance(address)
  bytes4 internal constant KEEPER = 0x862a179e; // KEEPER()
  bytes4 internal constant HAS_ANY_ROLE = 0x514e62fc; // hasAnyRole(address,uint256)

  function test_selectors_matchLiterals() public pure {
    assertEq(IRelayEntrypoint.pull.selector, PULL);
    assertEq(IRelayEntrypoint.accountedBalance.selector, ACCOUNTED_BALANCE);
    assertEq(IRelayEntrypoint.KEEPER.selector, KEEPER);
    assertEq(IRelayEntrypoint.hasAnyRole.selector, HAS_ANY_ROLE);
  }

  function test_selectors_matchUpstream() public pure {
    assertEq(IRelayEntrypoint.pull.selector, UpstreamIRelayEntrypoint.pull.selector);
    assertEq(IRelayEntrypoint.accountedBalance.selector, UpstreamIRelayEntrypoint.accountedBalance.selector);
    assertEq(IRelayEntrypoint.KEEPER.selector, UpstreamIRelayEntrypoint.KEEPER.selector);
    assertEq(IRelayEntrypoint.hasAnyRole.selector, UpstreamIRelayEntrypoint.hasAnyRole.selector);
  }

  function test_selectors_matchSignatures() public pure {
    assertEq(PULL, bytes4(keccak256('pull(address,uint256)')));
    assertEq(ACCOUNTED_BALANCE, bytes4(keccak256('accountedBalance(address)')));
    assertEq(KEEPER, bytes4(keccak256('KEEPER()')));
    assertEq(HAS_ANY_ROLE, bytes4(keccak256('hasAnyRole(address,uint256)')));
  }

  function test_skimSelector() public pure {
    assertEq(RelayFeeSkim.skim.selector, bytes4(keccak256('skim(address,address)')));
    assertEq(RelayFeeSkim.skim.selector, bytes4(0x712b772f));
  }
}
