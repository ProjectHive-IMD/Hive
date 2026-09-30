// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title HiveStaking
 * @notice Stake $HIVE, earn IMD pro-rata, weighted by a loyalty multiplier that grows the longer you
 *         stay staked. IMD is what the seats actually earn — holders receive what the NFTs get them.
 *         Rewards are deposited by the keeper (permissionless); holders claim whenever they like.
 *         No owner, no admin keys, no upgradability, no pause — every parameter is fixed at
 *         deployment. This is the holder side of the $HIVE flywheel: the seats' earnings are bridged
 *         back to this chain, consolidated to IMD, and streamed in here.
 *
 * Weighting: weight = amount * multiplier. The multiplier steps up with time held:
 *   < 7 days     -> 1.00x
 *   >= 7 days     -> 1.25x
 *   >= 30 days    -> 1.50x
 *   >= 90 days    -> 2.00x
 * Adding to a stake blends your stake-time by amount (a small top-up barely dents your loyalty).
 * Unstaking returns the withdrawn tokens and drops their weight; the tokens you leave staked keep
 * their clock. The multiplier is applied lazily — it advances a tier when you next stake, unstake,
 * claim, or when anyone calls poke() on you — so crossing a tier boundary while idle means your
 * higher rate starts from your next interaction, not retroactively. Claiming is the cheap way to
 * lock in a new tier.
 *
 * Accounting is the standard "accumulated reward per weight" pattern (à la MasterChef), extended so
 * a holder's weight can change; pending is always settled at the old weight before the weight moves.
 */
