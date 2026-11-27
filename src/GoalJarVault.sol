// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

// GoalJarVault — origin + callback contract on Base Sepolia (chain 84532).
//
// A personal savings jar:
//  - The owner deposits ETH in small steps (each deposit emits `Deposited`).
//  - A reactive contract on Lasna watches those deposits and, once the goal
//    is reached, calls back `onGoalReached`, which moves the flexible
//    balance into a locked balance that cannot be withdrawn until the
//    lock period ends.
//
// Written against the CURRENT (Omni) Reactive docs
// (dev.reactive.network "Callback Contracts", crawled 2026-11-27):
// AbstractCallback(callbackProxy, callbackSender) with both guards —
// onlyServiceProvider (caller is the chain's callback proxy) and
// onlyCallbackSender(first arg) (injected address is our reactive contract).
//
// Base Sepolia callback proxy: 0x476F44b11F5C942c58f4c8E3d0300E5710743585
// (re-check against "Origins & Destinations" in the Reactive docs before
// deploying to a different destination chain).
//
// Requires the Omni library (Reactive-Network/reactive-lib-omni), which
// provides the @reactive/src/base/* imports below.

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

contract GoalJarVault is AbstractCallback {
    address public owner;
    uint256 public goal; // wei
    uint256 public flexible; // withdrawable balance tracked for the jar
    uint256 public locked; // locked balance (goal reached)
    uint256 public lockUntil; // unix timestamp
    uint256 public constant LOCK_PERIOD = 30 days;
    bool public goalFired;

    event Deposited(address indexed user, uint256 amount, uint256 totalDeposited);
    event GoalSet(uint256 goal);
    event ProgressMarked(uint256 totalDeposited, uint256 goal);
    event SavingsLocked(uint256 amount, uint256 lockUntil);
    event Withdrawn(address indexed user, uint256 amount);

    /// @param callbackProxy_ Base Sepolia callback proxy (see header).
    /// @param reactive_ GoalJarReactive address on Lasna; stored immutably
    /// by AbstractCallback as the only authorised callback sender. A wrong
    /// address here is unrecoverable — the vault would need a redeploy.
    /// @param goal_ Savings goal in wei.
    constructor(IPayable callbackProxy_, address reactive_, uint256 goal_)
        payable
        AbstractCallback(callbackProxy_, reactive_)
    {
        require(goal_ > 0, "goal is zero");
        owner = msg.sender;
        goal = goal_;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function setGoal(uint256 goal_) external onlyOwner {
        require(!goalFired, "already locked");
        goal = goal_;
        emit GoalSet(goal_);
    }

    function deposit() external payable onlyOwner {
        require(!goalFired, "already locked");
        flexible += msg.value;
        emit Deposited(msg.sender, msg.value, flexible + locked);
    }

    // --- Callback entry points (called via the Base Sepolia callback proxy).
    // The first argument is an address slot: the network overwrites it with
    // the reactive contract's address, and onlyCallbackSender checks it
    // against the address authorised in the constructor.

    function onProgress(address reactive_, uint256 totalDeposited_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        emit ProgressMarked(totalDeposited_, goal);
    }

    function onGoalReached(address reactive_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        require(!goalFired, "already fired");
        goalFired = true;
        locked += flexible;
        flexible = 0;
        lockUntil = block.timestamp + LOCK_PERIOD;
        emit SavingsLocked(locked, lockUntil);
    }

    function withdraw() external onlyOwner {
        require(block.timestamp >= lockUntil, "still locked");
        uint256 amount = flexible + locked;
        flexible = 0;
        locked = 0;
        goalFired = false;
        (bool ok, ) = msg.sender.call{ value: amount }("");
        require(ok, "transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Settles outstanding callback debt from this contract's own
    /// balance (debt is billed to the recipient, in Base Sepolia ETH).
    function coverDebt() external {
        _coverDebt();
    }

    // receive() is inherited payable from AbstractPayer.
}
