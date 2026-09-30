// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HiveStaking} from "../src/HiveStaking.sol";

contract MockToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract HiveStakingTest is Test {
    MockToken hive; // stake token
    MockToken imd; // reward token
    HiveStaking st;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant U = 1e18;

    function setUp() public {
        hive = new MockToken("Hive", "HIVE");
        imd = new MockToken("IMD", "IMD");
        st = new HiveStaking(hive, imd);
        hive.mint(alice, 1_000_000 * U);
        hive.mint(bob, 1_000_000 * U);
        vm.prank(alice); hive.approve(address(st), type(uint256).max);
        vm.prank(bob); hive.approve(address(st), type(uint256).max);
        // this test contract funds the reward deposits
        imd.mint(address(this), 1_000_000 * U);
        imd.approve(address(st), type(uint256).max);
    }

    function _stake(address who, uint256 amt) internal { vm.prank(who); st.stake(amt); }
    function _deposit(uint256 amt) internal { st.depositReward(amt); }
    function _claim(address who) internal returns (uint256) { vm.prank(who); return st.claim(); }

    // one staker gets the whole pot
    function test_singleStakerGetsAll() public {
        _stake(alice, 100 * U);
        _deposit(5 ether);
        assertEq(st.pending(alice), 5 ether, "pending");
        uint256 got = _claim(alice);
        assertEq(got, 5 ether);
        assertEq(imd.balanceOf(alice), 5 ether, "IMD received");
        assertEq(st.pending(alice), 0);
    }

    // equal weight -> equal split
    function test_twoStakersProRata() public {
        _stake(alice, 100 * U);
        _stake(bob, 100 * U);
        _deposit(4 ether);
        assertEq(st.pending(alice), 2 ether);
        assertEq(st.pending(bob), 2 ether);
    }

    // amount-weighted split at the same tier
    function test_proRataByAmount() public {
        _stake(alice, 300 * U);
        _stake(bob, 100 * U);
        _deposit(4 ether);
        assertEq(st.pending(alice), 3 ether);
        assertEq(st.pending(bob), 1 ether);
    }

    // loyalty multiplier steps up over time
    function test_multiplierTiers() public {
        _stake(alice, 100 * U);
        assertEq(st.multiplierBps(alice), 10_000);
        vm.warp(block.timestamp + 7 days);
        assertEq(st.multiplierBps(alice), 12_500);
        vm.warp(block.timestamp + 23 days); // 30 total
        assertEq(st.multiplierBps(alice), 15_000);
        vm.warp(block.timestamp + 60 days); // 90 total
        assertEq(st.multiplierBps(alice), 20_000);
    }

    // a long-held staker earns more per token than a fresh one, once poked
    function test_multiplierAffectsShare() public {
        _stake(alice, 100 * U);
        vm.warp(block.timestamp + 90 days);
        _stake(bob, 100 * U); // bob fresh (1x); alice now 2x but stale
        st.poke(alice);
        assertEq(st.multiplierBps(alice), 20_000);
        assertEq(st.multiplierBps(bob), 10_000);
        _deposit(3 ether); // alice weight 200, bob 100 -> 2:1
        assertApproxEqAbs(st.pending(alice), 2 ether, 2);
        assertApproxEqAbs(st.pending(bob), 1 ether, 2);
    }

    // rewards accrued before a tier change stay at the old rate; new rate applies after
    function test_lazyTierDoesNotBackpay() public {
        _stake(alice, 100 * U);
        _deposit(1 ether); // at 1x
        vm.warp(block.timestamp + 90 days);
        st.poke(alice); // now 2x, but the first ether was already at 1x
        _deposit(1 ether); // at 2x (still only staker, gets it all)
        assertEq(st.pending(alice), 2 ether); // 1 + 1, no retroactive boost on the first
    }

    // adding stake blends the clock, it doesn't reset to zero
    function test_addStakeBlendsClock() public {
        _stake(alice, 100 * U);
        vm.warp(block.timestamp + 90 days); // alice at 2x on 100
        _stake(alice, 100 * U); // add equal amount at "now" -> midpoint ~45 days -> 1.5x
        assertEq(st.multiplierBps(alice), 15_000, "blended to 1.5x");
        // a tiny top-up barely moves a long position (well past the 90d line)
        _stake(bob, 900_000 * U);
        vm.warp(block.timestamp + 200 days);
        _stake(bob, 1 * U);
        assertEq(st.multiplierBps(bob), 20_000, "tiny top-up keeps 2x");
    }

    // unstake returns tokens, settles pending, and the remainder keeps its clock
    function test_unstakeKeepsRemainderClock() public {
        _stake(alice, 100 * U);
        vm.warp(block.timestamp + 90 days);
        st.poke(alice);
        _deposit(1 ether); // alice earns this at 2x (sole staker)
        uint256 balBefore = hive.balanceOf(alice);
        vm.prank(alice); st.unstake(40 * U);
        assertEq(hive.balanceOf(alice) - balBefore, 40 * U, "got tokens back");
        assertEq(st.pending(alice), 1 ether, "pending preserved through unstake");
        assertEq(st.multiplierBps(alice), 20_000, "remainder still 2x");
        (uint256 amt,,,,) = st.stakeOf(alice);
        assertEq(amt, 60 * U, "60 left staked");
    }

    // rewards deposited with nobody staked are carried to the first staker
    function test_rewardCarry() public {
        _deposit(2 ether); // nobody staked yet
        assertEq(st.rewardCarry(), 2 ether);
        assertEq(st.accRewardPerWeight(), 0);
        _stake(alice, 100 * U);
        _deposit(1 ether); // rolls in the 2 carried -> 3 total to alice
        assertEq(st.rewardCarry(), 0);
        assertEq(st.pending(alice), 3 ether);
    }

    // no IMD is lost across a mixed sequence: everything deposited is claimable in total
    function test_conservationOfRewards() public {
        _stake(alice, 100 * U);
        _stake(bob, 50 * U);
        _deposit(3 ether);
        vm.warp(block.timestamp + 30 days);
        st.poke(alice); st.poke(bob);
        _deposit(6 ether);
        uint256 a = _claim(alice);
        uint256 b = _claim(bob);
        assertApproxEqAbs(a + b, 9 ether, 1e5, "all rewards distributed");
        assertLe(imd.balanceOf(address(st)), 1e5, "dust only left in contract");
    }
}