contract HiveStaking is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ config (immutable)
    IERC20 public immutable stakeToken; // $HIVE
    IERC20 public immutable rewardToken; // IMD (what the seats earn)

    uint256 public constant PRECISION = 1e18;
    uint256 public constant BPS = 10_000;

    // loyalty tiers (seconds held -> multiplier in bps of the staked amount)
    uint256 public constant TIER1_AT = 7 days;
    uint256 public constant TIER2_AT = 30 days;
    uint256 public constant TIER3_AT = 90 days;
    uint256 public constant MULT_BASE = 10_000; // 1.00x
    uint256 public constant MULT_T1 = 12_500; // 1.25x
    uint256 public constant MULT_T2 = 15_000; // 1.50x
    uint256 public constant MULT_T3 = 20_000; // 2.00x

    // ------------------------------------------------------------------ state
    struct Stake {
        uint128 amount; // $HIVE staked
        uint64 since; // (amount-weighted) stake timestamp for the multiplier
        uint256 weight; // cached amount * multiplier / BPS
        uint256 rewardDebt; // accRewardPerWeight snapshot
        uint256 pending; // settled-but-unclaimed IMD
    }

    mapping(address => Stake) public stakes;
    uint256 public totalStaked; // sum of amounts
    uint256 public totalWeight; // sum of cached weights
    uint256 public accRewardPerWeight; // scaled by PRECISION
    uint256 public rewardCarry; // IMD deposited while nothing was staked, rolled into the next deposit

    // ------------------------------------------------------------------ events
    event Staked(address indexed user, uint256 amount, uint256 newAmount, uint256 weight);
    event Unstaked(address indexed user, uint256 amount, uint256 newAmount, uint256 weight);
    event Claimed(address indexed user, uint256 amount);
    event RewardDeposited(address indexed from, uint256 amount, uint256 accRewardPerWeight);
    event WeightUpdated(address indexed user, uint256 weight, uint256 multiplierBps);

    error ZeroAmount();
    error InsufficientStake();

    constructor(IERC20 _stakeToken, IERC20 _rewardToken) {
        require(address(_stakeToken) != address(0) && address(_rewardToken) != address(0), "token=0");
        require(_stakeToken != _rewardToken, "stake==reward");
        stakeToken = _stakeToken;
        rewardToken = _rewardToken;
    }

    // ------------------------------------------------------------------ multiplier / weight
    function _multBps(uint64 since) internal view returns (uint256) {
        if (since == 0) return MULT_BASE;
        uint256 held = block.timestamp - since;
        if (held >= TIER3_AT) return MULT_T3;
        if (held >= TIER2_AT) return MULT_T2;
        if (held >= TIER1_AT) return MULT_T1;
        return MULT_BASE;
    }

    /// current loyalty multiplier for a holder, in bps (10000 = 1.00x)
    function multiplierBps(address user) external view returns (uint256) {
        return _multBps(stakes[user].since);
    }

    // ------------------------------------------------------------------ internal accounting
    /// accrue rewards onto the user's pending at their CURRENT cached weight, then snapshot the debt
    function _settle(Stake storage s) internal {
        uint256 acc = accRewardPerWeight;
        if (s.weight != 0) {
            s.pending += (s.weight * (acc - s.rewardDebt)) / PRECISION;
        }
        s.rewardDebt = acc;
    }

    /// recompute the cached weight from the current multiplier and re-sync totalWeight
    function _refreshWeight(address user, Stake storage s) internal {
        uint256 nw = (uint256(s.amount) * _multBps(s.since)) / BPS;
        if (nw != s.weight) {
            totalWeight = totalWeight - s.weight + nw;
            s.weight = nw;
        }
        emit WeightUpdated(user, s.weight, _multBps(s.since));
    }

    /// settle + advance a holder's tier lazily; anyone may call so tiers can be kept current
    function poke(address user) public {
        Stake storage s = stakes[user];
        if (s.amount == 0) return;
        _settle(s);
        _refreshWeight(user, s);
    }

    // ------------------------------------------------------------------ actions
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Stake storage s = stakes[msg.sender];
        _settle(s);

        uint256 a0 = s.amount;
        if (a0 == 0) {
            s.since = uint64(block.timestamp);
        } else {
            // amount-weighted blend of the old stake-time and now
            s.since = uint64((uint256(a0) * s.since + amount * block.timestamp) / (a0 + amount));
        }
        s.amount = uint128(a0 + amount);
        totalStaked += amount;
        _refreshWeight(msg.sender, s);

        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount, s.amount, s.weight);
    }

    function unstake(uint256 amount) external nonReentrant {
        Stake storage s = stakes[msg.sender];
        if (amount == 0) revert ZeroAmount();
        if (amount > s.amount) revert InsufficientStake();
        _settle(s);

        s.amount = uint128(uint256(s.amount) - amount);
        totalStaked -= amount;
        // the tokens left staked keep their clock (s.since unchanged); the withdrawn weight just leaves
        _refreshWeight(msg.sender, s);

        stakeToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount, s.amount, s.weight);
    }

    /// claim accrued IMD rewards
    function claim() external nonReentrant returns (uint256 amount) {
        Stake storage s = stakes[msg.sender];
        _settle(s);
        _refreshWeight(msg.sender, s); // keep the tier current for whoever bothers to claim
        amount = s.pending;
        if (amount == 0) return 0;
        s.pending = 0;
        rewardToken.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    /// deposit IMD to distribute across all stakers (the keeper calls this; anyone may top up)
    function depositReward(uint256 amount) public nonReentrant {
        // credit the ACTUAL amount received, not the nominal `amount`, so a fee-on-transfer or
        // deflationary reward token can never record more liability than the contract holds
        uint256 received = 0;
        if (amount != 0) {
            uint256 balBefore = rewardToken.balanceOf(address(this));
            rewardToken.safeTransferFrom(msg.sender, address(this), amount);
            received = rewardToken.balanceOf(address(this)) - balBefore;
        }
        uint256 total = received + rewardCarry;
        if (total == 0) return;
        if (totalWeight == 0) {
            rewardCarry = total; // nothing staked yet — hold it for the first stakers
            return;
        }
        uint256 inc = (total * PRECISION) / totalWeight;
        if (inc == 0) {
            rewardCarry = total; // too small to distribute against the current weight — keep rolling, don't burn it
            return;
        }
        rewardCarry = 0;
        accRewardPerWeight += inc;
        emit RewardDeposited(msg.sender, total, accRewardPerWeight);
    }

    // ------------------------------------------------------------------ views
    /// claimable IMD for a holder right now (uses the cached weight; poke to refresh a stale tier)
    function pending(address user) external view returns (uint256) {
        Stake storage s = stakes[user];
        uint256 extra = s.weight == 0 ? 0 : (s.weight * (accRewardPerWeight - s.rewardDebt)) / PRECISION;
        return s.pending + extra;
    }

    function stakeOf(address user)
        external
        view
        returns (uint256 amount, uint256 since, uint256 weight, uint256 multBps, uint256 claimable)
    {
        Stake storage s = stakes[user];
        amount = s.amount;
        since = s.since;
        multBps = _multBps(s.since);
        weight = s.weight;
        uint256 extra = s.weight == 0 ? 0 : (s.weight * (accRewardPerWeight - s.rewardDebt)) / PRECISION;
        claimable = s.pending + extra;
    }
}
