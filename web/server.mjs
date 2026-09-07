// aumzero.com: static site + Hood RPC proxy in one process.
// The public Hood RPC sits behind a bot filter that dislikes bare fetches,
// so the page talks through here with a plain browser identity.
import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { gzipSync } from 'node:zlib';

const PORT = process.env.PORT || 3000;
const ROOT = new URL('.', import.meta.url).pathname;
// Two upstreams. The public node allows wide eth_getLogs ranges but rate
// limits hard; a dedicated provider (FAST_RPC_URL, e.g. Alchemy) answers
// calls and balances instantly but caps eth_getLogs at a few blocks. So
// logs go to the public node, behind a short shared cache, and everything
// else goes to the fast one.
const UPSTREAM = process.env.RPC_URL || 'https://rpc.mainnet.chain.robinhood.com';
const FAST = process.env.FAST_RPC_URL || UPSTREAM;
const LOG_CACHE_MS = 15_000;
const logCache = new Map();   // request body -> { at, status, text } or an in-flight promise
async function proxyRpc(body, method) {
  const headers = { 'content-type': 'application/json', 'user-agent': UA };
  if (method !== 'eth_getLogs') {
    const r = await fetch(FAST, { method: 'POST', headers, body });
    const text = await r.text();
    // a dedicated provider out of quota must not take the site down with it:
    // anything that smells like refusal is retried once on the public node
    if (r.status !== 200 || text.includes('capacity') || text.includes('exceeded') || text.includes('"error"')) {
      try { const r2 = await fetch(UPSTREAM, { method: 'POST', headers, body });
        return { status: r2.status, text: await r2.text() }; } catch {}
    }
    return { status: r.status, text };
  }
  const hit = logCache.get(body);
  if (hit && hit.then) return hit;                                   // same scan already in flight
  if (hit && Date.now() - hit.at < LOG_CACHE_MS) return hit;         // fresh enough for everyone
  const p = (async () => {
    // the public node says 429 easily; try twice, and if it still refuses,
    // hand out the last good answer rather than an error the page must hide
    for (let attempt = 0; attempt < 2; attempt++) {
      const r = await fetch(UPSTREAM, { method: 'POST', headers, body });
      const out = { at: Date.now(), status: r.status, text: await r.text() };
      if (r.status === 200 && !out.text.includes('"error"')) { logCache.set(body, out); return out; }
      if (attempt === 0) await new Promise(res => setTimeout(res, 1500));
      else { if (hit && !hit.then) { logCache.set(body, hit); return hit; } logCache.delete(body); return out; }
    }
  })();
  logCache.set(body, p);
  return p;
}
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';
// Only what the page needs; anything else is refused.
const ALLOW = new Set(['eth_call', 'eth_blockNumber', 'eth_getBalance', 'eth_chainId', 'eth_getLogs']);
const AUM0S = new Set(['0xe46b6e60c7b2cbc1f9761b3f12a69813093b6dde', '0xcc27dd6fd74210303660643bcf6c9d115443bfca', '0xafd484733f4b23e235bf1825c9ada39368160b03', '0x3484f1cc081a98103ce0e9e42ae96a2a770ecd79', '0xf7dbb9142a194f5f409c2c587cfc559d77c40358', '0x4f08bdc9353060351f95207cd47d67d1cf6e5989']);
// The proxy serves this site only. No CORS headers are ever emitted, so
// other origins cannot borrow it from a browser; same-origin needs none.
const SITE_ORIGINS = new Set(['https://aumzero.com', 'https://www.aumzero.com', 'https://aum0-web-production.up.railway.app']);
// a page served from this machine is this site too, whatever port it landed on
const isLocal = o => /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(o);

