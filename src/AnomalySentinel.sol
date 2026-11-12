// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { SentinelModel } from "./SentinelModel.sol";

/// @title AnomalySentinel
/// @notice Runs a neural network inside react(). Every `Sync` from the watched pool updates a
///         window of the last three returns, and the model scores it on-chain. When the model
///         flags an anomaly, the sentinel trips the CircuitBreaker on the origin chain through a
///         Reactive callback. The AI is part of the running system: it decides what the reactive
///         contract does next.
contract AnomalySentinel is IReactive, AbstractReactive {
    uint256 public constant SYNC_TOPIC_0 = uint256(keccak256("Sync(uint112,uint112)"));
    uint256 public constant TRIPPED_TOPIC_0 = uint256(keccak256("Tripped(int256,uint256,uint256,uint256)"));
    uint256 public constant RESET_TOPIC_0 = uint256(keccak256("Reset(address)"));
    uint64 public constant CALLBACK_GAS_LIMIT = 600_000;

    uint256 public immutable originChainId;
    address public immutable pair;
    address public immutable breaker;

    uint256 public lastPrice;
    int256 public r0;
    int256 public r1;
    int256 public r2;
    int256 public lastScore;
    uint256 public scored;
    bool public breakerTripped;
    bool public pending;

    event Scored(uint256 price, int256 ret, int256 score, uint256 originBlock);
    event TripRequested(int256 score, uint256 originBlock);

    constructor(uint256 originChainId_, address pair_, address breaker_) payable {
        originChainId = originChainId_;
        pair = pair_;
        breaker = breaker_;
        SYSTEM.subscribe(originChainId_, pair_, SYNC_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(originChainId_, breaker_, TRIPPED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(originChainId_, breaker_, RESET_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @notice Score an arbitrary window (percent returns scaled by 1e6, newest first).
    function scoreOf(int256 a, int256 b, int256 c) external pure returns (int256) {
        return SentinelModel.score(a, b, c);
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log) external onlySystem {
        if (log.chainId != originChainId) return;

        if (log.contractAddress == breaker) {
            if (log.topic0 == TRIPPED_TOPIC_0) { breakerTripped = true; pending = false; }
            else if (log.topic0 == RESET_TOPIC_0) { breakerTripped = false; pending = false; }
            return;
        }

        if (log.contractAddress != pair || log.topic0 != SYNC_TOPIC_0) return;
        (uint256 res0, uint256 res1) = abi.decode(log.data, (uint256, uint256));
        if (res0 == 0) return;
        uint256 p = (res1 * 1e18) / res0;
        uint256 prev = lastPrice;
        lastPrice = p;
        if (prev == 0) return;

        // percent return scaled by 1e6: (p - prev) / prev * 100 * 1e6
        int256 ret = ((int256(p) - int256(prev)) * 1e8) / int256(prev);
        r2 = r1; r1 = r0; r0 = ret;
        int256 z = SentinelModel.score(r0, r1, r2);
        lastScore = z;
        scored += 1;
        emit Scored(p, ret, z, log.blockNumber);

        if (z > 0 && !breakerTripped && !pending) {
            pending = true;
            emit TripRequested(z, log.blockNumber);
            SYSTEM.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: originChainId,
                    recipient: breaker,
                    gasLimit: CALLBACK_GAS_LIMIT,
                    payload: abi.encodeWithSignature("trip(address,int256,uint256)", address(0), z, log.blockNumber)
                })
            );
        }
    }
}
