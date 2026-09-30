// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HiveMerkleDistributor} from "../src/HiveMerkleDistributor.sol";

contract MockToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract HiveMerkleDistributorTest is Test {
    MockToken imd;
    HiveMerkleDistributor dist;

    address publisher = address(0xBEEF);
    address guardian = address(0x6A6A);
    address treasury = address(0x7EA);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address random = address(0x1234);

    uint64 constant CLAIM_DELAY = 1 days;
    uint64 constant SWEEP_DELAY = 180 days;
    uint256 constant U = 1e18;

    function setUp() public {
        imd = new MockToken("IMD", "IMD");
        dist = new HiveMerkleDistributor(imd, publisher, guardian, treasury, CLAIM_DELAY, SWEEP_DELAY);
    }

    // --- merkle helpers: OZ standard tree (double-hashed leaf, sorted-pair parents) ---
    function _leaf(address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    // a 2-leaf tree over (alice, aAmt) and (bob, bAmt)
    function _tree(uint256 aAmt, uint256 bAmt)
        internal
        view
        returns (bytes32 root, bytes32[] memory proofA, bytes32[] memory proofB)
    {
        bytes32 la = _leaf(alice, aAmt);
        bytes32 lb = _leaf(bob, bAmt);
        root = _hashPair(la, lb);
        proofA = new bytes32[](1);
        proofA[0] = lb;
        proofB = new bytes32[](1);
        proofB[0] = la;
    }

    function _open(uint256 pot, bytes32 root) internal returns (uint256 id) {
        imd.mint(address(dist), pot);
        vm.prank(publisher);
        id = dist.setRound(root, pot);
    }

    // happy path: both parties claim their exact share, funds land on the encoded accounts
    function test_claimBoth() public {
        (bytes32 root, bytes32[] memory pA, bytes32[] memory pB) = _tree(3 * U, 1 * U);
        uint256 id = _open(4 * U, root);
        vm.warp(block.timestamp + CLAIM_DELAY);

        dist.claim(id, alice, 3 * U, pA);
        dist.claim(id, bob, 1 * U, pB);

        assertEq(imd.balanceOf(alice), 3 * U);
        assertEq(imd.balanceOf(bob), 1 * U);
        assertEq(dist.totalReserved(), 0, "all reserved paid out");
        assertTrue(dist.isClaimed(id, alice));
    }

    // push semantics: a random keeper pays the encoded account, not itself
    function test_pushPaysEncodedAccount() public {
        (bytes32 root, bytes32[] memory pA,) = _tree(3 * U, 1 * U);
        uint256 id = _open(4 * U, root);
        vm.warp(block.timestamp + CLAIM_DELAY);
        vm.prank(random);
        dist.claim(id, alice, 3 * U, pA);
        assertEq(imd.balanceOf(alice), 3 * U, "alice paid");
        assertEq(imd.balanceOf(random), 0, "pusher gets nothing");
    }

    // batch push in one tx
    function test_batchClaim() public {
        (bytes32 root, bytes32[] memory pA, bytes32[] memory pB) = _tree(3 * U, 1 * U);
        uint256 id = _open(4 * U, root);
        vm.warp(block.timestamp + CLAIM_DELAY);
        address[] memory accts = new address[](2);
        uint256[] memory amts = new uint256[](2);
        bytes32[][] memory proofs = new bytes32[][](2);
        accts[0] = alice; amts[0] = 3 * U; proofs[0] = pA;
        accts[1] = bob; amts[1] = 1 * U; proofs[1] = pB;
        vm.prank(random);
        dist.batchClaim(id, accts, amts, proofs);
        assertEq(imd.balanceOf(alice), 3 * U);
        assertEq(imd.balanceOf(bob), 1 * U);
    }

    function test_doubleClaimReverts() public {
        (bytes32 root, bytes32[] memory pA,) = _tree(3 * U, 1 * U);
        uint256 id = _open(4 * U, root);
        vm.warp(block.timestamp + CLAIM_DELAY);
        dist.claim(id, alice, 3 * U, pA);
        vm.expectRevert(HiveMerkleDistributor.AlreadyClaimed.selector);
        dist.claim(id, alice, 3 * U, pA);
    }

    // a wrong amount (or wrong account) fails the proof
    function test_badProofReverts() public {
        (bytes32 root, bytes32[] memory pA,) = _tree(3 * U, 1 * U);
        uint256 id = _open(4 * U, root);
        vm.warp(block.timestamp + CLAIM_DELAY);
        vm.expectRevert(HiveMerkleDistributor.BadProof.selector);
        dist.claim(id, alice, 5 * U, pA); // inflated amount
    }

    function test_onlyPublisherOpens() public {
        (bytes32 root,,) = _tree(3 * U, 1 * U);
        imd.mint(address(dist), 4 * U);
        vm.expectRevert(HiveMerkleDistributor.NotPublisher.selector);
        dist.setRound(root, 4 * U);
    }

    // conservation: can't commit more than the contract actually holds (net of live rounds)
    function test_cannotOverCommit() public {
        (bytes32 root,,) = _tree(3 * U, 1 * U);
        imd.mint(address(dist), 4 * U);
        vm.prank(publisher);
        vm.expectRevert(HiveMerkleDistributor.InsufficientUnreserved.selector);
        dist.setRound(root, 5 * U); // only 4 in the contract
    }

    // two live rounds reserve independently; the second can only use what's left
    function test_reservationAcrossRounds() public {
        (bytes32 root,,) = _tree(3 * U, 1 * U);
        imd.mint(address(dist), 10 * U);
        vm.startPrank(publisher);
        dist.setRound(root, 4 * U); // reserves 4
        assertEq(dist.unreserved(), 6 * U);
        dist.setRound(root, 6 * U); // uses the rest
        assertEq(dist.unreserved(), 0);
        vm.expectRevert(HiveMerkleDistributor.InsufficientUnreserved.selector);
        dist.setRound(root, 1); // nothing left
        vm.stopPrank();
    }

    function test_claimBeforeDelayReverts() public {
        (bytes32 root, bytes32[] memory pA,) = _tree(3 * U, 1 * U);
        uint256 id = _open(4 * U, root);
        vm.expectRevert(HiveMerkleDistributor.NotClaimableYet.selector);
        dist.claim(id, alice, 3 * U, pA); // still inside claimDelay
    }

    // guardian cancels a bad round during its delay window -> funds unreserved, round dead
    function test_guardianCancel() public {
        (bytes32 root, bytes32[] memory pA,) = _tree(3 * U, 1 * U);
        uint256 id = _open(4 * U, root);
        vm.prank(guardian);
        dist.cancelRound(id);
        assertEq(dist.unreserved(), 4 * U, "funds returned to pool");
        vm.warp(block.timestamp + CLAIM_DELAY);
        vm.expectRevert(HiveMerkleDistributor.RoundInactive.selector);
        dist.claim(id, alice, 3 * U, pA);
    }

    function test_nonGuardianCannotCancel() public {
        (bytes32 root,,) = _tree(3 * U, 1 * U);
        uint256 id = _open(4 * U, root);
        vm.prank(random);
        vm.expectRevert(HiveMerkleDistributor.NotGuardian.selector);
        dist.cancelRound(id);
    }

    // can't cancel once the round is live (claimDelay passed)
    function test_cannotCancelLiveRound() public {
        (bytes32 root,,) = _tree(3 * U, 1 * U);
        uint256 id = _open(4 * U, root);
        vm.warp(block.timestamp + CLAIM_DELAY);
        vm.prank(guardian);
        vm.expectRevert(HiveMerkleDistributor.NotClaimableYet.selector);
        dist.cancelRound(id);
    }

    // unclaimed remainder sweeps to treasury only after sweepDelay
    function test_sweepUnclaimed() public {
        (bytes32 root, bytes32[] memory pA,) = _tree(3 * U, 1 * U);
        uint256 id = _open(4 * U, root);
        vm.warp(block.timestamp + CLAIM_DELAY);
        dist.claim(id, alice, 3 * U, pA); // 3 claimed, 1 left unclaimed (bob never claims)

        vm.expectRevert(HiveMerkleDistributor.TooEarlyToSweep.selector);
        dist.sweep(id);

        vm.warp(block.timestamp + SWEEP_DELAY);
        dist.sweep(id);
        assertEq(imd.balanceOf(treasury), 1 * U, "remainder swept");
        assertEq(dist.totalReserved(), 0);
    }

    // a distributor with guardian == 0 simply has no veto
    function test_guardianDisabled() public {
        HiveMerkleDistributor d2 =
            new HiveMerkleDistributor(imd, publisher, address(0), treasury, CLAIM_DELAY, SWEEP_DELAY);
        (bytes32 root,,) = _tree(3 * U, 1 * U);
        imd.mint(address(d2), 4 * U);
        vm.prank(publisher);
        uint256 id = d2.setRound(root, 4 * U);
        vm.prank(guardian);
        vm.expectRevert(HiveMerkleDistributor.NotGuardian.selector);
        d2.cancelRound(id);
    }
}