// Feed prices are the same for every visitor, so the server reads them once
// and hands out the cached copy. Fifteen calls per refresh instead of fifteen
// per person.
const FEEDS = [
  '0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15','0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb',
  '0x4A1166a659A55625345e9515b32adECea5547C38','0x6B22A786bAa607d76728168703a39Ea9C99f2cD0',
  '0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E','0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C',
  '0x425EEFdCf05ed6526C3cE61Af99429A228a6d596','0x319724394D3A0e3669269846abE664Cd621f9f6A',
  '0x820ABedFF239034956B7A9d2F0a331f9F075eB4c','0xfb133Fa4B7b385802B693a293606682Df47109A3',
  '0x3f390C5C24628Ac7C489515402235FeAD71D1913','0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72',
  '0xF6f373a037c30F0e5010d854385cA89185AE638b','0x7C38C00C30BEe9378381E7B6135d7283356D71b1',
  '0x451B1295aA84FD6d6b58af1a5002eA1b1A1913A0',
  // the widened venue: an index, a treasury bill, silver, oil, and seven more
  '0x80901d846d5D7B030F26B480776EE3b29374C2ae','0xa0DF4ee0fFf975306345875E3548Fcc519577A11',
  '0x209b73908e92Ae021826eD79609845451Ecba2ce','0x75a9c76Ef439e2C7c2E5a34Ab105EcFe3766431c',
  '0x27C71df6A64fB476468EdF256CF72c038baB5B67','0x6652eDf64bA3731C4F2D3ce821A0Fb1f1f6b482a',
  '0x1C6c8cADBe02E19129c39dDB92281cE4c0bf206b','0x396118bdFB181e6240E74D243F266B061c0edc3D',
  '0x874cF94aa8eC88Fd9560094dD065f2fB3E41Fc2F','0x62Cc8F9b5f56a33c9C8A60c8B92779f523c4E984',
  '0xB4106147E8cce40b7d46124090d373A71b70f87D',
];
let priceCache = { at: 0, px: null };
let keeper = null, shaking = false;
// One slow feed, or one rate-limited minute, should not empty the shelf: a
// stale price is better than none, and a missing one keeps its last value.
async function readFeed(addr) {
  // first the fast lane, then the public node: a provider out of quota must
  // not blind the whole venue
  for (const host of [FAST, UPSTREAM]) {
    try {
      const r = await fetch(host, { method: 'POST', headers: { 'content-type': 'application/json', 'user-agent': UA },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_call', params: [{ to: addr, data: '0xfeaf968c' }, 'latest'] }) });
      const j = await r.json();
      if (j.result) return Number(BigInt('0x' + j.result.slice(2 + 64, 2 + 128))) / 1e8;
    } catch {}
    await new Promise(r => setTimeout(r, 250));
  }
  return null;
}

let refreshing = null;
async function prices() {
  if (priceCache.px && Date.now() - priceCache.at < 30_000) return priceCache.px;
  if (refreshing) return refreshing;
  refreshing = (async () => {
    const out = [1];
    let got = 0;
    for (let i = 0; i < FEEDS.length; i++) {
      const p = await readFeed(FEEDS[i]);
      if (p !== null) { out.push(p); got++; }
      else out.push(priceCache.px ? priceCache.px[i + 1] : null);
    }
    if (got > 0) priceCache = { at: Date.now(), px: out };
    return priceCache.px || out;
  })().finally(() => { refreshing = null; });
  return refreshing;
}

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.webp': 'image/webp', '.png': 'image/png', '.ico': 'image/x-icon', '.css': 'text/css' };
const SECURITY = {
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'no-referrer',
  'x-frame-options': 'DENY',
  'strict-transport-security': 'max-age=31536000',
};

function sendText(req, res, status, headers, body) {
  const buf = Buffer.isBuffer(body) ? body : Buffer.from(body);
  const wantsGzip = /\bgzip\b/.test(req.headers['accept-encoding'] || '') && buf.length > 512;
  const h = { ...SECURITY, ...headers };
  if (wantsGzip && /^(text\/|application\/json)/.test(h['content-type'] || '')) {
    h['content-encoding'] = 'gzip';
    res.writeHead(status, h).end(gzipSync(buf));
  } else {
    res.writeHead(status, h).end(buf);
  }
}

// -- the firm's numbers, read once and handed to everyone --------------------
// Every visitor used to scan six venues' full history for the same answer,
// which is how a month of provider quota died in a day. The server scans once
// every ten minutes and every page shares the copy.
const REB_TOPIC = '0xbecdda7c726841dea88e1495b6f401a1d64029ba261415622f400509cf097b35';
const TS_TOPIC = '0xb8766537c154c2943c70a08668e5bbee5aa95bb3a80803f9c11d0b49b846fb87';
const STAT_VENUES = [
  ['0x4f08bdC9353060351f95207CD47D67D1cF6e5989', '0x353ef82', true],
  ['0xf7DBb9142A194F5f409c2c587cFC559D77C40358', '0x34f66fd', true],
  ['0x3484F1cC081A98103CE0E9E42AE96a2A770eCd79', '0x334a3f8', true],
  ['0xaFd484733f4B23e235bf1825c9AdA39368160B03', '0x3096d00', true],
  ['0xcc27Dd6FD74210303660643bcf6c9d115443bFcA', '0x3077e40', false],
  ['0xE46B6e60c7b2CbC1f9761B3f12a69813093B6dde', '0x3042380', false],
];
const KEEPER_ADDR = '0x3c71044dca7aa1eb401913a2f96277abe8c019a4';
let statCache = { at: 0, body: null };
let statBusy = null;
let statFailAt = 0;
async function upRpc(method, params) {
  const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method, params });
  const out = await proxyRpc(body, method);
  const j = JSON.parse(out.text);
  if (j.error) throw new Error(j.error.message || 'rpc');
  return j.result;
}
async function buildStats() {
  const head = parseInt(await upRpc('eth_blockNumber', []), 16);
  let jobs = 0, fees = 0, keeperPaid = 0, keeperJobs = 0;
  const recent = [], users = [];
  for (const [addr, from, wallet] of STAT_VENUES) {
    await new Promise(r => setTimeout(r, 400));   // the public node dislikes bursts
    const logs = await upRpc('eth_getLogs', [{ address: addr, topics: [REB_TOPIC], fromBlock: from, toBlock: '0x' + head.toString(16) }]);
    jobs += logs.length;
    for (const l of logs) {
      const paid = parseInt(l.data.slice(2 + 128, 2 + 192), 16) / 1e6;
      fees += paid;
      const worker = ('0x' + l.topics[2].slice(26)).toLowerCase();
      if (worker === KEEPER_ADDR) { keeperPaid += paid; keeperJobs++; }
      recent.push({ b: parseInt(l.blockNumber, 16), acct: '0x' + l.topics[1].slice(26), worker,
        d0: parseInt(l.data.slice(2, 66), 16), d1: parseInt(l.data.slice(66, 130), 16), paid });
    }
    if (wallet) {
      const ts = await upRpc('eth_getLogs', [{ address: addr, topics: [TS_TOPIC], fromBlock: from, toBlock: '0x' + head.toString(16) }]);
      for (const u of new Set(ts.map(l => '0x' + l.topics[1].slice(26)))) users.push([addr, u]);
    }
  }
  recent.sort((a, b) => b.b - a.b);
  return JSON.stringify({ block: head, jobs, fees, keeperPaid, keeperJobs, recent: recent.slice(0, 8), users });
}
async function statsBody() {
  if (statCache.body && Date.now() - statCache.at < 600_000) return statCache.body;
  if (statBusy) return statCache.body || statBusy;
  // a failed build rests a minute instead of hammering a throttled node
  if (!statCache.body && Date.now() - statFailAt < 60_000) return JSON.stringify({ error: 'the chain is busy, numbers follow' });
  statBusy = buildStats()
    .then(b => { statCache = { at: Date.now(), body: b }; return b; })
    .catch(e => { statFailAt = Date.now(); console.log('[stats] build failed:', String(e.message).slice(0,60)); return statCache.body || JSON.stringify({ error: String(e.message).slice(0, 80) }); })
    .finally(() => { statBusy = null; });
  return statCache.body || statBusy;
}

