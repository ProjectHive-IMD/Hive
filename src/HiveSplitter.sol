// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IPonsFeeEscrow {
    function claim() external returns (uint256);
    function balanceOf(address recipient) external view returns (uint256);
}

/**
 * @title HiveSplitter
 * @notice Immutable, no-admin fee router. It is set as the $HIVE creator-fee recipient on Pons v2, so
 *         the ETH trading fees accrue to it in the Pons escrow. Anyone may call harvest(): it claims
 *         the escrow balance (native ETH) and splits it by fixed shares — the seat treasury (buys IMD
 *         seats), ops (running costs), and the team. The money goes escrow → splitter → recipients
 *         with no owner, no way to change the percentages, and no personal wallet in the path.
 *
 * Shares are the 5.5% / 0.2% / 0.5% fee plan expressed against the 6.2% a creator nets on Pons v2
 * (5.5% tax + 0.7% kickback): 5.5/6.2, 0.2/6.2, 0.5/6.2. Buyers see 6.5% total (the 5.5% tax plus
 * Pons's 1% layer, of which Pons keeps 0.3% and kicks 0.7% back, funding the ops + team lines).
 */
contract HiveSplitter is ReentrancyGuard {
    uint256 public constant SEAT_BPS = 8871; // ~88.71% -> seat treasury
    uint256 public constant OPS_BPS = 323; //  ~3.23%  -> ops / running costs
    uint256 public constant TEAM_BPS = 806; // ~8.06%  -> team
    uint256 public constant BPS = 10_000;

    address public immutable seatTreasury;
    address public immutable ops;
    address public immutable team;
    IPonsFeeEscrow public immutable escrow; // Pons v2 fee escrow (may be address(0) if fees arrive directly)

    event Distributed(uint256 seat, uint256 ops, uint256 team);

    error ZeroAddress();
    error NoBalance();
    error SendFailed();

    constructor(address _seatTreasury, address _ops, address _team, address _escrow) {
        if (_seatTreasury == address(0) || _ops == address(0) || _team == address(0)) revert ZeroAddress();
        seatTreasury = _seatTreasury;
        ops = _ops;
        team = _team;
        escrow = IPonsFeeEscrow(_escrow); // escrow == 0 => harvest() just splits whatever ETH is here
    }

    receive() external payable {}

    /// claim accrued ETH fees from the Pons escrow (if any) and split them. Permissionless; never reverts on empty.
    function harvest() external nonReentrant {
        if (address(escrow) != address(0) && escrow.balanceOf(address(this)) > 0) {
            escrow.claim();
        }
        uint256 bal = address(this).balance;
        if (bal > 0) _distribute(bal);
    }

    /// split the whole current balance seat/ops/team by the fixed shares (rounding remainder to team)
    function distribute() external nonReentrant {
        uint256 bal = address(this).balance;
        if (bal == 0) revert NoBalance();
        _distribute(bal);
    }

    function _distribute(uint256 bal) internal {
        uint256 seatAmt = (bal * SEAT_BPS) / BPS;
        uint256 opsAmt = (bal * OPS_BPS) / BPS;
        uint256 teamAmt = bal - seatAmt - opsAmt;
        _send(seatTreasury, seatAmt);
        _send(ops, opsAmt);
        _send(team, teamAmt);
        emit Distributed(seatAmt, opsAmt, teamAmt);
    }

    function _send(address to, uint256 amt) internal {
        if (amt == 0) return;
        (bool ok,) = payable(to).call{value: amt}("");
        if (!ok) revert SendFailed();
    }
}
