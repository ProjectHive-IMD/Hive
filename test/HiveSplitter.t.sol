// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HiveSplitter} from "../src/HiveSplitter.sol";

/// Minimal stand-in for the Pons v2 fee escrow's native path: holds a per-recipient ETH
/// balance credited by the launch, and pays it all out to msg.sender on claim().
contract MockEscrow {
    mapping(address => uint256) public balanceOf;

    function credit(address recipient) external payable {
        balanceOf[recipient] += msg.value;
    }

    function claim() external returns (uint256 amount) {
        amount = balanceOf[msg.sender];
        require(amount > 0, "no balance");
        balanceOf[msg.sender] = 0;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok, "send failed");
    }
}

contract HiveSplitterTest is Test {
    HiveSplitter sp;
    MockEscrow escrow;
    address seat = address(0x5EA7);
    address ops = address(0x0B5);
    address team = address(0x7EA1);

    function setUp() public {
        escrow = new MockEscrow();
        sp = new HiveSplitter(seat, ops, team, address(escrow));
    }

    function test_splitsByShares() public {
        vm.deal(address(sp), 1 ether);
        sp.distribute();
        assertEq(seat.balance, (uint256(1 ether) * 8871) / 10000);
        assertEq(ops.balance, (uint256(1 ether) * 323) / 10000);
        assertEq(team.balance, 1 ether - seat.balance - ops.balance);
    }

    // nothing is lost: seat + ops + team == everything that came in
    function test_conservation() public {
        vm.deal(address(sp), 6.2 ether);
        sp.distribute();
        assertEq(seat.balance + ops.balance + team.balance, 6.2 ether, "all distributed");
        assertEq(address(sp).balance, 0, "nothing left behind");
    }

    // 6.2 ETH claimed (a 5.5% tax on ~100 ETH volume) lands as ~5.5 / ~0.2 / ~0.5
    function test_matchesFeePlan() public {
        vm.deal(address(sp), 6.2 ether);
        sp.distribute();
        assertApproxEqRel(seat.balance, 5.5 ether, 0.002e18); // ~5.5 ETH to seats
        assertApproxEqRel(ops.balance, 0.2 ether, 0.01e18); // ~0.2 ETH ops
        assertApproxEqRel(team.balance, 0.5 ether, 0.01e18); // ~0.5 ETH team
    }

    function test_revertsWhenEmpty() public {
        vm.expectRevert(HiveSplitter.NoBalance.selector);
        sp.distribute();
    }

    function test_rejectsZeroAddress() public {
        vm.expectRevert(HiveSplitter.ZeroAddress.selector);
        new HiveSplitter(address(0), ops, team, address(escrow));
    }

    // the full on-chain path: fees credited in the escrow -> harvest() claims + splits in one call
    function test_harvestClaimsThenSplits() public {
        // the launch credits 6.2 ETH of creator fees to the splitter's escrow balance
        escrow.credit{value: 6.2 ether}(address(sp));
        assertEq(escrow.balanceOf(address(sp)), 6.2 ether, "credited");

        sp.harvest(); // permissionless: pulls from escrow, then splits

        assertEq(escrow.balanceOf(address(sp)), 0, "escrow drained");
        assertEq(address(sp).balance, 0, "splitter drained");
        assertEq(seat.balance + ops.balance + team.balance, 6.2 ether, "all forwarded");
        assertApproxEqRel(seat.balance, 5.5 ether, 0.002e18);
    }

    // harvest also mops up ETH already sitting in the splitter (e.g. sent directly), not just escrow
    function test_harvestSplitsDirectBalanceToo() public {
        escrow.credit{value: 1 ether}(address(sp)); // 1 in escrow
        vm.deal(address(sp), 1 ether); // 1 already here
        sp.harvest();
        assertEq(seat.balance + ops.balance + team.balance, 2 ether, "both sources split");
    }

    // harvest never reverts when there is nothing to do (keeper can poll it safely)
    function test_harvestNoopWhenEmpty() public {
        sp.harvest();
        assertEq(seat.balance, 0);
        assertEq(ops.balance, 0);
        assertEq(team.balance, 0);
    }
}
