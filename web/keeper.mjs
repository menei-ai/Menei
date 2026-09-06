// The employee's hands. Polls the chain, finds accounts off their law,
// rebalances them across every asset in the venue, earns the bounty.
// Serves every AUM0 venue listed in CONTRACTS. Runs when KEEPER_PK is set.
import { JsonRpcProvider, FetchRequest, Wallet, Contract } from 'ethers';

const RPC = process.env.RPC_URL || 'https://rpc.mainnet.chain.robinhood.com';
const CONTRACTS = [
  { addr: '0x4f08bdC9353060351f95207CD47D67D1cF6e5989', fromBlock: 55832000, wallet: true, cross: true },  // pension: the desk, plus laws that age
  { addr: '0xf7DBb9142A194F5f409c2c587cFC559D77C40358', fromBlock: 55535000, wallet: true, cross: true },  // desk: 26 assets, plus the internal cross
  { addr: '0x3484F1cC081A98103CE0E9E42AE96a2A770eCd79', fromBlock: 53775000, wallet: true },  // v4: 26 assets, stocks through treasuries
  { addr: '0xaFd484733f4B23e235bf1825c9AdA39368160B03', fromBlock: 50946000, wallet: true },  // v3: fifteen stocks
  { addr: '0xcc27Dd6FD74210303660643bcf6c9d115443bFcA', fromBlock: 50820000 },                // custody, 15 stocks
  { addr: '0xE46B6e60c7b2CbC1f9761B3f12a69813093B6dde', fromBlock: 50600000 },                // custody, NVDA only
];
const POLL_MS = 60_000;
const MIN_ACT_BPS = 300;      // don't grind dust: act only on real drift
const MIN_VALUE_USD = 0.5;    // ignore empty accounts
const MIN_LEG_USD = 0.05;     // skip legs the pool fee would eat
const MAX_TX_PER_DAY = 200;   // hard spend cap
const DRY = process.env.DRY_RUN === '1';

// Self-employment. The employee only takes jobs that pay, and when its gas
// runs low it converts its own wages into fuel. Nobody tops this wallet up.
// lowercase on purpose: ethers rejects a mixed-case address whose checksum is off
const WETH = '0x0bd7d308f8e1639fab988df18a8011f41eacad73';
const ROUTER = '0xcaf681a66d020601342297493863e78c959e5cb2';
const USDG = '0x5fc5360d0400a0fd4f2af552add042d716f1d168';
const WETH_POOL = '0x69bfaf19c9f377bb306a89aed9f6b07e2c1a8d9a'; // WETH/USDG 0.05%
const FACTORY = '0x1f7d7550b1b028f7571e69a784071f0205fd2efa';
// The exchange closes; the chain does not. An asset is worth trading at any
// hour as long as its feed still agrees with its live pool. When the two part
// company the feed can no longer price the fill, so that asset waits.
const AWAKE_GAP_PCT = 1.0;
const PROFIT_MARGIN = 1.5;    // a stranger's job must pay 1.5x its gas
const REFUEL_BELOW = 0.015;   // ETH; below this the employee buys its own gas
const REFUEL_TARGET = 0.02;   // and fills the tank back to this
const USDG_FLOAT = 2;         // it never spends the last of its cash

const ABI = [
  'function accountOf(address) view returns (uint16[] targetBps, uint16 minDriftBps, uint16 bandBps, uint128 bountyQuote)',
  'function valueOf(address) view returns (uint256)',
  'function drift(address) view returns (uint256)',
  'function balanceOf(address, uint256) view returns (uint256)',
  'function heldBy(address, uint256) view returns (uint256)',
  'function assetCount() view returns (uint256)',
  'function assetAt(uint256) view returns (address token, address feed, uint24 poolFee, uint8 decimals)',
  'function rebalance(address user, (uint256 sellAsset, uint256 buyAsset, uint256 amountIn)[] trades)',
  'function cross(address seller, address buyer, uint256 asset, uint256 amount)',
  'event TargetSet(address indexed user, uint16[] targetBps, uint16 minDriftBps, uint16 bandBps, uint128 bountyQuote)',
];
const FEED_ABI = ['function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)'];
const ERC20_ABI = [
  'function balanceOf(address) view returns (uint256)',
  'function allowance(address, address) view returns (uint256)',
  'function approve(address, uint256) returns (bool)',
];

