# Sentinel: a neural network that runs inside a reactive contract

Reactive Omni Buildathon, track **Reactive Meets AI**.

> A 6-8-1 neural network is executed **on-chain inside `react()`** on Reactive Network. It scores every price move of a pool on Base Sepolia. When it flags a manipulation-style move, it trips a circuit breaker that freezes withdrawals on Base Sepolia. The AI is not the tool that wrote the code: **it is the part of the running system that decides what the reactive contract does next.**

## The loop

```
Base Sepolia: a swap moves the pool    -> MiniPair emits Sync(r0, r1)
Reactive Lasna: AnomalySentinel.react()
     computes the return vs the last price, keeps a 3-return window,
     runs SentinelModel.score(r0, r1, r2)   <- the neural network, on-chain
     emits Scored(price, return, score)
     score > 0  -> requests callback trip(score, originBlock)
Base Sepolia: CircuitBreaker.trip()    -> withdrawals frozen; latency recorded
```

## The model

| | |
|---|---|
| Architecture | 6 inputs, 8 ReLU hidden units, 1 logit output |
| Inputs | last three returns `r0, r1, r2` (percent, 1e6 fixed point) plus `abs(r0)`, `abs(r1)`, `abs(r0 + r1)` |
| Training | Adam on 20,000 labelled synthetic return windows. Normal trading is Gaussian noise (σ = 0.25%) plus legitimate moves up to about 1.7%. Anomalies are single 3–30% spikes, pump-and-dumps and fast two-step runs. |
| Held-out accuracy | **99.98%** (5,000 windows: 0 false positives, 1 false negative) |
| On-chain form | weights quantized to 1e6 fixed point, integer inference in `SentinelModel.sol`; the quantized model agrees with the float model on **100%** of 2,000 checks |

The model is honest about its scope: it was trained on synthetic data and is a demonstration of on-chain inference in a reactive loop, not a production manipulation detector. Retraining on real pool data only means replacing 65 constants.

## Live run on testnet

Contracts:

| | Chain | Address |
|---|---|---|
| `AnomalySentinel` | Reactive Lasna | [0x4FC8…8549](https://lasna.reactscan.net/address/0x4FC812DFE1c4B1d316d528668D38246CC79b8549) (same address as the pair below by nonce coincidence, on a different chain) |
| `CircuitBreaker` | Base Sepolia | [0x064E…d8D0](https://sepolia.basescan.org/address/0x064Ee5E1127016DB7dA6A29755D83Ca02779d8D0) |
| `MiniPair` (watched pool) | Base Sepolia | [0x4FC8…8549](https://sepolia.basescan.org/address/0x4FC812DFE1c4B1d316d528668D38246CC79b8549) |

Deploys: breaker [0x991c…80d8](https://sepolia.basescan.org/tx/0x991cfbd8a9b2bb3c59cdc9cb38c1e9757fc45e2178bd0a933a23e7fc104580d8), sentinel [0x3fd0…5688](https://lasna.reactscan.net/tx/0x3fd023dba10b0e2d8f457f8864659cee78a187ba9333d5b18676deb45ddc5688).

What the network decided, swap by swap (each score was computed on-chain on Lasna):

| Swap (Base Sepolia) | Return | Score (logit, 1e6) | Decision | Sentinel tx (Lasna) |
|---|---|---|---|---|
| [0x6530…2f80](https://sepolia.basescan.org/tx/0x6530ea6639c56d305df6421bcf8680d2a9426448d68fb220fbb55733222f2f80) | −0.40% | −15,106,900 | normal | [0x3b76…aa64](https://lasna.reactscan.net/tx/0x3b76726da95b2d159997077b84d5b608d3310069e38aef58ee25a5cc787baa64) |
| [0x7636…0331](https://sepolia.basescan.org/tx/0x763618c22d6c2dd348740938610bbc162db16c624e0761dd92fb3179c43b0331) | +0.50% | −14,730,171 | normal | [0x207d…a8a3](https://lasna.reactscan.net/tx/0x207d25697f30aa14ff2112720ba730f12bc921a476bf111de5cf7be914cda8a3) |
| [0xc3f4…42eb](https://sepolia.basescan.org/tx/0xc3f4733ce316e5ef5f11260b6debdf38664e3181eaba4164f037672ea89d42eb) | −0.69% | −12,549,720 | normal | [0x1bbb…8e8d](https://lasna.reactscan.net/tx/0x1bbbc954320336cbf6e4109878f45647b00742209f356b55c5ab54c482bf8e8d) |
| [0x5fcc…8926](https://sepolia.basescan.org/tx/0x5fcc1b57ef3ff67934e70214dfd029c251994740f5bf1c11e3d34f3ecdcd8926) | +0.30% | −15,559,462 | normal | [0xaf7d…a4c0](https://lasna.reactscan.net/tx/0xaf7dede1477d14b8ab5105b5123f5dde4f133dee5ecb6bf1314d0c84f92fa4c0) |
| **[0x7815…54d9](https://sepolia.basescan.org/tx/0x781567c60a5a55f53a52f00fa8ff7cef11e9a17d4127f14135ffaba2fe7054d9)** (dump) | **−35.86%** | **+111,395,574** | **anomaly: trip** | **[0x057c…3177](https://lasna.reactscan.net/tx/0x057cbe01a7f2ad6c0575cb1dedbdf939ce68eccdc2b906bdeae9f2428fcb3177)** |

The breaker was tripped on Base Sepolia by [0xbe48…3a36](https://sepolia.basescan.org/tx/0xbe48845df3333c43edfcdf371bd18dbe37f5530507f502471ff6a11d02293a36): **8 blocks (about 1.6 s) after the dump**, with `latencyBlocks` recorded on-chain. A withdrawal attempted afterwards reverts with `Frozen()`.

## Tests

```bash
forge test
```

**11/11 passing.**

- **`ModelTest`:** `SentinelModel.score` reproduces the reference logits of the trained model exactly (calm, legitimate 1.5% move, −12% spike, +8% spike, pump-and-dump, two-step run, flat). Fuzz test: no window with all returns within ±0.5% is ever flagged.
- **`BreakerTest`:** a trip freezes withdrawals; only the proxy plus the authorized sentinel can trip; the owner resets and withdrawals resume.
- **`SentinelTest`** (Reactive's system contract mocked with `vm.etch`): 3 subscriptions; normal trading never trips; a spike trips with the origin block in the payload; no duplicate requests while pending or tripped, and it re-arms after `Reset`; ignores other sources; only the system contract can call `react`.

Built with AI assistance (Claude Code). The trained model itself is part of the running system.
