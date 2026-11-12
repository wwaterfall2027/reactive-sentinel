// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { SentinelModel } from "../src/SentinelModel.sol";
import { AnomalySentinel } from "../src/AnomalySentinel.sol";
import { CircuitBreaker } from "../src/CircuitBreaker.sol";

contract MockSystem is ISystemContract {
    uint256 public subs;
    CallbackConfiguration_V_1_0[] internal cbs;
    receive() external payable {}
    function debt(address) external pure returns (uint256) { return 0; }
    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external { subs++; }
    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}
    function requestCallback(CallbackVersion, bytes memory) external pure { revert("unused"); }
    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 memory c) external { cbs.push(c); }
    function count() external view returns (uint256) { return cbs.length; }
    function at(uint256 i) external view returns (CallbackConfiguration_V_1_0 memory) { return cbs[i]; }
}

contract ModelHarness {
    function score(int256 a, int256 b, int256 c) external pure returns (int256) { return SentinelModel.score(a, b, c); }
}

/// @dev Reference logits come from the float-trained model, quantized and run in JS (truncating division).
contract ModelTest is Test {
    ModelHarness m = new ModelHarness();

    function test_MatchesReferenceLogits() public view {
        assertEq(m.score(100000, -200000, 50000), -16244177);     // calm
        assertEq(m.score(1500000, 100000, -100000), -7971640);    // legit 1.5% move
        assertEq(m.score(-12000000, 100000, 0), 34540527);        // -12% spike
        assertEq(m.score(8000000, 0, 0), 20977657);               // +8% spike
        assertEq(m.score(-9000000, 10000000, 0), 30822379);       // pump then dump
        assertEq(m.score(3500000, 3500000, 100000), 18600549);    // fast two-step run
        assertEq(m.score(0, 0, 0), -16659707);                    // flat
    }

    function testFuzz_SmallMovesAreNeverFlagged(int256 a, int256 b, int256 c) public view {
        a = bound(a, -500000, 500000); b = bound(b, -500000, 500000); c = bound(c, -500000, 500000); // within +/-0.5%
        assertLt(m.score(a, b, c), 0);
    }
}

contract BreakerTest is Test {
    CircuitBreaker br;
    address proxy = makeAddr("proxy");
    address sentinel = makeAddr("sentinel");
    address alice = makeAddr("alice");

    function setUp() public {
        br = new CircuitBreaker(IPayable(payable(proxy)), sentinel);
        vm.deal(alice, 1 ether);
        vm.prank(alice); br.deposit{ value: 1 ether }();
    }

    function test_TripFreezesWithdrawals() public {
        vm.prank(proxy); br.trip(sentinel, 123, block.number);
        assertTrue(br.tripped());
        vm.prank(alice); vm.expectRevert(CircuitBreaker.Frozen.selector); br.withdraw(0.1 ether);
    }

    function test_OnlyProxyAndSentinelCanTrip() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, alice, proxy));
        br.trip(sentinel, 1, 1);
        vm.prank(proxy);
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, alice, sentinel));
        br.trip(alice, 1, 1);
    }

    function test_OwnerResetsAndWithdrawalsResume() public {
        vm.prank(proxy); br.trip(sentinel, 1, block.number);
        br.reset();
        vm.prank(alice); br.withdraw(0.4 ether);
        assertEq(alice.balance, 0.4 ether);
        vm.prank(alice); vm.expectRevert(CircuitBreaker.NotOwner.selector); br.reset();
    }
}

contract SentinelTest is Test {
    address constant SYS = 0x8888888888888888888888888888888888888888;
    uint256 constant ORIGIN = 84532;
    MockSystem sys; AnomalySentinel s;
    address pair = makeAddr("pair");
    address breaker = makeAddr("breaker");

    function setUp() public {
        vm.etch(SYS, address(new MockSystem()).code);
        sys = MockSystem(payable(SYS));
        s = new AnomalySentinel(ORIGIN, pair, breaker);
    }

    function _send(address src, uint256 t0, bytes memory data, uint256 blk) internal {
        IReactive.LogRecord memory l;
        l.chainId = ORIGIN; l.contractAddress = src; l.topic0 = t0; l.data = data; l.blockNumber = blk;
        vm.prank(SYS); s.react(l);
    }
    function _sync(uint256 r0_, uint256 r1_, uint256 blk) internal {
        uint256 t = s.SYNC_TOPIC_0();
        _send(pair, t, abi.encode(r0_, r1_), blk);
    }

    function test_ThreeSubscriptions() public view { assertEq(sys.subs(), 3); }

    function test_NormalTradingNeverTrips() public {
        _sync(10_000e18, 20_000e18, 1);   // price 2.000
        _sync(10_010e18, 19_980e18, 2);   // ~ -0.2%
        _sync(10_000e18, 20_000e18, 3);   // ~ +0.2%
        _sync(9_995e18, 20_010e18, 4);
        assertEq(s.scored(), 3);
        assertLt(s.lastScore(), 0);
        assertEq(sys.count(), 0);
    }

    function test_ManipulationSpikeTripsWithOriginBlock() public {
        _sync(10_000e18, 20_000e18, 1);
        _sync(10_010e18, 19_980e18, 2);
        _sync(12_000e18, 16_700e18, 777); // ~ -30% price dump in one swap
        assertGt(s.lastScore(), 0);
        assertEq(sys.count(), 1);
        ISystemContract.CallbackConfiguration_V_1_0 memory c = sys.at(0);
        assertEq(c.chainId, ORIGIN);
        assertEq(c.recipient, breaker);
        assertEq(c.payload, abi.encodeWithSignature("trip(address,int256,uint256)", address(0), s.lastScore(), uint256(777)));
    }

    function test_NoDuplicateWhilePendingOrTripped_RearmsAfterReset() public {
        _sync(10_000e18, 20_000e18, 1);
        _sync(12_000e18, 16_700e18, 2);
        _sync(14_000e18, 14_300e18, 3);   // another big move while pending
        assertEq(sys.count(), 1);
        _send(breaker, s.TRIPPED_TOPIC_0(), "", 4);
        _sync(16_000e18, 12_500e18, 5);   // tripped: still no new request
        assertEq(sys.count(), 1);
        _send(breaker, s.RESET_TOPIC_0(), "", 6);
        _sync(20_000e18, 10_000e18, 7);   // big move after reset: trips again
        assertEq(sys.count(), 2);
    }

    function test_IgnoresOtherSources() public {
        _sync(10_000e18, 20_000e18, 1);
        uint256 t = s.SYNC_TOPIC_0();
        _send(makeAddr("other"), t, abi.encode(uint256(1e18), uint256(100e18)), 2);
        assertEq(s.scored(), 0);
    }

    function test_OnlySystem() public {
        IReactive.LogRecord memory l;
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYS));
        s.react(l);
    }
}
