// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IHiveStaking {
    function depositReward(uint256 amount) external;
    function rewardToken() external view returns (address);
}

/**
 * @title HiveRewardRouter
 * @notice Immutable, no-admin split of the seats' IMD into the "base + bonus" reward model:
 *           - the holder pot (40%) -> the HiveMerkleDistributor: shared by EVERY holder, staked or
 *             not (the snapshot counts staked $HIVE too, so stakers earn this slice as well).
 *           - STAKER_BPS (60%) -> HiveStaking.depositReward(): an EXTRA pot only stakers share,
 *             pro-rata by loyalty weight.
 *         So a staker earns the holder slice AND the staker bonus; a non-staking holder earns the
 *         holder slice. The keeper bridges the IMD the seats earned to Robinhood Chain, drops it here,
 *         and calls route(). The split is fixed at deployment — no owner, no setter, no way to change
 *         who gets what, and no path that can pull funds out to a personal wallet. Enforced by code.
 *
 * Trust surface: route() is permissionless and only ever moves the router's own balance to the two
 * fixed sinks. The staking allowance is set to the staking contract alone, once, in the constructor.
 */
contract HiveRewardRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable rewardToken; // bridged IMD on Robinhood Chain (what the seats earn)
    IHiveStaking public immutable staking; // receives STAKER_BPS — the stakers-only bonus pot — via depositReward()
    address public immutable distributor; // receives the remainder — the 40% pot every holder shares

    uint256 public constant STAKER_BPS = 6000; // 60% -> stakers-only bonus pot (holders share the other 40%)
    uint256 public constant BPS = 10_000;

    event Routed(uint256 total, uint256 toStakers, uint256 toHolders);

    error ZeroAddress();
    error TokenMismatch();

    constructor(IERC20 _rewardToken, IHiveStaking _staking, address _distributor) {
        if (address(_rewardToken) == address(0) || address(_staking) == address(0) || _distributor == address(0)) {
            revert ZeroAddress();
        }
        // the staking contract must pay out the SAME asset we route, or depositReward would pull the wrong token
        if (_staking.rewardToken() != address(_rewardToken)) revert TokenMismatch();
        rewardToken = _rewardToken;
        staking = _staking;
        distributor = _distributor;
        // staking pulls its share via transferFrom inside depositReward(); approve it once, to it alone
        _rewardToken.forceApprove(address(_staking), type(uint256).max);
    }

    /**
     * @notice Split the router's entire rewardToken balance 60/40 (stakers bonus / all-holders pot) and forward each part.
     *         Permissionless, no-admin, no withdraw. The rounding remainder falls to the holder pot.
     *         Never reverts on an empty balance.
     * @return toStakers IMD handed to HiveStaking. @return toHolders IMD sent to the distributor.
     */
    function route() external nonReentrant returns (uint256 toStakers, uint256 toHolders) {
        uint256 bal = rewardToken.balanceOf(address(this));
        if (bal == 0) return (0, 0);
        toStakers = (bal * STAKER_BPS) / BPS;
        toHolders = bal - toStakers;
        // stakers: depositReward pulls `toStakers` via the max allowance set in the constructor.
        // (If nothing is staked yet, HiveStaking carries it internally for the first stakers — not lost.)
        if (toStakers != 0) staking.depositReward(toStakers);
        // holders: fund the distributor; the keeper later opens a round for it against a merkle root.
        if (toHolders != 0) rewardToken.safeTransfer(distributor, toHolders);
        emit Routed(bal, toStakers, toHolders);
    }

    /// @notice Holder-pot share in bps (the complement of STAKER_BPS), for readers/UI.
    function holderBps() external pure returns (uint256) {
        return BPS - STAKER_BPS;
    }
}
