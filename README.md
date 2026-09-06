<p align="center">
  <img src="assets/banner.webp" alt="AUM0" width="100%">
</p>

# AUM0

AUM Zero. An asset manager with no employees, no fees, no custody, and no
ability to steal.

CA: 0xe7cfbf084589b73a3ff74e9819dd3d28ee1e05a9

[aumzero.com](https://aumzero.com) · [x.com/aum0com](https://x.com/aum0com)

You carve a target allocation into your own wallet: so much stock, so much
cash. From then on, strangers manage your portfolio. When prices drift your
holdings away from the target, anyone may call rebalance() on your wallet,
push it back toward the target, and take a small bounty for the work. That is
the entire company.

BlackRock runs $10 trillion of AUM and charges for it. This is AUM, zero.

## Your stocks never leave your wallet

There is no deposit. Your stocks and your cash sit in your own wallet, where
your wallet app can see them, and they stay there. You grant an allowance and
set a target; each rebalance pulls from your wallet, swaps on the venue, and
hands the result straight back to your wallet inside the same transaction.
The manager's balance is zero before the trade and zero after it.

You quit by setting the allowance to zero. There is nothing to withdraw: you
never gave anything up.

## Why a stranger cannot hurt you

**Wall 1. Strangers can only help.** Every rebalance must move your wallet
strictly closer to your own target. The contract measures drift before and
after on your real balances; if drift did not fall, the whole transaction
reverts. There is no trade a keeper can construct that leaves you worse off
against your policy.

**Wall 2. Fills are checked against reality.** Every realized fill is priced
against the chain's official feeds, on the amount your wallet actually
received, not the amount promised. A fill that sits further from the feed
than your tolerance is refused, so a keeper cannot route your order through
a manipulated pool and pocket the difference.

**Wall 3. Nothing else can move.** No function in the contract names a
destination. Swap output goes to you. The bounty, sized by you, goes to
whoever did the work, paid in proportion to how much the rebalance helped.
Splitting one rebalance into many collects exactly the same total: the
payouts telescope, so your bounty is the most you will ever pay to travel
from fully drifted back to target.

No owner. No admin. No upgrade path. No fee to anyone but the stranger who
did the work.

## The employee is self employed

The keeper that serves aumzero.com takes no funding from anyone. Before a
job it estimates the real gas and only works when the bounty covers at least
1.5x of it: a job that does not pay for itself is refused. When its gas runs
low it turns its own wages into fuel, swapping the USDG it earned for WETH on
the chain's deepest pool and unwrapping it, never spending the last of its
cash. Tidying its own demo wallet stays free. No human tops the wallet up.

## Live on Hood Chain

    Pension edition  0x4f08bdC9353060351f95207CD47D67D1cF6e5989
    Desk edition     0xf7DBb9142A194F5f409c2c587cFC559D77C40358
    Bid edition      0xb0C34AC5e846e0159f711Db84802D512E916A51F
    Wallet edition   0x3484F1cC081A98103CE0E9E42AE96a2A770eCd79
    First wallet     0xaFd484733f4B23e235bf1825c9AdA39368160B03
    Chain            Hood Chain (id 4663)
    Web              https://aumzero.com
    Venue            USDG + twenty six assets, stocks through treasuries:
                     NVDA, SPCX, TSLA, AAPL, MSFT, AMZN, MU, SPY, PLTR, SNDK,
                     INTC, AMD, GOOGL, META, USAR, SGOV, QQQ, ASML, AVGO, ORCL,
                     COIN, HOOD, ARM, CRWV, TSM, BRKB

## The pension edition

Half of every new retirement dollar in America defaults into a target
date fund, and a committee manages its glide path for decades, for a
fee. Here the committee is arithmetic. A wallet carves its law once,
with a beginning, an end, and two allocations, and the target it is
measured against slides between them second by second, for forty years
if asked. Drift appears as the law walks away from the holdings, the
same workers close it through the same walls, and the desk still
crosses opposite wallets, which now has a name older than any of this:
the young buying the market from the old.

One glide, read at three ages on the live chain at a single block:

    at 25    market 9000 bps
    at 45    market 5000 bps
    at 64    market 1200 bps, the bond near half

Sign once. Retire on schedule. Headcount zero the entire way.

## The desk edition

Wall Street's asset managers cross client orders in-house under rule
17a-7, whose one demand is the independent current market price. The
academics who read four million of those trades found the prices set
strategically to move performance between sibling funds, and many of the
trades backdated, because a human typed the price in.

Here nobody types it in. When one wallet must sell what another must
buy, anyone may call cross(): shares walk from the seller to the buyer,
cash walks straight back, and the only price the code can produce is the
official feed at that block. Both wallets must land strictly closer to
their own laws or the whole cross reverts. Nothing is lost to any pool,
so the worker who found the match is paid in full by both sides.

Ten thousand dollars of SNDK on the live chain, both ways, same block:

    through the pool      5.3272 shares    the pool kept $785.91    worker paid  $0.00
    crossed at the feed   5.7815 shares    the pool got nothing     worker paid $199.98

## The bid edition

A rebalance is a purchase, so the bounty is a price, not a tip. The bid
edition prices it. Whatever the wallet loses on the fill is subtracted from
the worker's pay, dollar for dollar, and a worker may skip the pool entirely
and hand the stock over out of its own inventory. Both routes are checked by
the same wall; whichever delivered the better price keeps the money.

Ten thousand dollars into ASML, which sits in a thin pool on a one percent
tier, on the live chain:

    through the pool      wallet receives 5.6689 ASML   worker keeps  $0.00
    from a maker          wallet receives 5.8479 ASML   worker keeps $99.99

The wallet gets 3.16 percent more stock and the worker who delivered it is
paid in full. Nothing is special cased: on a rebalance where the pool priced
better than the feed, the routing worker kept the whole bounty.

Every asset is pinned to its official on-chain feed and its real USDG pool,
measured on-chain and frozen at construction forever.

First rebalances on the live pools, reported by the contract itself:

    drift 1479 bps -> 43 bps      bounty 0.0144 USDG
    drift 9999 bps -> 305 bps     bounty 0.0969 USDG, all cash carried into
                                  a fifteen-stock target in one transaction

The custody editions that came first remain live: deposit-based vaults at
0xcc27Dd6FD74210303660643bcf6c9d115443bFcA (fifteen stocks) and
0xE46B6e60c7b2CbC1f9761B3f12a69813093B6dde (NVDA), where the first real
account was rebalanced from 10000 bps drift to 25 bps minutes after deploy.

## Interface

    setTarget(bps[], minDrift, band, bounty)  // carve your policy
    rebalance(user, trades[])                 // anyone; must help; earns bounty
    drift(user) / valueOf(user) / heldBy(user, asset)

No deposit and no withdraw: your wallet already holds everything. Assets are
indexed with the quote (USDG) at 0, every trade leg touches the quote, and
the venue (router, tokens, feeds, pool fees) is fixed at construction.

## Honest edges

- Equity feeds go quiet on weekends, and the band check inherits that
  caution: rebalances execute during hours when the feeds are speaking.
- Hood pool liquidity is what it is. Large accounts rebalance in slices;
  the band guard refuses any slice the pool cannot absorb honestly.

## Build and test

    forge test
    forge test --match-contract ForkTest --fork-url https://rpc.mainnet.chain.robinhood.com -vv

## Layout

    src/AUM0Wallet.sol           the company: allowance-based, holds nothing
    src/AUM0.sol                 custody edition (v1 and v2 venues)
    script/DeployWallet.s.sol    wallet venue (USDG + fifteen stocks)
    script/DeployV2.s.sol        custody venue, fifteen stocks
    script/Deploy.s.sol          custody venue, NVDA only
    test/                        the three walls, drift math, guards, and
                                 fork replays against the live pools
    web/                         aumzero.com: static site, RPC proxy, keeper

MIT licensed.