const req = new FetchRequest(RPC);
req.setHeader('user-agent', 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36');
const provider = new JsonRpcProvider(req, 4663, { staticNetwork: true });
let wallet;

let sentToday = 0, dayStamp = '';
const backoff = new Map(); // `${venue}:${user}` -> fail count

function log(...a) { console.log(new Date().toISOString(), '[keeper]', ...a); }

async function loadVenue(v) {
  v.c = new Contract(v.addr, ABI, wallet);
  const n = Number(await v.c.assetCount());
  v.assets = [];
  const quote = (await v.c.assetAt(0)).token;
  for (let i = 0; i < n; i++) {
    const a = await v.c.assetAt(i);
    const asset = { token: a.token, feed: a.feed, poolFee: Number(a.poolFee), decimals: Number(a.decimals), feedC: i === 0 ? null : new Contract(a.feed, FEED_ABI, provider) };
    if (i > 0) asset.pool = await poolFor(a.token, quote, Number(a.poolFee));
    v.assets.push(asset);
  }
  v.quote = quote;
  log(`venue ${v.addr.slice(0, 8)}… loaded, ${n} assets`);
}

// -- self-employment ---------------------------------------------------------

let ethCache = { at: 0, px: 0 };
async function ethUsd() {
  if (ethCache.px && Date.now() - ethCache.at < 300_000) return ethCache.px;
  const slot0 = await provider.call({ to: WETH_POOL, data: '0x3850c7bd' });
  const s = Number(BigInt('0x' + slot0.slice(2, 66))) / 2 ** 96;
  ethCache = { at: Date.now(), px: s * s * 1e12 };
  return ethCache.px;
}

let thinLoggedAt = 0;
async function refuel() {
  const bal = Number(await provider.getBalance(wallet.address)) / 1e18;
  if (bal >= REFUEL_BELOW) return;
  const px = await ethUsd();
  const usdg = new Contract(USDG, ERC20_ABI, wallet);
  const cash = Number(await usdg.balanceOf(wallet.address)) / 1e6;
  const spend = Math.min(cash - USDG_FLOAT, (REFUEL_TARGET - bal) * px);
  if (spend < 1) {
    if (Date.now() - thinLoggedAt > 3600_000) {
      thinLoggedAt = Date.now();
      log(`gas low (${bal.toFixed(5)} ETH), wages too thin to refuel (${cash.toFixed(2)} USDG on hand)`);
    }
    return;
  }
  if ((await usdg.allowance(wallet.address, ROUTER)) < BigInt(Math.floor(spend * 1e6))) {
    await (await usdg.approve(ROUTER, 2n ** 255n)).wait();
  }
  const router = new Contract(ROUTER,
    ['function exactInputSingle((address,address,uint24,address,uint256,uint256,uint160)) payable returns (uint256)'], wallet);
  const amountIn = BigInt(Math.floor(spend * 1e6));
  const minOut = BigInt(Math.floor(spend / px * 0.97 * 1e18));
  await (await router.exactInputSingle([USDG, WETH, 500, wallet.address, amountIn, minOut, 0n])).wait();
  const weth = new Contract(WETH, ['function withdraw(uint256)', ...ERC20_ABI], wallet);
  const got = await weth.balanceOf(wallet.address);
  if (got > 0n) await (await weth.withdraw(got)).wait();
  sentToday += 2;
  log(`bought its own gas: ${spend.toFixed(2)} USDG -> ${(Number(got) / 1e18).toFixed(5)} ETH. nobody tops this wallet up.`);
}

async function prices(v) {
  const out = [1];
  for (let i = 1; i < v.assets.length; i++) {
    const [, p] = await v.assets[i].feedC.latestRoundData();
    out.push(Number(p) / 1e8);
  }
  return out;
}

// -- the demonstration -------------------------------------------------------

// Anyone can watch a fund drift and be walked home, but reading about it is
// not the same as doing it. The site lets a visitor knock the employee's own
// demo wallet off its law with a real swap on the real pool. After that the
// employee waits: for a full minute the job sits open on the board and any
// wallet on earth may take it and keep the bounty. If nobody does, it tidies
// its own desk, as always.
const SHAKE_VENUE = '0xaFd484733f4B23e235bf1825c9AdA39368160B03';
const SHAKE_USD = 0.35;           // enough to move the needle, small enough to be nothing
const SHAKE_COOLDOWN_MS = 300_000;
const HANDS_OFF_MS = 60_000;      // the window in which a stranger can beat the robot to it
const SHAKE_MAX_PER_DAY = 30;     // the demo is cheap, but not free
let lastShakeAt = 0, handsOffUntil = 0, shakesToday = 0, shakeDay = '';

export function shakeState() {
  const now = Date.now();
  const day = new Date().toISOString().slice(0, 10);
  if (day !== shakeDay) { shakeDay = day; shakesToday = 0; }
  return {
    ready: !!wallet && now - lastShakeAt >= SHAKE_COOLDOWN_MS && shakesToday < SHAKE_MAX_PER_DAY,
    spentToday: shakesToday, maxPerDay: SHAKE_MAX_PER_DAY,
    cooldownLeft: Math.max(0, SHAKE_COOLDOWN_MS - (now - lastShakeAt)),
    handsOffLeft: Math.max(0, handsOffUntil - now),
    venue: SHAKE_VENUE,
    wallet: wallet ? wallet.address : null,
  };
}

// Sell a slice of whichever holding is furthest above its target. That is the
// one honest way to push a wallet off course: it is exactly what the market
// does to it every day, only faster.
export async function shake() {
  if (!wallet) throw new Error('the employee is not on shift');
  const now = Date.now();
  if (now - lastShakeAt < SHAKE_COOLDOWN_MS) throw new Error('too soon; the last one is still settling');
  const day = new Date().toISOString().slice(0, 10);
  if (day !== shakeDay) { shakeDay = day; shakesToday = 0; }
  if (shakesToday >= SHAKE_MAX_PER_DAY) throw new Error('the desk has been knocked about enough for one day');
  shakesToday++;
  const v = CONTRACTS.find(c => c.addr === SHAKE_VENUE);
  if (!v) throw new Error('venue not loaded');

  const px = await prices(v);
  const acct = await v.c.accountOf(wallet.address);
  const bal = [];
  for (let i = 0; i < v.assets.length; i++) {
    bal.push(Number(await v.c.heldBy(wallet.address, i)) / 10 ** (i === 0 ? 6 : 18));
  }
  const value = bal.reduce((s, b, i) => s + b * px[i], 0);
  let pick = 0, worst = 0;
  for (let i = 1; i < bal.length; i++) {
    const usd = bal[i] * px[i];
    if (usd < SHAKE_USD * 1.2) continue;                       // must have enough to sell
    const over = usd - value * Number(acct.targetBps[i]) / 10000;
    if (over > worst) { worst = over; pick = i; }
  }
  if (!pick) {                                                  // nothing above target: buy instead
    for (let i = 1; i < bal.length; i++) if (Number(acct.targetBps[i]) > 0) { pick = i; break; }
    if (!pick || bal[0] < SHAKE_USD) throw new Error('the wallet is too small to disturb');
  }

  const sell = worst > 0;
  const asset = v.assets[pick];
  const token = sell ? asset.token : v.quote;
  const other = sell ? v.quote : asset.token;
  const amountIn = sell
    ? BigInt(Math.floor((SHAKE_USD / px[pick]) * 1e18))
    : BigInt(Math.floor(SHAKE_USD * 1e6));

  const erc = new Contract(token, ERC20_ABI, wallet);
  if ((await erc.allowance(wallet.address, ROUTER)) < amountIn) {
    await (await erc.approve(ROUTER, 2n ** 255n)).wait();
  }
  const router = new Contract(ROUTER,
    ['function exactInputSingle((address,address,uint24,address,uint256,uint256,uint160)) payable returns (uint256)'], wallet);
  const driftBefore = Number(await v.c.drift(wallet.address));

  // Stand back before the swap, not after it. The moment the swap lands the
  // wallet is off its law, and a poll already in flight would otherwise tidy
  // it up before the window even opens.
  lastShakeAt = Date.now();
  handsOffUntil = lastShakeAt + HANDS_OFF_MS;

  const tx = await router.exactInputSingle([token, other, asset.poolFee ?? 3000, wallet.address, amountIn, 0n, 0n]);
  await tx.wait();
  const driftAfter = Number(await v.c.drift(wallet.address));

  handsOffUntil = Date.now() + HANDS_OFF_MS;   // the full minute starts once it is really off course
  lastShakeAt = Date.now();
  sentToday++;
  log(`a visitor knocked the desk: drift ${driftBefore} -> ${driftAfter} bps. hands off for ${HANDS_OFF_MS / 1000}s, the job is anyone's.`);
  return { tx: tx.hash, driftBefore, driftAfter, handsOffMs: HANDS_OFF_MS };
}

// -- the night shift ---------------------------------------------------------

async function poolFor(token, quote, fee) {
  const pad = a => a.replace('0x', '').toLowerCase().padStart(64, '0');
  const data = '0x1698ee82' + pad(token) + pad(quote) + fee.toString(16).padStart(64, '0');
  const res = await provider.call({ to: FACTORY, data });
  const addr = '0x' + res.slice(-40);
  return BigInt(addr) === 0n ? null : addr;
}

// What the pool says a share costs right now, read from its own price slot.
async function poolPrice(asset, quote) {
  if (!asset.pool) return null;
  const slot0 = await provider.call({ to: asset.pool, data: '0x3850c7bd' });
  const sqrtP = Number(BigInt('0x' + slot0.slice(2, 66))) / 2 ** 96;
  const p = sqrtP * sqrtP;
  if (!p) return null;
  const scale = 10 ** (asset.decimals - 6);
  return asset.token.toLowerCase() < quote.toLowerCase() ? p * scale : scale / p;
}

// An asset is awake when its feed and its pool still tell the same story.
// Feeds go quiet outside market hours; that is fine. What is not fine is a
// feed that has drifted away from where the asset actually trades, because
// the contract prices every fill against that feed.
async function awakeMask(v, px) {
  const mask = [true];
  for (let i = 1; i < v.assets.length; i++) {
    try {
      const pp = await poolPrice(v.assets[i], v.quote);
      mask.push(pp !== null && px[i] > 0 && Math.abs(pp / px[i] - 1) * 100 < AWAKE_GAP_PCT);
    } catch { mask.push(false); }
  }
  return mask;
}

// Sells first (they raise cash), then buys, each leg 3% inside the line.
function planTrades(weights, balances, px, cash, awake) {
  const value = balances.reduce((s, b, i) => s + b * px[i], 0);
  if (value < MIN_VALUE_USD) return null;
  const sells = [], buys = [];
  let cashFreed = 0, cashNeeded = 0;
  for (let i = 1; i < balances.length; i++) {
    if (awake && !awake[i]) continue;   // sleeping asset: leave it where it is
    const delta = (value * Number(weights[i]) / 10000 - balances[i] * px[i]) * 0.97;
    if (delta < -MIN_LEG_USD) {
      sells.push({ sellAsset: BigInt(i), buyAsset: 0n, amountIn: BigInt(Math.floor(-delta / px[i] * 1e18)) });
      cashFreed += -delta;
    } else if (delta > MIN_LEG_USD) {
      buys.push({ sellAsset: 0n, buyAsset: BigInt(i), amountIn: BigInt(Math.floor(delta * 1e6)), usd: delta });
    }
  }
  // buys spend cash on hand plus what the sells free up (less pool fees)
  const budget = cash + cashFreed * 0.99;
  cashNeeded = buys.reduce((s, b) => s + b.usd, 0);
  if (cashNeeded > budget) {
    const k = budget / cashNeeded;
    for (const b of buys) b.amountIn = BigInt(Math.floor(Number(b.amountIn) * k));
  }
  const trades = [...sells, ...buys.map(({ usd, ...t }) => t)].filter(t => t.amountIn > 0n);
  return trades.length ? { trades, cashAfter: budget - Math.min(cashNeeded, budget) } : null;
}

// -- the desk ---------------------------------------------------------------
// The employee sits at the desk too. When two of the wallets it serves want
// opposite sides of the same stock, routing both through a pool would cost
// each of them the spread for nothing, so before any pool work it looks for
// pairs and crosses them at the feed. A cross never touches a pool: it clears
// at any hour, weekends included, and nothing is deducted from the pay.
async function crossPass(v, px) {
  const self = wallet.address.toLowerCase();
  const infos = [];
  for (const u of await users(v)) {
    try {
      const [acct, driftRaw] = await Promise.all([v.c.accountOf(u), v.c.drift(u).catch(() => null)]);
      if (driftRaw === null || !acct.targetBps.length) continue;
      const drift = Number(driftRaw);
      if (drift < Math.max(Number(acct.minDriftBps), MIN_ACT_BPS)) continue;
      const balances = [];
      for (let i = 0; i < v.assets.length; i++) balances.push(Number(await v.c.heldBy(u, i)) / 10 ** (i === 0 ? 6 : 18));
      const value = balances.reduce((s2, b, i) => s2 + b * px[i], 0);
      if (value < MIN_VALUE_USD) continue;
      const deltas = [];
      for (let i = 1; i < v.assets.length; i++) deltas[i] = value * Number(acct.targetBps[i]) / 10000 - balances[i] * px[i];
      infos.push({ u, drift, value, deltas, bounty: Number(acct.bountyQuote) / 1e6 });
    } catch {}
  }
  for (const sInfo of infos) for (const bInfo of infos) {
    if (sInfo.u === bInfo.u) continue;
    const ownSide = sInfo.u.toLowerCase() === self || bInfo.u.toLowerCase() === self;
    if (ownSide && Date.now() < handsOffUntil) continue;   // a shaken desk stays available to strangers
    for (let i = 1; i < v.assets.length; i++) {
      const sell = -(sInfo.deltas[i] || 0), buy = bInfo.deltas[i] || 0;
      if (sell < 0.5 || buy < 0.5) continue;
      const size = Math.min(sell, buy) * 0.95;
      const amount = BigInt(Math.floor(size / px[i] * 1e6)) * 10n ** 12n;
      // tried as a read first, always: a cross that would revert costs nothing
      const est = await v.c.cross.estimateGas(sInfo.u, bInfo.u, i, amount).catch(() => null);
      if (est === null) continue;
      // a fee paid to the employee's own wallet is a wash, not income
      const fee = x => x.bounty * Math.min(2 * size / x.value * 10000, x.drift) / 10000;
      const pay = (sInfo.u.toLowerCase() === self ? 0 : fee(sInfo)) + (bInfo.u.toLowerCase() === self ? 0 : fee(bInfo));
      if (!ownSide) {
        const [feeData, eth] = await Promise.all([provider.getFeeData(), ethUsd()]);
        const costUsd = Number(est) * Number(feeData.gasPrice) / 1e18 * eth;
        if (pay < costUsd * PROFIT_MARGIN) {
          v.deskLogged ??= new Set();
          const key = sInfo.u + bInfo.u + i;
          if (!v.deskLogged.has(key)) { v.deskLogged.add(key); log(`desk: ${sInfo.u.slice(0, 8)}x${bInfo.u.slice(0, 8)} matched, pays $${pay.toFixed(3)} vs gas $${costUsd.toFixed(3)}, left on the board for a human`); }
          continue;
        }
      }
      if (DRY) { log(`desk DRY: would cross $${size.toFixed(2)} of asset ${i}, ${sInfo.u.slice(0, 8)} to ${bInfo.u.slice(0, 8)}`); return; }
      const tx = await v.c.cross(sInfo.u, bInfo.u, i, amount, { gasLimit: est * 13n / 10n });
      const rc = await tx.wait();
      sentToday++;
      log(`crossed at the desk: $${size.toFixed(2)} of asset ${i}, ${sInfo.u.slice(0, 8)} sold to ${bInfo.u.slice(0, 8)}, pay ~$${pay.toFixed(3)}, gas ${rc.gasUsed}, tx ${tx.hash}`);
      return;   // one cross a tick; the next tick reads the new world
    }
  }
}

async function serveOne(v, user, px, awake) {
  // a freshly disturbed desk is left alone, so a stranger has a fair shot at the bounty
  if (user.toLowerCase() === wallet.address.toLowerCase() && Date.now() < handsOffUntil) return;
  const [acct, driftRaw] = await Promise.all([v.c.accountOf(user), v.c.drift(user).catch(() => null)]);
  if (driftRaw === null) return;
  const drift = Number(driftRaw);
  if (drift < Math.max(Number(acct.minDriftBps), MIN_ACT_BPS)) return;

  const balances = [];
  for (let i = 0; i < v.assets.length; i++) {
    const raw = v.wallet ? await v.c.heldBy(user, i) : await v.c.balanceOf(user, i);
    balances.push(Number(raw) / 10 ** (i === 0 ? 6 : 18));
  }
  const plan = planTrades(acct.targetBps, balances, px, balances[0], awake);
  if (!plan) return;

  const expectedPay = Number(acct.bountyQuote) / 1e6 * drift / 10000;
  if (expectedPay > plan.cashAfter) { log(user, 'skipped: bounty exceeds cash (broken policy)'); return; }

  // Every plan is tried as a read first, its own desk included: a plan that
  // would revert is a plan that only burns gas, and blind sends were how the
  // wallet bled on 2026-09-06. Tidying its own desk stays free of the profit
  // test; a stranger's job still has to pay for itself at 1.5x the gas.
  const est = await v.c.rebalance.estimateGas(user, plan.trades).catch(() => null);
  if (est === null) { log(user, 'skipped: the trade would revert as planned'); return; }
  if (user.toLowerCase() !== wallet.address.toLowerCase()) {
    const [fee, px] = await Promise.all([provider.getFeeData(), ethUsd()]);
    const costUsd = Number(est) * Number(fee.gasPrice) / 1e18 * px;
    if (expectedPay < costUsd * PROFIT_MARGIN) {
      log(user, `skipped: pays $${expectedPay.toFixed(3)}, gas $${costUsd.toFixed(3)}. charity is not in the contract`);
      return;
    }
  }

  if (DRY) { log(user, `DRY: drift ${drift}, ${plan.trades.length} legs, pay ~$${expectedPay.toFixed(2)}`); return; }

  const tx = await v.c.rebalance(user, plan.trades, { gasLimit: 600_000 + 400_000 * plan.trades.length });
  const rc = await tx.wait();
  sentToday++;
  log(user, `rebalanced on ${v.addr.slice(0, 8)}…. drift was ${drift}, ${plan.trades.length} legs, pay ~$${expectedPay.toFixed(2)}, gas ${rc.gasUsed}, tx ${tx.hash}`);
  backoff.delete(v.addr + ':' + user);
}

// Who has a law. The first pass scans from the venue's birth; every pass after
// reads only the blocks since, so the public node sees a sliver, not history.
async function users(v) {
  const head = await provider.getBlockNumber();
  const from = v.scannedTo === undefined ? v.fromBlock : v.scannedTo + 1;
  v.users ??= new Set();
  if (from <= head) {
    const logs = await provider.getLogs({ address: v.addr, topics: [v.c.interface.getEvent('TargetSet').topicHash], fromBlock: from, toBlock: head });
    for (const l of logs) v.users.add('0x' + l.topics[1].slice(26));
    v.scannedTo = head;
  }
  return [...v.users];
}

async function tick() {
  const day = new Date().toISOString().slice(0, 10);
  if (day !== dayStamp) { dayStamp = day; sentToday = 0; }
  if (sentToday >= MAX_TX_PER_DAY) return log('daily tx cap reached, resting');
  if (!DRY) await refuel().catch(e => log('refuel failed:', String(e.shortMessage || e.message).slice(0, 100)));
  for (const v of CONTRACTS) {
    const px = await prices(v);
    const awake = await awakeMask(v, px);
    const asleep = awake.map((ok, i) => ok ? null : i).filter(i => i);
    if (asleep.length !== (v.lastAsleep ?? -1)) {
      v.lastAsleep = asleep.length;
      log(`${v.addr.slice(0, 8)}… ${awake.length - 1 - asleep.length}/${awake.length - 1} assets awake` +
          (asleep.length ? `, sleeping: ${asleep.join(',')}` : ', trading around the clock'));
    }
    if (v.cross && sentToday < MAX_TX_PER_DAY) {
      try { await crossPass(v, px); }
      catch (e) { log('desk pass failed:', String(e.shortMessage || e.message).slice(0, 100)); }
    }
    for (const u of await users(v)) {
      const key = v.addr + ':' + u;
      if ((backoff.get(key) || 0) >= 3) continue;
      try { await serveOne(v, u, px, awake); }
      catch (e) {
        backoff.set(key, (backoff.get(key) || 0) + 1);
        log(u, 'failed:', String(e.shortMessage || e.message).slice(0, 120));
      }
    }
  }
}

export async function startKeeper() {
  if (!process.env.KEEPER_PK) { log('no KEEPER_PK, hands stay in pockets'); return; }
  wallet = new Wallet(process.env.KEEPER_PK, provider);
  for (const v of CONTRACTS) await loadVenue(v);
  log(`up. wallet ${wallet.address}, poll ${POLL_MS / 1000}s, act >= ${MIN_ACT_BPS} bps${DRY ? ', DRY RUN' : ''}`);
  const loop = () => tick().catch(e => log('tick failed:', String(e.message).slice(0, 120))).finally(() => setTimeout(loop, POLL_MS));
  loop();
}
