// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HiveStaking} from "../src/HiveStaking.sol";
import {HiveMerkleDistributor} from "../src/HiveMerkleDistributor.sol";
import {HiveRewardRouter, IHiveStaking} from "../src/HiveRewardRouter.sol";

contract MockToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract HiveRewardRouterTest is Test {
    MockToken hive;
    MockToken imd;
    HiveStaking staking;
    HiveMerkleDistributor dist;
    HiveRewardRouter router;

    address alice = address(0xA11CE);
    address publisher = address(0xBEEF);
    address treasury = address(0x7EA);
    uint256 constant U = 1e18;

    function setUp() public {
        hive = new MockToken("Hive", "HIVE");
        imd = new MockToken("IMD", "IMD");
        staking = new HiveStaking(hive, imd);
        dist = new HiveMerkleDistributor(imd, publisher, address(0), treasury, 1 days, 180 days);
        router = new HiveRewardRouter(imd, IHiveStaking(address(staking)), address(dist));

        hive.mint(alice, 1_000_000 * U);
        vm.prank(alice);
        hive.approve(address(staking), type(uint256).max);
    }

    function _fundRouter(uint256 amt) internal { imd.mint(address(router), amt); }

    // 60/40 split: a staker gets the 60% bonus via depositReward, the distributor holds the 40% holder pot
    function test_routeSplits60_40() public {
        vm.prank(alice);
        staking.stake(100 * U);

        _fundRouter(100 * U);
        (uint256 toStakers, uint256 toHolders) = router.route();

        assertEq(toStakers, 60 * U, "60% to stakers");
        assertEq(toHolders, 40 * U, "40% to holders");
        assertEq(staking.pending(alice), 60 * U, "staker pending == 60");
        assertEq(imd.balanceOf(address(dist)), 40 * U, "distributor funded with 40");
        assertEq(imd.balanceOf(address(router)), 0, "router emptied");
    }

    // with nothing staked, the 80% is carried inside staking for the first stakers; holders still get 20%
    function test_routeCarriesStakerShareWhenNoStakers() public {
        _fundRouter(100 * U);
        router.route();
        assertEq(staking.rewardCarry(), 60 * U, "staker share carried");
        assertEq(imd.balanceOf(address(dist)), 40 * U, "holders still funded");
    }

    // empty balance is a no-op, never reverts
    function test_routeEmptyIsNoop() public {
        (uint256 s, uint256 h) = router.route();
        assertEq(s, 0);
        assertEq(h, 0);
    }

    // the split is a fixed constant — no setter exists (checked at the type level + value here)
    function test_splitIsImmutable() public view {
        assertEq(router.STAKER_BPS(), 6000);
        assertEq(router.holderBps(), 4000);
    }

    // constructor rejects a staking contract that pays a different reward token
    function test_ctorRejectsTokenMismatch() public {
        MockToken other = new MockToken("Other", "OTH");
        HiveStaking badStaking = new HiveStaking(hive, other); // rewards in OTH, not IMD
        vm.expectRevert(HiveRewardRouter.TokenMismatch.selector);
        new HiveRewardRouter(imd, IHiveStaking(address(badStaking)), address(dist));
    }

    // conservation: everything funded leaves the router, split exactly, nothing stuck
    function testFuzz_routeConserves(uint96 amt) public {
        vm.assume(amt > 0);
        vm.prank(alice);
        staking.stake(100 * U);
        _fundRouter(amt);
        (uint256 s, uint256 h) = router.route();
        assertEq(s + h, amt, "no IMD created or lost");
        assertEq(imd.balanceOf(address(router)), 0, "router fully drained");
        assertEq(s, (uint256(amt) * 6000) / 10_000, "staker share exact");
    }
}
