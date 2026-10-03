// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {HivePotPusher, IAcrossSpokePool} from "../src/HivePotPusher.sol";
import {HiveSplitter} from "../src/HiveSplitter.sol";

/// records the last deposit call exactly as Across would receive it (raw calldata, read back by index)
contract MockSpokePool {
    bytes4 constant DEPOSIT_V3 = bytes4(
        keccak256("depositV3(address,address,address,address,uint256,uint256,uint256,address,uint32,uint32,uint32,bytes)")
    );
    bytes public lastCall;
    address public sender;
    uint256 public value;
    uint256 public count;

    fallback() external payable {
        require(bytes4(msg.data) == DEPOSIT_V3, "not depositV3");
        lastCall = msg.data;
        (sender, value) = (msg.sender, msg.value);
        count++;
        require(uint256(word(4)) == msg.value, "value != inputAmount");
    }

    /// the i-th static argument of the last call
    function word(uint256 i) public view returns (bytes32 w) {
        bytes memory d = lastCall;
        assembly { w := mload(add(add(d, 36), mul(i, 32))) }
    }

    function addr(uint256 i) public view returns (address) {
        return address(uint160(uint256(word(i))));
    }
}

contract SafeNft is ERC721 {
    constructor() ERC721("n", "n") {}
    function safeMintTo(address to, uint256 id) external { _safeMint(to, id); }
}

contract HivePotPusherTest is Test {
    uint256 constant PK = 0xA11CE; // stands in for the seat-pot wallet's key
    address wallet;
    address bot = makeAddr("bot");
    address seatBuyer = makeAddr("seatBuyer");
    address constant WETH_RH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant WETH_ETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    MockSpokePool spoke;
    HivePotPusher impl;

    function setUp() public {
        wallet = vm.addr(PK);
        spoke = new MockSpokePool();
        impl = new HivePotPusher(bot, IAcrossSpokePool(address(spoke)), WETH_RH, WETH_ETH, seatBuyer, 100, 0.1 ether, 0.002 ether);
        // the wallet signs a one-time EIP-7702 authorization pointing at the pusher
        vm.signAndAttachDelegation(address(impl), PK);
        (bool ok,) = wallet.call(""); // any call carries the type-4 tx
        require(ok);
        vm.deal(wallet, 3 ether);
    }

    function _push(address caller, uint256 amount, uint256 out) internal {
        vm.prank(caller);
        HivePotPusher(payable(wallet)).push(amount, out, uint32(block.timestamp), uint32(block.timestamp + 2 hours), address(0), 0);
    }

    function test_delegationIsInPlace() public view {
        assertEq(wallet.code, abi.encodePacked(hex"ef0100", address(impl)), "7702 designator");
    }

    function test_walletStillReceivesEth() public {
        (bool ok,) = wallet.call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(wallet.balance, 4 ether);
    }

    function test_feeHarvestStillPaysTheWallet() public {
        HiveSplitter splitter = new HiveSplitter(wallet, makeAddr("ops"), makeAddr("team"), address(0));
        vm.deal(address(splitter), 1 ether);
        splitter.harvest();
        assertEq(wallet.balance, 3 ether + (1 ether * 8871) / 10_000, "seat share landed in the delegated wallet");
    }

    function test_botPushesToTheFixedDestinationOnly() public {
        _push(bot, 2 ether, 1.99 ether);
        assertEq(spoke.count(), 1);
        assertEq(spoke.addr(0), wallet, "depositor: refunds come back to the wallet");
        assertEq(spoke.addr(1), seatBuyer, "recipient: money can only go to the SeatBuyer");
        assertEq(spoke.addr(2), WETH_RH, "input token");
        assertEq(spoke.addr(3), WETH_ETH, "output token");
        assertEq(uint256(spoke.word(4)), 2 ether, "input amount");
        assertEq(uint256(spoke.word(5)), 1.99 ether, "output amount");
        assertEq(uint256(spoke.word(6)), 1, "destination: Ethereum");
        assertEq(spoke.sender(), wallet, "the wallet itself deposits");
        assertEq(spoke.value(), 2 ether);
        assertEq(wallet.balance, 1 ether);
    }

    function test_walletItselfCanPush() public {
        _push(wallet, 1 ether, 0.995 ether);
        assertEq(spoke.count(), 1);
    }

    function test_strangerCannotPush() public {
        vm.expectRevert(HivePotPusher.NotAllowed.selector);
        _push(makeAddr("stranger"), 1 ether, 0.995 ether);
    }

    function test_feeIsCapped() public {
        vm.expectRevert(HivePotPusher.FeeTooHigh.selector);
        _push(bot, 2 ether, 1.97 ether); // 1.5% > 1% cap
    }

    function test_outputCannotExceedInput() public {
        vm.expectRevert(HivePotPusher.BadAmount.selector);
        _push(bot, 1 ether, 1.1 ether);
    }

    function test_gasReserveAlwaysStays() public {
        vm.expectRevert(HivePotPusher.BadAmount.selector);
        _push(bot, 2.999 ether, 2.99 ether); // would leave < 0.002
    }

    function test_noDustPushes() public {
        vm.expectRevert(HivePotPusher.BadAmount.selector);
        _push(bot, 0.05 ether, 0.0499 ether);
    }

    function test_deadlinesBounded() public {
        vm.startPrank(bot);
        HivePotPusher w = HivePotPusher(payable(wallet));
        vm.expectRevert(HivePotPusher.BadTiming.selector);
        w.push(1 ether, 0.995 ether, uint32(block.timestamp), uint32(block.timestamp), address(0), 0);
        vm.expectRevert(HivePotPusher.BadTiming.selector);
        w.push(1 ether, 0.995 ether, uint32(block.timestamp), uint32(block.timestamp + 7 hours), address(0), 0);
        vm.expectRevert(HivePotPusher.BadTiming.selector);
        w.push(1 ether, 0.995 ether, uint32(block.timestamp), uint32(block.timestamp + 1 hours), address(1), 601);
        vm.stopPrank();
    }

    function test_neverTouchesWalletStorage() public {
        vm.record();
        _push(bot, 1 ether, 0.995 ether);
        (, bytes32[] memory writes) = vm.accesses(wallet);
        assertEq(writes.length, 0, "stateless: no SSTORE on the wallet");
    }

    function test_acceptsSafeNftTransfers() public {
        SafeNft nft = new SafeNft();
        nft.safeMintTo(wallet, 7);
        assertEq(nft.ownerOf(7), wallet);
    }

    function test_constructorGuards() public {
        vm.expectRevert("bad arg");
        new HivePotPusher(address(0), IAcrossSpokePool(address(spoke)), WETH_RH, WETH_ETH, seatBuyer, 100, 0, 0);
        vm.expectRevert("bad arg");
        new HivePotPusher(bot, IAcrossSpokePool(address(spoke)), WETH_RH, WETH_ETH, seatBuyer, 501, 0, 0);
    }
}
