// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// --------------------------------------------------------------------------------------------------
// Minimal Seaport 1.6 basic-order surface. Field order/types match Seaport's BasicOrderParameters so
// the keeper can pass an OpenSea listing straight through (basicOrderType is Seaport's enum, a uint8).
// --------------------------------------------------------------------------------------------------
struct AdditionalRecipient {
    uint256 amount;
    address payable recipient;
}

struct BasicOrderParameters {
    address considerationToken; // 0x0 == native ETH listing
    uint256 considerationIdentifier;
    uint256 considerationAmount; // paid to the seller
    address payable offerer;
    address zone;
    address offerToken; // the NFT collection (collection-check target)
    uint256 offerIdentifier; // tokenId
    uint256 offerAmount; // 1 for an ERC721
    uint8 basicOrderType; // Seaport BasicOrderType enum
    uint256 startTime;
    uint256 endTime;
    bytes32 zoneHash;
    uint256 salt;
    bytes32 offererConduitKey;
    bytes32 fulfillerConduitKey;
    uint256 totalOriginalAdditionalRecipients;
    AdditionalRecipient[] additionalRecipients; // marketplace fee + royalties
    bytes signature;
}

interface ISeaport {
    function fulfillBasicOrder(BasicOrderParameters calldata parameters) external payable returns (bool fulfilled);
}

/**
 * @title SeatBuyer
 * @notice Turns treasury ETH into identity.md seats by filling OpenSea (Seaport) listings, behind two
 *         hard safety rails so a bot — or a compromised keeper — can never drain the treasury or buy
 *         the wrong thing:
 *           1. collection-check: the listing's NFT must be the identity.md contract;
 *           2. price-cap: the total paid must be <= the per-call limit AND <= an immutable hard ceiling.
 *         The seat is forwarded to `seatVault` (the wallet that pairs and runs it). The keeper is an
 *         operator, not an owner: it can only ever trigger a capped identity.md purchase into the
 *         vault, with no path to move funds anywhere else. This is the "auto-buy / floor-sweep / snipe"
 *         engine of the flywheel; the keeper picks the cheapest live listing off-chain and fills it here.
 */
contract SeatBuyer is ReentrancyGuard, IERC721Receiver {
    ISeaport public immutable seaport;
    IERC721 public immutable identityMd; // the seat collection
    address public immutable seatVault; // holds + pairs the seats, and receives any rescued ETH
    address public immutable keeper; // the only caller that can trigger a buy (operator, not admin)
    uint256 public immutable maxSeatPrice; // hard ceiling: a compromised keeper can never overpay above this

    event SeatBought(uint256 indexed tokenId, address indexed offerer, uint256 totalCost);
    event EthRescued(uint256 amount);

    error NotKeeper();
    error WrongCollection();
    error NotEthListing();
    error NotSingleNft();
    error PriceTooHigh(uint256 cost, uint256 limit);
    error InsufficientEth(uint256 need, uint256 have);
    error FillFailed();

    constructor(ISeaport _seaport, IERC721 _identityMd, address _seatVault, address _keeper, uint256 _maxSeatPrice) {
        require(
            address(_seaport) != address(0) && address(_identityMd) != address(0) && _seatVault != address(0)
                && _keeper != address(0) && _maxSeatPrice > 0,
            "bad arg"
        );
        seaport = _seaport;
        identityMd = _identityMd;
        seatVault = _seatVault;
        keeper = _keeper;
        maxSeatPrice = _maxSeatPrice;
    }

    receive() external payable {} // bridged treasury ETH lands here

    /// total ETH a listing costs: what the seller gets plus every marketplace-fee / royalty recipient
    function orderCost(BasicOrderParameters calldata p) public pure returns (uint256 cost) {
        cost = p.considerationAmount;
        uint256 n = p.additionalRecipients.length;
        for (uint256 i = 0; i < n; i++) {
            cost += p.additionalRecipients[i].amount;
        }
    }

    /// buy one identity.md seat, collection-checked and price-capped, and forward it to the vault
    function buySeat(BasicOrderParameters calldata p, uint256 maxPay) external nonReentrant returns (uint256 tokenId) {
        if (msg.sender != keeper) revert NotKeeper();
        if (p.offerToken != address(identityMd)) revert WrongCollection();
        if (p.considerationToken != address(0)) revert NotEthListing();
        if (p.offerAmount != 1) revert NotSingleNft();

        uint256 cost = orderCost(p);
        uint256 limit = maxPay < maxSeatPrice ? maxPay : maxSeatPrice;
        if (cost > limit) revert PriceTooHigh(cost, limit);
        if (address(this).balance < cost) revert InsufficientEth(cost, address(this).balance);

        tokenId = p.offerIdentifier;
        bool ok = seaport.fulfillBasicOrder{value: cost}(p);
        if (!ok) revert FillFailed();

        // the seat is ours now — hand it to the vault that pairs and runs it
        identityMd.transferFrom(address(this), seatVault, tokenId);
        emit SeatBought(tokenId, p.offerer, cost);
    }

    /// return idle ETH to the vault. Destination is fixed (nothing can be stolen); restricted to the
    /// keeper or the vault so it can't be front-run to grief a pending buySeat by emptying the balance.
    function rescueEth() external nonReentrant {
        if (msg.sender != keeper && msg.sender != seatVault) revert NotKeeper();
        uint256 bal = address(this).balance;
        if (bal == 0) return;
        (bool ok,) = payable(seatVault).call{value: bal}("");
        require(ok, "rescue failed");
        emit EthRescued(bal);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
