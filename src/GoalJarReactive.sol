// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

// GoalJarReactive — reactive contract on Reactive Lasna (chain 5318007).
//
// Subscribes to GoalJarVault.Deposited on Base Sepolia, keeps a running
// total, and requests a callback to the vault when progress thresholds
// (50% / 90%) and the goal (100%) are reached.
//
// Written against the CURRENT (Omni) Reactive docs
// (dev.reactive.network "Reactive Contracts", crawled 2026-11-27):
// SYSTEM at 0x8888...8888, SYSTEM.subscribe, react() with onlySystem,
// callbacks via SYSTEM.requestCallbackV_1_0(CallbackConfiguration_V_1_0).
//
// Requires the Omni library (Reactive-Network/reactive-lib-omni), which
// provides the @reactive/src/base/* imports below.
//
// Deployment order (breaks the vault<->reactive address cycle on this side,
// per the docs' "Deployment Order"):
//   1. Deploy this contract (goal only; no vault yet).
//   2. Deploy GoalJarVault with (callback proxy, this contract's address).
//   3. Call start(vault) here: records the vault and subscribes.

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

contract GoalJarReactive is AbstractReactive {
    uint256 public constant BASE_SEPOLIA = 84532;

    // keccak256("Deposited(address,uint256,uint256)") — canonical topic0,
    // confirmed via Reactive MCP plan_rc on 2026-11-27.
    uint256 public constant DEPOSITED_TOPIC0 =
        0x73a19dd210f1a7f902193214c0ee91dd35ee5b4d920cba8d519eca65a7b488ca;

    uint64 private constant GAS_LIMIT = 1_000_000;

    address public owner;
    uint256 public immutable goal;

    address public vault;
    bool public started;

    uint256 public totalSeen;
    bool public marked50;
    bool public marked90;
    bool public goalSent;

    event Started(address vault);
    event ThresholdCrossed(uint256 totalSeen, uint256 goal);

    constructor(uint256 goal_) payable {
        require(goal_ > 0, "goal is zero");
        owner = msg.sender;
        goal = goal_;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /// @notice Records the vault and subscribes to its Deposited events.
    /// @dev Subscribing at runtime (not only in the constructor) is
    /// explicitly supported by the current docs.
    function start(address vault_) external onlyOwner {
        require(!started, "already started");
        require(vault_ != address(0), "zero vault");
        started = true;
        vault = vault_;
        SYSTEM.subscribe(
            BASE_SEPOLIA,
            vault_,
            DEPOSITED_TOPIC0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        emit Started(vault_);
    }

    /// @inheritdoc IReactive
    function react(LogRecord memory log_) external onlySystem {
        // Ignore anything that is not the vault's Deposited event. Per the
        // docs, non-matching logs should fall through, never revert.
        if (log_.topic0 != DEPOSITED_TOPIC0 || log_.contractAddress != vault) {
            return;
        }
        // Deposited(address indexed user, uint256 amount, uint256 totalDeposited)
        // user is topic1; amount and totalDeposited are packed in data.
        (uint256 amount, ) = abi.decode(log_.data, (uint256, uint256));
        totalSeen += amount;

        if (!goalSent && totalSeen >= goal) {
            goalSent = true;
            emit ThresholdCrossed(totalSeen, goal);
            _requestCallback(
                abi.encodeWithSignature("onGoalReached(address)", address(0))
            );
        } else if (!marked90 && totalSeen * 10 >= goal * 9) {
            marked90 = true;
            _requestCallback(
                abi.encodeWithSignature(
                    "onProgress(address,uint256)",
                    address(0),
                    totalSeen
                )
            );
        } else if (!marked50 && totalSeen * 2 >= goal) {
            marked50 = true;
            _requestCallback(
                abi.encodeWithSignature(
                    "onProgress(address,uint256)",
                    address(0),
                    totalSeen
                )
            );
        }
    }

    function _requestCallback(bytes memory payload) internal {
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: BASE_SEPOLIA,
                recipient: vault,
                gasLimit: GAS_LIMIT,
                payload: payload
            })
        );
    }

    /// @notice Settles outstanding debt from this contract's own balance.
    function coverDebt() external {
        _coverDebt();
    }
}
