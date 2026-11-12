// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

/// @title CircuitBreaker
/// @notice A guarded ETH vault on the origin chain. Deposits are always open; withdrawals
///         freeze while the breaker is tripped. Only Reactive Network's callback proxy, on
///         behalf of the authorized AnomalySentinel, can trip it, so the neural network
///         running inside the reactive contract decides when to freeze. The owner resets it.
contract CircuitBreaker is AbstractCallback {
    address public immutable owner;
    bool public tripped;
    uint256 public trips;
    mapping(address => uint256) public balanceOf;

    event Tripped(int256 score, uint256 originBlock, uint256 executedBlock, uint256 latencyBlocks);
    event Reset(address by);
    event Deposit(address indexed who, uint256 amount);
    event Withdraw(address indexed who, uint256 amount);

    error NotOwner();
    error Frozen();

    constructor(IPayable callbackProxy_, address sentinel_) payable AbstractCallback(callbackProxy_, sentinel_) {
        owner = msg.sender;
    }

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        if (tripped) revert Frozen();
        balanceOf[msg.sender] -= amount;
        (bool ok, ) = msg.sender.call{ value: amount }("");
        require(ok, "transfer failed");
        emit Withdraw(msg.sender, amount);
    }

    /// @notice Reactive callback. `rvm_` is overwritten by the proxy with the sentinel's address.
    function trip(address rvm_, int256 score, uint256 originBlock)
        external onlyServiceProvider onlyCallbackSender(rvm_)
    {
        if (tripped) return;
        tripped = true;
        trips += 1;
        emit Tripped(score, originBlock, block.number, block.number > originBlock ? block.number - originBlock : 0);
    }

    function reset() external {
        if (msg.sender != owner) revert NotOwner();
        tripped = false;
        emit Reset(msg.sender);
    }
}
