// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @notice Mock of a compliance-gated ERC-20 like GLD (Robinhood beacon proxy -> Stock implementation):
 *         every transfer checks a pause flag and a per-account blocklist. Two failure styles:
 *         `Mode.Revert` reverts with a custom error (what GLD does), `Mode.ReturnFalse` returns false.
 */
contract MockBlocklistToken is ERC20 {
    enum Mode {
        Revert,
        ReturnFalse
    }

    error AccountBlocked(address account);
    error EnforcedPause();

    Mode public mode;
    bool public paused;
    mapping(address => bool) public blocked;

    constructor(Mode mode_) ERC20("Mock GLD", "GLD") {
        mode = mode_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function setPaused(bool isPaused) external {
        paused = isPaused;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (paused) {
            if (mode == Mode.Revert) revert EnforcedPause();
            return false;
        }
        if (blocked[to] || blocked[msg.sender]) {
            if (mode == Mode.Revert) revert AccountBlocked(blocked[to] ? to : msg.sender);
            return false;
        }
        return super.transfer(to, amount);
    }
}
