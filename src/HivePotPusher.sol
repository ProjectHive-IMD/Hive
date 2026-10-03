// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Across V3 SpokePool (Robinhood Chain) — the one entry point we use.
interface IAcrossSpokePool {
    function depositV3(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityParameter,
        bytes calldata message
    ) external payable;
}

/**
 * @title HivePotPusher
 * @notice The code the $HIVE seat-pot wallet (0x84b3) on Robinhood Chain points to through EIP-7702.
 *
 *         The trading-fee splitter is immutable and pays the seat share to that wallet forever, and the
 *         seats are bought on Ethereum by the SeatBuyer contract. This gives the wallet exactly ONE extra
 *         ability so a bot can move the pot across WITHOUT holding the wallet's key:
 *
 *           push(): send the wallet's ETH through Across to the SeatBuyer on Ethereum — and nowhere else.
 *
 *         - the destination contract and chain are fixed at deploy (no parameter can redirect the money);
 *         - the bridge fee is capped (maxFeeBps); if no relayer fills, Across refunds the wallet itself;
 *         - only the bot (or the wallet itself) can trigger it, and a gas reserve always stays behind;
 *         - it adds a door, it removes none: the wallet's own private key keeps full control and can drop
 *           this code at any time by signing a new authorization;
 *         - stateless (immutables only), so it never reads or writes the wallet's storage;
 *         - it still accepts ETH (so fee harvests keep landing) and safe NFT/1155 transfers.
 *
 *         This only exists on Robinhood Chain (the authorization is signed for chain 4663). The seats
 *         themselves live on Ethereum, where the wallet stays a plain account.
 */
contract HivePotPusher {
    uint256 public constant DESTINATION_CHAIN = 1; // Ethereum
    uint32 public constant MAX_FILL_WINDOW = 6 hours; // Across's own fillDeadlineBuffer on Robinhood
    uint32 public constant MAX_EXCLUSIVITY = 600; // seconds a quoted relayer may hold the fill

    address public immutable bot; // the only outside caller allowed to push
    IAcrossSpokePool public immutable spokePool; // Across on Robinhood Chain
    address public immutable inputToken; // wrapped ETH on Robinhood (Across wraps the native ETH we send)
    address public immutable outputToken; // WETH on Ethereum (delivered as ETH, or WETH the buyer unwraps)
    address public immutable seatBuyer; // the recipient on Ethereum — fixed forever
    uint256 public immutable maxFeeBps; // most the bridge may keep, in basis points
    uint256 public immutable minPush; // no dust pushes
    uint256 public immutable gasReserve; // always left in the wallet for its own gas

    event PotPushed(uint256 amount, uint256 outputAmount, uint32 fillDeadline);

    error NotAllowed();
    error BadAmount();
    error FeeTooHigh();
    error BadTiming();

    constructor(
        address _bot,
        IAcrossSpokePool _spokePool,
        address _inputToken,
        address _outputToken,
        address _seatBuyer,
        uint256 _maxFeeBps,
        uint256 _minPush,
        uint256 _gasReserve
    ) {
        require(
            _bot != address(0) && address(_spokePool) != address(0) && _inputToken != address(0)
                && _outputToken != address(0) && _seatBuyer != address(0) && _maxFeeBps <= 500,
            "bad arg"
        );
        bot = _bot;
        spokePool = _spokePool;
        inputToken = _inputToken;
        outputToken = _outputToken;
        seatBuyer = _seatBuyer;
        maxFeeBps = _maxFeeBps;
        minPush = _minPush;
        gasReserve = _gasReserve;
    }

    /// fee harvests (and anything else) keep arriving as normal
    receive() external payable {}

    /**
     * Send `amount` of this wallet's ETH to the SeatBuyer on Ethereum via Across. The bot passes the
     * quote it got from Across (outputAmount, quoteTimestamp, fillDeadline, optional exclusive relayer);
     * everything that decides WHERE the money goes is fixed here.
     */
    function push(
        uint256 amount,
        uint256 outputAmount,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        address exclusiveRelayer,
        uint32 exclusivityParameter
    ) external {
        if (msg.sender != bot && msg.sender != address(this)) revert NotAllowed();
        if (amount < minPush || amount + gasReserve > address(this).balance) revert BadAmount();
        if (outputAmount > amount) revert BadAmount();
        if (outputAmount * 10_000 < amount * (10_000 - maxFeeBps)) revert FeeTooHigh();
        if (fillDeadline <= block.timestamp || fillDeadline > block.timestamp + MAX_FILL_WINDOW) revert BadTiming();
        if (exclusivityParameter > MAX_EXCLUSIVITY) revert BadTiming();

        spokePool.depositV3{value: amount}(
            address(this), // depositor: any refund comes back to this wallet
            seatBuyer,
            inputToken,
            outputToken,
            amount,
            outputAmount,
            DESTINATION_CHAIN,
            exclusiveRelayer,
            quoteTimestamp,
            fillDeadline,
            exclusivityParameter,
            ""
        );
        emit PotPushed(amount, outputAmount, fillDeadline);
    }

    // accept safe transfers so nothing sent to the wallet on Robinhood can bounce
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return 0xf23a6e61;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return 0xbc197c81;
    }
}
