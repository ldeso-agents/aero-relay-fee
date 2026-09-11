// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from 'forge-std/Test.sol';

import {RelayFeeSkim} from '../src/RelayFeeSkim.sol';
import {FalseReturnERC20, MockERC20, NoReturnERC20} from './mocks/MockERC20.sol';
import {MockRelay} from './mocks/MockRelay.sol';

contract RelayFeeSkimTest is Test {
  uint256 internal constant FEE_BPS = 500; // 5%
  uint256 internal constant BPS = 10_000;

  address internal keeper = makeAddr('keeper');
  address internal sink = makeAddr('sink');
  address internal stranger = makeAddr('stranger');

  RelayFeeSkim internal skim;
  MockRelay internal relay;
  MockERC20 internal token;

  event Skimmed(address indexed relay, address indexed token, uint256 idle, uint256 fee, uint256 forwarded);

  function setUp() public {
    skim = new RelayFeeSkim(FEE_BPS, sink);
    relay = new MockRelay();
    token = new MockERC20();
    relay.grantRoles(keeper, relay.KEEPER());
    // Installed as the Relay's `converter`: the factory seats it with CONVERTER, which is what
    // authorizes `pull`.
    relay.grantRoles(address(skim), relay.CONVERTER());
  }

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                   CONSTRUCTOR                                                     */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

  function test_constructor_setsImmutables() public view {
    assertEq(skim.FEE_BPS(), FEE_BPS);
    assertEq(skim.FEE_SINK(), sink);
    assertEq(skim.MAX_FEE_BPS(), 1000);
    assertEq(skim.BPS_DENOMINATOR(), BPS);
  }

  function test_constructor_acceptsMaxFee() public {
    RelayFeeSkim _s = new RelayFeeSkim(1000, sink);
    assertEq(_s.FEE_BPS(), 1000);
  }

  function test_constructor_revertsAboveMaxFee() public {
    vm.expectRevert(RelayFeeSkim.FeeOutOfRange.selector);
    new RelayFeeSkim(1001, sink);
  }

  function test_constructor_revertsZeroFee() public {
    vm.expectRevert(RelayFeeSkim.FeeOutOfRange.selector);
    new RelayFeeSkim(0, sink);
  }

  function test_constructor_revertsZeroSink() public {
    vm.expectRevert(RelayFeeSkim.ZeroAddress.selector);
    new RelayFeeSkim(FEE_BPS, address(0));
  }

  function testFuzz_constructor_boundsFee(uint256 _bps) public {
    if (_bps == 0 || _bps > 1000) {
      vm.expectRevert(RelayFeeSkim.FeeOutOfRange.selector);
      new RelayFeeSkim(_bps, sink);
    } else {
      assertEq(new RelayFeeSkim(_bps, sink).FEE_BPS(), _bps);
    }
  }

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                   KEEPER GATE                                                     */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

  function test_skim_revertsWhenCallerIsNotKeeper() public {
    token.mint(address(relay), 1000e18);
    vm.expectRevert(RelayFeeSkim.NotKeeper.selector);
    vm.prank(stranger);
    skim.skim(address(relay), address(token));
  }

  function test_skim_revertsWhenCallerHoldsOtherRolesButNotKeeper() public {
    token.mint(address(relay), 1000e18);
    relay.grantRoles(stranger, relay.VOTER_ROLE() | relay.COMPOUNDER() | relay.CONVERTER());
    vm.expectRevert(RelayFeeSkim.NotKeeper.selector);
    vm.prank(stranger);
    skim.skim(address(relay), address(token));
  }

  function test_skim_revertsAfterKeeperRevoked() public {
    token.mint(address(relay), 1000e18);
    relay.revokeRoles(keeper, relay.KEEPER());
    vm.expectRevert(RelayFeeSkim.NotKeeper.selector);
    vm.prank(keeper);
    skim.skim(address(relay), address(token));
  }

  function test_skim_keeperGateIsCheckedBeforeBalanceReads() public {
    // Empty Relay: a non-keeper still gets NotKeeper, never NoFee.
    vm.expectRevert(RelayFeeSkim.NotKeeper.selector);
    vm.prank(stranger);
    skim.skim(address(relay), address(token));
  }

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                    ROLE ON RELAY                                                  */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

  function test_skim_revertsWhenSkimmerLacksPullRole() public {
    token.mint(address(relay), 1000e18);
    relay.revokeRoles(address(skim), relay.CONVERTER());
    vm.expectRevert(MockRelay.NotAuthorized.selector);
    vm.prank(keeper);
    skim.skim(address(relay), address(token));
  }

  function test_skim_worksWithCompounderRoleToo() public {
    token.mint(address(relay), 1000e18);
    relay.revokeRoles(address(skim), relay.CONVERTER());
    relay.grantRoles(address(skim), relay.COMPOUNDER());
    vm.prank(keeper);
    assertEq(skim.skim(address(relay), address(token)), 50e18);
  }

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                     FEE MATH                                                      */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

  function test_skim_takesFeeOfWholeBalanceWhenNothingAccounted() public {
    token.mint(address(relay), 1000e18);

    vm.expectEmit(address(skim));
    emit Skimmed(address(relay), address(token), 1000e18, 50e18, 50e18);
    vm.prank(keeper);
    uint256 _fee = skim.skim(address(relay), address(token));

    assertEq(_fee, 50e18);
    assertEq(token.balanceOf(sink), 50e18);
    assertEq(token.balanceOf(address(relay)), 950e18);
    assertEq(token.balanceOf(address(skim)), 0);
  }

  function test_skim_subtractsAccountedBalance() public {
    token.mint(address(relay), 1000e18);
    relay.setAccountedBalance(address(token), 300e18);

    vm.expectEmit(address(skim));
    emit Skimmed(address(relay), address(token), 700e18, 35e18, 35e18);
    vm.prank(keeper);
    uint256 _fee = skim.skim(address(relay), address(token));

    assertEq(_fee, 35e18);
    assertEq(token.balanceOf(sink), 35e18);
    // Claimants stay whole: what remains still covers the accounted balance.
    assertGe(token.balanceOf(address(relay)), 300e18);
    assertEq(token.balanceOf(address(relay)), 965e18);
  }

  function test_skim_roundsDown() public {
    // 199 * 500 / 10_000 = 9.95 -> 9
    token.mint(address(relay), 199);
    vm.prank(keeper);
    assertEq(skim.skim(address(relay), address(token)), 9);
    assertEq(token.balanceOf(sink), 9);
  }

  function test_skim_maxFeeTakesTenPercent() public {
    RelayFeeSkim _ten = new RelayFeeSkim(1000, sink);
    relay.grantRoles(address(_ten), relay.CONVERTER());
    token.mint(address(relay), 1000e18);
    vm.prank(keeper);
    assertEq(_ten.skim(address(relay), address(token)), 100e18);
  }

  function test_skim_isPerToken() public {
    MockERC20 _other = new MockERC20();
    token.mint(address(relay), 1000e18);
    _other.mint(address(relay), 10e18);
    relay.setAccountedBalance(address(_other), 4e18);

    vm.startPrank(keeper);
    assertEq(skim.skim(address(relay), address(token)), 50e18);
    assertEq(skim.skim(address(relay), address(_other)), 0.3e18);
    vm.stopPrank();

    assertEq(token.balanceOf(sink), 50e18);
    assertEq(_other.balanceOf(sink), 0.3e18);
  }

  function test_skim_isPerRelay() public {
    MockRelay _other = new MockRelay();
    _other.grantRoles(keeper, _other.KEEPER());
    _other.grantRoles(address(skim), _other.CONVERTER());
    token.mint(address(relay), 1000e18);
    token.mint(address(_other), 200e18);

    vm.startPrank(keeper);
    assertEq(skim.skim(address(relay), address(token)), 50e18);
    assertEq(skim.skim(address(_other), address(token)), 10e18);
    vm.stopPrank();
    assertEq(token.balanceOf(sink), 60e18);
  }

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                    ZERO REVERT                                                    */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

  function test_skim_revertsOnEmptyRelay() public {
    vm.expectRevert(RelayFeeSkim.NoFee.selector);
    vm.prank(keeper);
    skim.skim(address(relay), address(token));
  }

  function test_skim_revertsWhenEverythingIsAccounted() public {
    token.mint(address(relay), 1000e18);
    relay.setAccountedBalance(address(token), 1000e18);
    vm.expectRevert(RelayFeeSkim.NoFee.selector);
    vm.prank(keeper);
    skim.skim(address(relay), address(token));
  }

  function test_skim_revertsWhenAccountedExceedsBalance() public {
    // Upstream `pull` would panic on the underflow; the skimmer treats it as no idle balance.
    token.mint(address(relay), 1000e18);
    relay.setAccountedBalance(address(token), 1001e18);
    vm.expectRevert(RelayFeeSkim.NoFee.selector);
    vm.prank(keeper);
    skim.skim(address(relay), address(token));
  }

  function test_skim_revertsWhenFeeRoundsToZero() public {
    // 19 * 500 / 10_000 = 0.95 -> 0
    token.mint(address(relay), 19);
    vm.expectRevert(RelayFeeSkim.NoFee.selector);
    vm.prank(keeper);
    skim.skim(address(relay), address(token));
  }

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                       FUZZ                                                        */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

  /// @dev The fee never exceeds FEE_BPS of the idle balance and never touches the accounted part.
  function testFuzz_skim_feeNeverExceedsShareOfIdle(uint256 _bps, uint256 _balance, uint256 _accounted) public {
    _bps = bound(_bps, 1, 1000);
    _balance = bound(_balance, 0, type(uint128).max);
    _accounted = bound(_accounted, 0, type(uint128).max);

    RelayFeeSkim _s = new RelayFeeSkim(_bps, sink);
    relay.grantRoles(address(_s), relay.CONVERTER());
    token.mint(address(relay), _balance);
    relay.setAccountedBalance(address(token), _accounted);

    uint256 _idle = _balance > _accounted ? _balance - _accounted : 0;
    uint256 _expected = (_idle * _bps) / BPS;

    vm.prank(keeper);
    if (_expected == 0) {
      vm.expectRevert(RelayFeeSkim.NoFee.selector);
      _s.skim(address(relay), address(token));
      return;
    }
    uint256 _fee = _s.skim(address(relay), address(token));

    assertEq(_fee, _expected, 'fee');
    assertLe(_fee, _idle, 'fee <= idle');
    assertLe(_fee * BPS, _idle * _bps, 'fee <= bps share of idle');
    assertEq(token.balanceOf(sink), _fee, 'sink');
    assertEq(token.balanceOf(address(relay)), _balance - _fee, 'relay');
    assertGe(token.balanceOf(address(relay)), _accounted, 'claimants whole');
    assertEq(token.balanceOf(address(_s)), 0, 'nothing stranded');
  }

  /// @dev A skim can never move what the Relay itself would refuse to `pull`.
  function testFuzz_skim_neverExceedsRelayPullBound(uint256 _balance, uint256 _accounted) public {
    _balance = bound(_balance, 0, type(uint128).max);
    _accounted = bound(_accounted, 0, _balance);
    token.mint(address(relay), _balance);
    relay.setAccountedBalance(address(token), _accounted);

    vm.prank(keeper);
    try skim.skim(address(relay), address(token)) returns (uint256 _fee) {
      assertLe(_fee, _balance - _accounted);
    } catch (bytes memory _err) {
      // A 4-byte selector is all the revert carries; truncating to it is the point.
      // forge-lint: disable-next-line(unsafe-typecast)
      assertEq(bytes4(_err), RelayFeeSkim.NoFee.selector);
    }
  }

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                    DOUBLE SKIM                                                    */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

  /// @dev The contract is stateless, so a repeat call skims FEE_BPS of the *remainder*. Two calls
  ///      take 5% + 5% of 95% = 9.75%, not 5% and not 10%. Only the keeper can trigger that.
  function test_skim_twiceSkimsTheRemainderAgain() public {
    token.mint(address(relay), 1000e18);

    vm.startPrank(keeper);
    assertEq(skim.skim(address(relay), address(token)), 50e18);
    assertEq(skim.skim(address(relay), address(token)), 47.5e18);
    vm.stopPrank();

    assertEq(token.balanceOf(sink), 97.5e18);
    assertEq(token.balanceOf(address(relay)), 902.5e18);
  }

  function test_skim_revertsOnceIdleIsGone() public {
    token.mint(address(relay), 1000e18);
    vm.prank(keeper);
    skim.skim(address(relay), address(token));

    // The Compounder drains the rest (simulated: everything left is now accounted).
    relay.setAccountedBalance(address(token), token.balanceOf(address(relay)));

    vm.expectRevert(RelayFeeSkim.NoFee.selector);
    vm.prank(keeper);
    skim.skim(address(relay), address(token));
  }

  function test_skim_newInflowIsSkimmedFresh() public {
    token.mint(address(relay), 1000e18);
    vm.prank(keeper);
    skim.skim(address(relay), address(token));
    relay.setAccountedBalance(address(token), token.balanceOf(address(relay)));

    token.mint(address(relay), 200e18);
    vm.prank(keeper);
    assertEq(skim.skim(address(relay), address(token)), 10e18);
    assertEq(token.balanceOf(sink), 60e18);
  }

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                  TOKEN BEHAVIOUR                                                  */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

  function test_skim_handlesNoReturnDataToken() public {
    NoReturnERC20 _usdt = new NoReturnERC20();
    _usdt.mint(address(relay), 1000e6);

    vm.prank(keeper);
    assertEq(skim.skim(address(relay), address(_usdt)), 50e6);
    assertEq(_usdt.balanceOf(sink), 50e6);
    assertEq(_usdt.balanceOf(address(relay)), 950e6);
  }

  function test_skim_revertsWhenTokenReturnsFalse() public {
    FalseReturnERC20 _bad = new FalseReturnERC20();
    _bad.mint(address(relay), 1000e18);
    // The mock Relay's own pull rejects a false return before the skimmer's transfer runs, so
    // exercise the skimmer's check directly with a token the Relay can hand out.
    vm.expectRevert(bytes('pull transfer failed'));
    vm.prank(keeper);
    skim.skim(address(relay), address(_bad));
  }

  function test_safeTransfer_revertsWhenTokenReturnsFalse() public {
    // Fund the skimmer directly so only its own forwarding transfer touches the false-returning token.
    FalseReturnERC20 _bad = new FalseReturnERC20();
    _bad.mint(address(skim), 1e18);
    // A Relay that never moves the token: idle is measured on the real token, pull is a no-op there.
    ForwardOnlyRelay _relay = new ForwardOnlyRelay();
    _bad.mint(address(_relay), 1000e18);
    _relay.grantRoles(keeper, _relay.KEEPER());
    vm.expectRevert(RelayFeeSkim.TransferFailed.selector);
    vm.prank(keeper);
    skim.skim(address(_relay), address(_bad));
  }

  function test_skim_forwardsStrayBalanceHeldByTheSkimmer() public {
    token.mint(address(relay), 1000e18);
    token.mint(address(skim), 7e18);

    vm.expectEmit(address(skim));
    emit Skimmed(address(relay), address(token), 1000e18, 50e18, 57e18);
    vm.prank(keeper);
    skim.skim(address(relay), address(token));

    assertEq(token.balanceOf(sink), 57e18);
    assertEq(token.balanceOf(address(skim)), 0);
  }
}

/// @dev A Relay stand-in whose `pull` moves nothing: lets a test reach the skimmer's own transfer
///      with a token the mock Relay would otherwise reject first.
contract ForwardOnlyRelay is MockRelay {
  function pull(address, uint256) external pure override {}
}
