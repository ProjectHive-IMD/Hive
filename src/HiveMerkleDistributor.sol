// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title HiveMerkleDistributor
 * @notice The "all holders get a slice" lane. Each round, the publisher (the keeper) posts a merkle
 *         root committing to (holder -> amount) computed OFF-CHAIN from a hardened snapshot:
 *         time-weighted average balance (TWAB) over the period, a minimum-balance floor, and an
 *         explicit exclusion list (curve, pool, treasury, the staking contract, burn). The pot is the
 *         20% the router forwards here. Holders don't have to do anything — anyone (the keeper) can
 *         push each holder's share on their behalf, because a claim always pays the address encoded in
 *         the leaf, never msg.sender. claim() is also there as a self-serve backstop.
 *
 * What the contract guarantees on-chain (so the off-chain snapshot only has to be *honest*, and it's
 * publicly recomputable):
 *   - Conservation: a round can only reserve funds already in the contract; the sum of live rounds
 *     never exceeds the balance, so nothing can be double-spent or over-committed.
 *   - Correct destination: funds go to the leaf's `account`, never to whoever calls claim.
 *   - No double claim: each (round, account) pays at most once.
 *   - No drain: there is NO owner withdrawal. The only non-claim outflow is sweeping a round's
 *     UNCLAIMED remainder to the treasury, and only after sweepDelay.
 *
 * Trust that remains (and how it's bounded): the publisher chooses the root, so a dishonest/compromised
 * publisher could post a self-dealing root. Bounds: (1) roots are public + recomputable from chain data,
 * (2) a round is not claimable until claimDelay elapses — a visible window, and (3) an optional guardian
 * can cancelRound() during that window, returning the funds to the unreserved pool. Run the publisher as
 * a dedicated minimal-privilege key and set a guardian for a real on-chain veto.
 */
contract HiveMerkleDistributor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable rewardToken; // bridged IMD on Robinhood Chain
    address public immutable publisher; // may open rounds (the keeper)
    address public immutable guardian; // may cancel a not-yet-claimable round (0 = disabled)
    address public immutable treasury; // receives swept, long-unclaimed remainders
    uint64 public immutable claimDelay; // a round is claimable only after createdAt + claimDelay
    uint64 public immutable sweepDelay; // a round's unclaimed remainder is sweepable after createdAt + sweepDelay

    struct Round {
        bytes32 root; // merkle root over leaves keccak256(bytes.concat(keccak256(abi.encode(account, amount))))
        uint128 amount; // total IMD committed to this round
        uint128 claimed; // IMD claimed/pushed so far
        uint64 createdAt; // block.timestamp at setRound
        bool cancelled; // guardian-cancelled (unreserves the whole amount)
        bool swept; // remainder swept to treasury (unreserves what was left)
    }

    Round[] private _rounds;
    /// round => account => claimed?
    mapping(uint256 => mapping(address => bool)) public isClaimed;
    /// IMD committed to live (not cancelled/fully-swept) rounds and not yet paid out — reserved, un-openable
    uint256 public totalReserved;

    event RoundOpened(uint256 indexed roundId, bytes32 root, uint256 amount, uint64 claimableAt);
    event Claimed(uint256 indexed roundId, address indexed account, uint256 amount);
    event RoundCancelled(uint256 indexed roundId, uint256 returned);
    event Swept(uint256 indexed roundId, uint256 amount);

    error NotPublisher();
    error NotGuardian();
    error ZeroAddress();
    error InsufficientUnreserved();
    error NoRound();
    error NotClaimableYet();
    error RoundInactive();
    error AlreadyClaimed();
    error BadProof();
    error TooEarlyToSweep();
    error LengthMismatch();

    constructor(
        IERC20 _rewardToken,
        address _publisher,
        address _guardian,
        address _treasury,
        uint64 _claimDelay,
        uint64 _sweepDelay
    ) {
        if (address(_rewardToken) == address(0) || _publisher == address(0) || _treasury == address(0)) {
            revert ZeroAddress();
        }
        require(_sweepDelay >= _claimDelay, "sweep<claim");
        rewardToken = _rewardToken;
        publisher = _publisher;
        guardian = _guardian; // 0 allowed => no veto
        treasury = _treasury;
        claimDelay = _claimDelay;
        sweepDelay = _sweepDelay;
    }

    // ------------------------------------------------------------------ publisher
    /**
     * @notice Open a round for `amount` IMD against `root`. Only funds already sitting in the contract
     *         and not reserved by earlier live rounds can back it. Returns the new round id.
     */
    function setRound(bytes32 root, uint256 amount) external nonReentrant returns (uint256 roundId) {
        if (msg.sender != publisher) revert NotPublisher();
        if (amount == 0 || root == bytes32(0)) revert NoRound();
        if (amount > unreserved()) revert InsufficientUnreserved();
        totalReserved += amount;
        roundId = _rounds.length;
        _rounds.push(
            Round({
                root: root,
                amount: uint128(amount),
                claimed: 0,
                createdAt: uint64(block.timestamp),
                cancelled: false,
                swept: false
            })
        );
        emit RoundOpened(roundId, root, amount, uint64(block.timestamp) + claimDelay);
    }

    // ------------------------------------------------------------------ claim (push or self-serve)
    /// @notice Claim (or push, on someone's behalf) `account`'s share of `roundId`. Pays `account`.
    function claim(uint256 roundId, address account, uint256 amount, bytes32[] calldata proof)
        public
        nonReentrant
    {
        _claim(roundId, account, amount, proof);
    }

    /// @notice Push many holders' shares of one round in a single tx (the keeper's default path).
    function batchClaim(
        uint256 roundId,
        address[] calldata accounts,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external nonReentrant {
        uint256 n = accounts.length;
        if (n != amounts.length || n != proofs.length) revert LengthMismatch();
        for (uint256 i; i < n; ++i) {
            _claim(roundId, accounts[i], amounts[i], proofs[i]);
        }
    }

    function _claim(uint256 roundId, address account, uint256 amount, bytes32[] calldata proof) internal {
        if (roundId >= _rounds.length) revert NoRound();
        Round storage r = _rounds[roundId];
        if (r.cancelled || r.swept) revert RoundInactive();
        if (block.timestamp < r.createdAt + claimDelay) revert NotClaimableYet();
        if (isClaimed[roundId][account]) revert AlreadyClaimed();
        // OZ standard-tree leaf: double-hash of the abi-encoded (account, amount)
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
        if (!MerkleProof.verifyCalldata(proof, r.root, leaf)) revert BadProof();

        isClaimed[roundId][account] = true;
        r.claimed += uint128(amount);
        totalReserved -= amount;
        rewardToken.safeTransfer(account, amount);
        emit Claimed(roundId, account, amount);
    }

    // ------------------------------------------------------------------ guardian / sweep
    /// @notice Guardian may cancel a round while it's still inside its claimDelay window (bad/compromised root).
    function cancelRound(uint256 roundId) external nonReentrant {
        if (msg.sender != guardian || guardian == address(0)) revert NotGuardian();
        if (roundId >= _rounds.length) revert NoRound();
        Round storage r = _rounds[roundId];
        if (r.cancelled || r.swept) revert RoundInactive();
        if (block.timestamp >= r.createdAt + claimDelay) revert NotClaimableYet(); // window has passed; can't cancel a live round
        uint256 back = uint256(r.amount) - r.claimed; // nothing claimed yet during the delay, but be exact
        r.cancelled = true;
        totalReserved -= back;
        emit RoundCancelled(roundId, back);
    }

    /// @notice After sweepDelay, return a round's UNCLAIMED remainder to the treasury so funds never lock forever.
    function sweep(uint256 roundId) external nonReentrant {
        if (roundId >= _rounds.length) revert NoRound();
        Round storage r = _rounds[roundId];
        if (r.cancelled || r.swept) revert RoundInactive();
        if (block.timestamp < r.createdAt + sweepDelay) revert TooEarlyToSweep();
        uint256 remainder = uint256(r.amount) - r.claimed;
        r.swept = true;
        if (remainder != 0) {
            totalReserved -= remainder;
            rewardToken.safeTransfer(treasury, remainder);
        }
        emit Swept(roundId, remainder);
    }

    // ------------------------------------------------------------------ views
    /// @notice IMD in the contract not reserved by a live round — the ceiling for the next setRound().
    function unreserved() public view returns (uint256) {
        uint256 bal = rewardToken.balanceOf(address(this));
        return bal > totalReserved ? bal - totalReserved : 0;
    }

    function roundCount() external view returns (uint256) {
        return _rounds.length;
    }

    function rounds(uint256 roundId)
        external
        view
        returns (bytes32 root, uint256 amount, uint256 claimed, uint64 createdAt, bool cancelled, bool swept)
    {
        Round storage r = _rounds[roundId];
        return (r.root, r.amount, r.claimed, r.createdAt, r.cancelled, r.swept);
    }

    /// @notice True once `roundId` has passed its claimDelay and is still active.
    function isClaimable(uint256 roundId) external view returns (bool) {
        if (roundId >= _rounds.length) return false;
        Round storage r = _rounds[roundId];
        return !r.cancelled && !r.swept && block.timestamp >= r.createdAt + claimDelay;
    }
}
