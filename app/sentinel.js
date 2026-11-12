// Sentinel live: reads the deployed contracts directly. No wallet, no backend, no keys.
import { ethers } from 'https://cdn.jsdelivr.net/npm/ethers@6.13.4/+esm';

export const CFG = {
  sentinel: '0x4FC812DFE1c4B1d316d528668D38246CC79b8549', // AnomalySentinel on Reactive Lasna
  sentinelDeployBlock: 8138149,
  breaker: '0x064Ee5E1127016DB7dA6A29755D83Ca02779d8D0', // CircuitBreaker on Base Sepolia
  breakerDeployBlock: 57683565,
  pair: '0x4FC812DFE1c4B1d316d528668D38246CC79b8549', // MiniPair on Base Sepolia (same address, other chain)
  lasnaRpc: 'https://lasna-rpc.rnk.dev/',
  baseRpcs: ['https://base-sepolia-rpc.publicnode.com', 'https://sepolia.base.org'],
  lasnaTx: 'https://lasna.reactscan.net/tx/',
  baseTx: 'https://sepolia.basescan.org/tx/',
  baseBlock: 'https://sepolia.basescan.org/block/',
};

const SENTINEL_ABI = [
  'event Scored(uint256 price, int256 ret, int256 score, uint256 originBlock)',
  'event TripRequested(int256 score, uint256 originBlock)',
  'function scoreOf(int256 a, int256 b, int256 c) pure returns (int256)',
  'function scored() view returns (uint256)',
  'function lastScore() view returns (int256)',
  'function breakerTripped() view returns (bool)',
  'function pending() view returns (bool)',
];
const BREAKER_ABI = [
  'event Tripped(int256 score, uint256 originBlock, uint256 executedBlock, uint256 latencyBlocks)',
  'event Reset(address by)',
  'function tripped() view returns (bool)',
  'function trips() view returns (uint256)',
];

export const lasna = new ethers.JsonRpcProvider(CFG.lasnaRpc, 5318007, { staticNetwork: true });
const baseProviders = CFG.baseRpcs.map((u) => new ethers.JsonRpcProvider(u, 84532, { staticNetwork: true }));
export const sentinel = new ethers.Contract(CFG.sentinel, SENTINEL_ABI, lasna);
const breakerIface = new ethers.Interface(BREAKER_ABI);

async function withBase(fn) {
  let last;
  for (const p of baseProviders) { try { return await fn(p); } catch (e) { last = e; } }
  throw last;
}

/** eth_getLogs in chunks (public RPCs cap the block range). */
async function chunkedLogs(provider, filter, from, to, step) {
  const out = [];
  for (let a = from; a <= to; a += step + 1) {
    const b = Math.min(a + step, to);
    out.push(...(await provider.getLogs({ ...filter, fromBlock: a, toBlock: b })));
  }
  return out;
}

const pct = (x1e6) => Number(x1e6) / 1e6; // contract returns are percent * 1e6

export async function loadState() {
  const [scored, lastScore, sTripped, pending, balance] = await Promise.all([
    sentinel.scored(), sentinel.lastScore(), sentinel.breakerTripped(), sentinel.pending(), lasna.getBalance(CFG.sentinel),
  ]);
  const breaker = await withBase(async (p) => {
    const c = new ethers.Contract(CFG.breaker, BREAKER_ABI, p);
    const [tripped, trips] = await Promise.all([c.tripped(), c.trips()]);
    return { tripped, trips: Number(trips) };
  });
  return { scored: Number(scored), lastScore, sentinelSeesTripped: sTripped, pending, balance: ethers.formatEther(balance), breaker };
}

export async function loadScored() {
  const head = await lasna.getBlockNumber();
  const logs = await chunkedLogs(lasna, { address: CFG.sentinel, topics: [sentinel.interface.getEvent('Scored').topicHash] }, CFG.sentinelDeployBlock, head, 10_000);
  return logs.map((l) => {
    const e = sentinel.interface.parseLog(l);
    return {
      lasnaBlock: l.blockNumber,
      tx: l.transactionHash,
      price: Number(ethers.formatUnits(e.args.price, 18)),
      retPct: pct(e.args.ret),
      score: e.args.score,
      originBlock: Number(e.args.originBlock),
    };
  });
}

export async function loadTrips() {
  return withBase(async (p) => {
    const head = await p.getBlockNumber();
    const topics = [[breakerIface.getEvent('Tripped').topicHash, breakerIface.getEvent('Reset').topicHash]];
    const logs = await chunkedLogs(p, { address: CFG.breaker, topics }, CFG.breakerDeployBlock, head, 50_000);
    return logs.map((l) => {
      const e = breakerIface.parseLog(l);
      return e.name === 'Tripped'
        ? { kind: 'Tripped', tx: l.transactionHash, block: l.blockNumber, score: e.args.score, originBlock: Number(e.args.originBlock), latencyBlocks: Number(e.args.latencyBlocks) }
        : { kind: 'Reset', tx: l.transactionHash, block: l.blockNumber, by: e.args.by };
    });
  });
}

/** Asks the deployed contract's own neural network (a pure function, so this is a free eth_call). */
export async function scoreWindow(r0Pct, r1Pct, r2Pct) {
  const s = (x) => BigInt(Math.round(x * 1e6));
  return sentinel.scoreOf(s(r0Pct), s(r1Pct), s(r2Pct));
}