http.createServer(async (req, res) => {
  // -- RPC proxy ----------------------------------------------------------
  if (req.url === '/api/rpc') {
    const origin = req.headers.origin;
    if (origin && !SITE_ORIGINS.has(origin) && !isLocal(origin)) {
      return sendText(req, res, 403, { 'content-type': 'application/json', 'cache-control': 'no-store' }, '{"error":"this proxy serves aumzero.com only"}');
    }
    if (req.method !== 'POST') return sendText(req, res, 405, { 'content-type': 'application/json' }, '{"error":"POST only"}');
    let body = '';
    req.on('data', c => { body += c; if (body.length > 10000) req.destroy(); });
    req.on('end', async () => {
      try {
        const parsed = JSON.parse(body);
        if (!ALLOW.has(parsed.method)) return sendText(req, res, 400, { 'content-type': 'application/json', 'cache-control': 'no-store' }, '{"error":"method not allowed"}');
        if (parsed.method === 'eth_getLogs' && !AUM0S.has(String(parsed.params?.[0]?.address).toLowerCase())) {
          return sendText(req, res, 400, { 'content-type': 'application/json', 'cache-control': 'no-store' }, '{"error":"logs served for the AUM0 contract only"}');
        }
        const out = await proxyRpc(body, parsed.method);
        sendText(req, res, out.status, { 'content-type': 'application/json', 'cache-control': 'no-store' }, out.text);
      } catch (e) { sendText(req, res, 502, { 'content-type': 'application/json', 'cache-control': 'no-store' }, JSON.stringify({ error: String(e.message) })); }
    });
    return;
  }



// -- cached feed prices -------------------------------------------------
  // -- the demonstration --------------------------------------------------
  // A visitor may knock the employee's own demo wallet off its law. One real
  // swap on a real pool, then the employee stands back for a minute so that
  // anyone who wants the bounty can take the job first.
  if (req.url === '/api/stats') {
    const body = await statsBody();
    return sendText(req, res, 200, { 'content-type': 'application/json', 'cache-control': 'public, max-age=60' }, body);
  }

  if (req.url === '/api/shake') {
    const origin = req.headers.origin;
    if (origin && !SITE_ORIGINS.has(origin) && !isLocal(origin)) {
      return sendText(req, res, 403, { 'content-type': 'application/json' }, '{"error":"this endpoint serves aumzero.com only"}');
    }
    const state = keeper?.shakeState?.();
    if (!state) return sendText(req, res, 503, { 'content-type': 'application/json', 'cache-control': 'no-store' }, '{"error":"the employee is not on shift"}');
    if (req.method === 'GET') {
      return sendText(req, res, 200, { 'content-type': 'application/json', 'cache-control': 'no-store' }, JSON.stringify(state));
    }
    if (req.method !== 'POST') return sendText(req, res, 405, { 'content-type': 'application/json' }, '{"error":"POST only"}');
    if (!state.ready) {
      return sendText(req, res, 429, { 'content-type': 'application/json', 'cache-control': 'no-store' },
        JSON.stringify({ error: 'too soon', ...state }));
    }
    if (shaking) return sendText(req, res, 429, { 'content-type': 'application/json' }, '{"error":"already under way"}');
    shaking = true;
    keeper.shake()
      .then(r => sendText(req, res, 200, { 'content-type': 'application/json', 'cache-control': 'no-store' }, JSON.stringify(r)))
      .catch(e => sendText(req, res, 500, { 'content-type': 'application/json', 'cache-control': 'no-store' }, JSON.stringify({ error: String(e.shortMessage || e.message).slice(0, 140) })))
      .finally(() => { shaking = false; });
    return;
  }

  if (req.url === '/api/prices') {
    try {
      const px = await prices();
      if (!px || px.some(v => v === null)) throw new Error('feeds warming up');
      return sendText(req, res, 200, { 'content-type': 'application/json', 'cache-control': 'public, max-age=20' }, JSON.stringify(px));
    } catch (e) {
      return sendText(req, res, 503, { 'content-type': 'application/json', 'cache-control': 'no-store' }, JSON.stringify({ error: String(e.message) }));
    }
  }

  // -- static files -------------------------------------------------------
  const path = normalize(req.url.split('?')[0]).replace(/^\/+/, '') || 'index.html';
  try {
    const data = await readFile(join(ROOT, path === '' ? 'index.html' : path));
    const ct = MIME[extname(path)] || 'application/octet-stream';
    // The page itself is always fresh; assets are content-stable and cache long.
    const cache = ct.startsWith('text/html') ? 'no-store' : 'public, max-age=86400';
    sendText(req, res, 200, { 'content-type': ct, 'cache-control': cache }, data);
  } catch {
    try {
      sendText(req, res, 200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' }, await readFile(join(ROOT, 'index.html')));
    } catch { sendText(req, res, 404, { 'content-type': 'text/html' }, 'not found'); }
  }
}).listen(PORT, () => {
  console.log('aumzero.com serving on', PORT);
  prices().then(p => console.log('[prices] warm,', p.filter(Boolean).length, 'feeds')).catch(() => {});
});

import('./keeper.mjs').then(m => { keeper = m; return m.startKeeper(); })
  .catch(e => console.log('[keeper] not started:', e.message));
