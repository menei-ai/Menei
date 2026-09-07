// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, IFeed, ISwapRouter} from "./AUM0.sol";

/// AUM Zero, world edition. The firm becomes a world: anyone can be a manager.
///
/// On Wall Street a separately managed account is a rich man's product. Below
/// a minimum that runs to six or seven figures, your money is pooled into a
/// fund and handled in bulk. Above it, a manager runs your own account against
/// a model portfolio, and the model business alone moves trillions, all of it
/// on custody, minimums and human hands.
///
/// Here pooling was never needed, so the minimum is zero and every account is
/// separately managed by construction. This edition adds the managers. Anyone
/// may publish a policy: an allocation, or a glide, under their own address,
/// with a royalty. Anyone may follow one, keeping their own assets in their
/// own wallet, and from then on their account is measured against the policy
/// as it stands. When the author revises it, every follower drifts at once,
/// and the robots go to work across the whole world.
///
/// The author's reach is exactly this wide: they steer weights inside the
/// venue's frozen asset list, and they collect their royalty out of bounties
/// actually paid for work actually done. They cannot touch a follower's
/// assets, and a follower leaves by carving any law of their own, one
/// signature, no notice.
///
/// Money still moves to three places only: back to the owner, to the worker
/// who helped, and the royalty the follower agreed to on the day they signed.
///
/// Everything below is the pension edition, unchanged.
///
/// Half of every new retirement dollar in America defaults into a target date
/// fund: heavy in stocks while the owner is young, sliding into bonds as they
/// age. The slide is called a glide path, and a committee manages it for
/// decades, for a fee, at Vanguard and Fidelity and everywhere else.
///
/// Here the committee is arithmetic. A wallet carves its law once, with a
/// beginning, an end, and two allocations, and from then on the target it is
/// measured against moves by itself, second by second, for forty years if
/// asked. Nothing else changes: drift appears as the law slides away from the
/// holdings, the same workers close it through the same walls, and the desk
/// still crosses two wallets that want opposite sides. A young account is a
/// buyer of stock by law and an old one is a seller of it by law, so the desk
/// does what pension systems have always done underneath: it lets the young
/// buy the market from the old, here at the feed, to the cent, with no one in
/// the middle.
///
/// Sign once. Retire on schedule. Headcount zero the entire way.
///
/// Everything below is the desk edition, unchanged: the trading desk that no
/// one works at.
///
/// Wall Street's quietest cost saver is the internal cross. When one of a
/// manager's clients is selling what another is buying, the desk matches them
/// in-house and neither pays the market. The SEC's rule for it, 17a-7, makes
/// one demand: the cross must happen at the independent current market price.
/// Researchers who later read four million of these trades found the prices
/// set strategically to move performance between sibling funds, and many of
/// the trades backdated. The rule asked for an independent price; humans were
/// the ones typing it in.
///
/// Here nobody types it in. cross() moves shares from one wallet to another
/// and cash straight back, and the only price the code can produce is the
/// chain's official feed at that block. Both wallets must land strictly closer
/// to their own targets or the whole cross reverts, so a cross that favors one
/// client at the other's expense cannot be constructed. Backdating is not a
/// concept that exists here. Neither side touches a pool, nothing is lost to
/// slippage, and the worker who found the match is paid in full by both.
///
/// Everything below the desk is the bid edition, unchanged.
///
/// Every version before this one paid a worker for moving a wallet closer to
/// its target, and checked the fill only against a band: as long as the price
/// landed within a percent or two of the official feed, the work was accepted
/// and the bounty paid in full. That is fine when the sums are small and
/// ruinous when they are not. A worker routing a large rebalance can take the
/// whole width of that band for itself and still collect, so the money is not
/// really in the bounty at all. It is in the slippage.
///
/// This edition prices the work the other way round. The contract measures
/// what each fill actually cost the wallet against the chain's official feeds,
/// adds it up across the whole rebalance, and subtracts it from the bounty. A
/// worker who fills at the feed keeps the bounty entire. A worker who leaves a
/// percent on the table keeps nothing, because the wallet already paid that
/// percent. Competition moves from being first to being cheapest.
///
/// Two ways to fill are allowed, and they are judged by the same rule:
///
///   POOL      route the leg through the venue's pool, as before.
///   INVENTORY hand the asset over yourself. The worker delivers the bought
///             asset out of their own wallet and takes the sold asset in
///             return, at whatever rate they choose. A market maker with the
///             asset on hand can beat any pool, since there is no pool fee and
///             no slippage, and the better their rate the more bounty is left
///             for them to collect.
///
/// AUM Zero, wallet edition. The asset manager that never holds your money.
///
/// There is no deposit. Your stocks and your cash sit in your own wallet, where
/// your wallet app can see them, and they stay there. You grant an allowance and
/// carve a target allocation; from then on strangers may rebalance you, and each
/// rebalance pulls from your wallet, swaps, and hands the result straight back
/// to your wallet inside the same transaction. This contract's balance is zero
/// before the trade and zero after it.
///
/// Why an allowance is safe here:
///
///   1. Every rebalance must move the wallet strictly CLOSER to your own
///      target, measured before and after on your real balances. No
///      improvement, no trade.
///   2. Every fill is checked against the chain's official feeds, on the
///      amount your wallet actually received, not the amount promised.
///   3. There is no function anywhere in this contract that names a
///      destination. Swap output goes to the owner. The bounty, sized by you,
///      goes to whoever did the work. Nothing else can move.
///
/// You quit by setting the allowance to zero. Nothing to withdraw: you never
/// gave anything up.
///
/// The asset list, feeds, and venue are fixed at construction. No owner, no
/// admin, no upgrade path.
contract AUM0World {
    struct Asset {
        address token;
        address feed;     // 1e8 USD feed; address(0) means the quote itself ($1)
        uint24 poolFee;   // fee tier of the token/quote pool
        uint8 decimals;
    }

    ISwapRouter public immutable router;
    IERC20 public immutable quote;
    uint8 public immutable quoteDecimals;
    uint256 public immutable maxPriceAge;

    Asset[] private _assets;   // index 0 is always the quote

    struct Account {
        uint16[] targetBps;   // where the law stands at glideStart
        uint16[] endBps;      // where it retires; empty means the law never moves
        uint64 glideStart;
        uint64 glideEnd;
        uint64 policyId;      // nonzero: this account follows a published policy
        uint16 minDriftBps;
        uint16 bandBps;
        uint128 bountyQuote;
    }

    struct Policy {
        address author;
        uint16[] targetBps;
        uint16[] endBps;
        uint64 glideStart;
        uint64 glideEnd;
        uint16 royaltyBps;    // the author's cut of bounties actually paid, fixed at publish
        uint32 followers;
        bool retired;
    }

    Policy[] private _policies;

    mapping(address => Account) private _accounts;
    mapping(address => bool) private _routerApproved;   // set on an asset's first routed leg

    event TargetSet(address indexed user, uint16[] targetBps, uint16 minDriftBps, uint16 bandBps, uint128 bountyQuote);
    /// A law with a beginning and an end: the target slides between the two.
    event GlideSet(address indexed user, uint16[] fromBps, uint16[] toBps, uint64 start, uint64 end);
    event PolicyPublished(uint256 indexed id, address indexed author, uint16 royaltyBps);
    event PolicyRevised(uint256 indexed id);
    event Followed(address indexed user, uint256 indexed id);
    event Royalty(address indexed author, address indexed user, uint256 amount);
    event Rebalanced(address indexed user, address indexed keeper, uint256 driftBefore, uint256 driftAfter, uint256 bounty);
    /// Two wallets met at the feed and no pool was paid.
    event Crossed(address indexed seller, address indexed buyer, address indexed keeper, uint256 asset, uint256 amount, uint256 quoteAmount);
    /// What the work earned, what the fills cost, and what was left to pay.
    event Priced(address indexed user, address indexed keeper, uint256 earned, uint256 slippage, uint256 paid);

    error BadAsset();
    error BadWeights();
    error BadParams();
    error NotConfigured();
    error StaleFeed(uint256 asset);
    error BadPrice(int256 answer);
    error DriftBelowThreshold(uint256 drift, uint256 threshold);
    error DriftNotImproved(uint256 before_, uint256 after_);
    error FillOutsideBand(uint256 inUsd, uint256 outUsd, uint16 bandBps);
    error TransferFailed();
    error NotAuthor();

    constructor(
        address _router,
        address _quote,
        uint8 _quoteDecimals,
        uint256 _maxPriceAge,
        address[] memory tokens,
        address[] memory feeds,
        uint24[] memory poolFees,
        uint8[] memory tokenDecimals
    ) {
        router = ISwapRouter(_router);
        quote = IERC20(_quote);
        quoteDecimals = _quoteDecimals;
        maxPriceAge = _maxPriceAge;

        _assets.push(Asset({token: _quote, feed: address(0), poolFee: 0, decimals: _quoteDecimals}));
        for (uint256 i; i < tokens.length; ++i) {
            _assets.push(Asset({token: tokens[i], feed: feeds[i], poolFee: poolFees[i], decimals: tokenDecimals[i]}));
        }
        // The router is approved the first time an asset is actually routed,
        // not twenty six times at birth. It costs one storage read per pool
        // leg and saves a small fortune in deployment gas, and an inventory
        // fill never needs the router at all.
    }

    /// Carve your policy. targetBps runs over all assets (quote first) and must
    /// sum to 10000. It applies to whatever the venue's assets are worth in your
    /// wallet, so cash you do not want managed belongs in a different wallet.
    function setTarget(uint16[] calldata targetBps, uint16 minDriftBps, uint16 bandBps, uint128 bountyQuote) external {
        if (targetBps.length != _assets.length) revert BadWeights();
        uint256 s;
        for (uint256 i; i < targetBps.length; ++i) s += targetBps[i];
        if (s != 10000) revert BadWeights();
        if (bandBps == 0 || bandBps > 1000 || minDriftBps == 0) revert BadParams();
        _setPolicy(msg.sender, 0);
        _accounts[msg.sender] = Account({
            targetBps: targetBps,
            endBps: new uint16[](0),
            glideStart: 0,
            glideEnd: 0,
            policyId: 0,
            minDriftBps: minDriftBps,
            bandBps: bandBps,
            bountyQuote: bountyQuote
        });
        emit TargetSet(msg.sender, targetBps, minDriftBps, bandBps, bountyQuote);
    }

    /// Carve a law that ages. From fromBps at start to toBps at end, moving a
    /// little every second in between; before start it is fromBps, after end
    /// it is toBps, forever. Emits TargetSet as well, so anything that watches
    /// for laws sees this one like any other.
    function setGlide(
        uint16[] calldata fromBps,
        uint16[] calldata toBps,
        uint64 start,
        uint64 end,
        uint16 minDriftBps,
        uint16 bandBps,
        uint128 bountyQuote
    ) external {
        if (fromBps.length != _assets.length || toBps.length != _assets.length) revert BadWeights();
        uint256 s1; uint256 s2;
        for (uint256 i; i < fromBps.length; ++i) { s1 += fromBps[i]; s2 += toBps[i]; }
        if (s1 != 10000 || s2 != 10000) revert BadWeights();
        if (end <= start) revert BadParams();
        if (bandBps == 0 || bandBps > 1000 || minDriftBps == 0) revert BadParams();
        _setPolicy(msg.sender, 0);
        _accounts[msg.sender] = Account({
            targetBps: fromBps,
            endBps: toBps,
            glideStart: start,
            glideEnd: end,
            policyId: 0,
            minDriftBps: minDriftBps,
            bandBps: bandBps,
            bountyQuote: bountyQuote
        });
        emit GlideSet(msg.sender, fromBps, toBps, start, end);
        emit TargetSet(msg.sender, fromBps, minDriftBps, bandBps, bountyQuote);
    }

    /// Publish a policy under your own address. Fixed or gliding, with a
    /// royalty that is carved in stone the day it is published: followers
    /// agree to that number and no other, forever.
    function publish(
        uint16[] calldata fromBps,
        uint16[] calldata toBps,
        uint64 start,
        uint64 end,
        uint16 royaltyBps
    ) external returns (uint256 id) {
        _checkAnchors(fromBps, toBps, start, end);
        if (royaltyBps > 5000) revert BadParams();   // at most half of any bounty
        _policies.push(Policy({
            author: msg.sender,
            targetBps: fromBps,
            endBps: toBps,
            glideStart: start,
            glideEnd: end,
            royaltyBps: royaltyBps,
            followers: 0,
            retired: false
        }));
        id = _policies.length;
        emit PolicyPublished(id, msg.sender, royaltyBps);
    }

    /// The author steers. Every follower's law moves with one revision, drift
    /// opens across the whole world at once, and the robots go to work.
    function revise(
        uint256 id,
        uint16[] calldata fromBps,
        uint16[] calldata toBps,
        uint64 start,
        uint64 end
    ) external {
        Policy storage p = _policyAt(id);
        if (msg.sender != p.author) revert NotAuthor();
        _checkAnchors(fromBps, toBps, start, end);
        p.targetBps = fromBps;
        p.endBps = toBps;
        p.glideStart = start;
        p.glideEnd = end;
        emit PolicyRevised(id);
    }

    /// An author may close the door to new followers. Existing followers keep
    /// the policy as it stands; nothing is pulled out from under anyone.
    function retire(uint256 id) external {
        Policy storage p = _policyAt(id);
        if (msg.sender != p.author) revert NotAuthor();
        p.retired = true;
    }

    /// Follow a policy. Your assets stay yours, your risk settings stay your
    /// own, and leaving is any setTarget or setGlide of your own, no notice.
    function follow(uint256 id, uint16 minDriftBps, uint16 bandBps, uint128 bountyQuote) external {
        Policy storage p = _policyAt(id);
        if (p.retired) revert BadParams();
        if (bandBps == 0 || bandBps > 1000 || minDriftBps == 0) revert BadParams();
        _setPolicy(msg.sender, uint64(id));
        Account storage a = _accounts[msg.sender];
        delete a.targetBps;
        delete a.endBps;
        a.glideStart = 0;
        a.glideEnd = 0;
        a.policyId = uint64(id);
        a.minDriftBps = minDriftBps;
        a.bandBps = bandBps;
        a.bountyQuote = bountyQuote;
        emit Followed(msg.sender, id);
        emit TargetSet(msg.sender, _targetNow(a), minDriftBps, bandBps, bountyQuote);
    }

    function _policyAt(uint256 id) internal view returns (Policy storage) {
        if (id == 0 || id > _policies.length) revert BadParams();
        return _policies[id - 1];
    }

    function _setPolicy(address user, uint64 newId) internal {
        uint64 old = _accounts[user].policyId;
        if (old == newId) return;
        if (old != 0) _policies[old - 1].followers--;
        if (newId != 0) _policies[newId - 1].followers++;
        _accounts[user].policyId = newId;
    }

    function _checkAnchors(uint16[] calldata fromBps, uint16[] calldata toBps, uint64 start, uint64 end) internal view {
        if (fromBps.length != _assets.length) revert BadWeights();
        uint256 s1;
        for (uint256 i; i < fromBps.length; ++i) s1 += fromBps[i];
        if (s1 != 10000) revert BadWeights();
        if (toBps.length != 0) {
            if (toBps.length != _assets.length) revert BadWeights();
            uint256 s2;
            for (uint256 i; i < toBps.length; ++i) s2 += toBps[i];
            if (s2 != 10000) revert BadWeights();
            if (end <= start) revert BadParams();
        }
    }

    /// The royalty on one paid bounty, and who it belongs to.
    function _royaltyOn(Account storage acct, uint256 bounty) internal view returns (uint256 cut, address author) {
        if (acct.policyId == 0 || bounty == 0) return (0, address(0));
        Policy storage p = _policies[acct.policyId - 1];
        return ((bounty * p.royaltyBps) / 10000, p.author);
    }

    /// The law as it stands right now. A fixed law is returned as carved; a
    /// gliding law is the weighted average of its two anchors at this second,
    /// floored per asset, with the quote absorbing the rounding so the whole
    /// always sums to ten thousand.
    function _targetNow(Account storage acct) internal view returns (uint16[] memory) {
        if (acct.policyId != 0) {
            Policy storage p = _policies[acct.policyId - 1];
            return _interp(p.targetBps, p.endBps, p.glideStart, p.glideEnd);
        }
        return _interp(acct.targetBps, acct.endBps, acct.glideStart, acct.glideEnd);
    }

    function _interp(uint16[] storage fromBps, uint16[] storage toBps, uint64 start, uint64 end)
        internal
        view
        returns (uint16[] memory t)
    {
        t = fromBps;
        uint256 n = t.length;
        if (n == 0 || toBps.length == 0) return t;
        if (block.timestamp <= start) return t;
        if (block.timestamp >= end) return toBps;
        uint256 num = block.timestamp - start;
        uint256 den = end - start;
        uint256 sum;
        for (uint256 i = 1; i < n; ++i) {
            uint256 v = (uint256(fromBps[i]) * (den - num) + uint256(toBps[i]) * num) / den;
            t[i] = uint16(v);
            sum += v;
        }
        t[0] = uint16(10000 - sum);
    }

    enum Fill { POOL, INVENTORY }

    struct Trade {
        uint256 sellAsset;  // one side must be the quote (index 0)
        uint256 buyAsset;
        uint256 amountIn;   // raw units of sellAsset
        Fill fill;          // route it through the pool, or hand it over yourself
        uint256 amountOut;  // INVENTORY only: what the worker delivers for it
    }

    /// Anyone may call this on any configured wallet. Nothing is held: each leg
    /// pulls from the owner, swaps, and delivers to the owner. The wallet must
    /// end strictly closer to its target than it began, or all of it reverts.
    function rebalance(address user, Trade[] calldata trades) external {
        Account storage acct = _accounts[user];
        if (acct.targetBps.length == 0 && acct.policyId == 0) revert NotConfigured();

        uint256[] memory prices = _priceAll();
        uint256 driftBefore = _drift(user, prices);
        if (driftBefore < acct.minDriftBps) revert DriftBelowThreshold(driftBefore, acct.minDriftBps);

        // What the fills cost the wallet, measured against the feeds, in quote units.
        uint256 slippageQuote;
        for (uint256 i; i < trades.length; ++i) {
            slippageQuote += _execute(user, trades[i], prices, acct.bandBps);
        }

        uint256 driftAfter = _drift(user, prices);
        if (driftAfter >= driftBefore) revert DriftNotImproved(driftBefore, driftAfter);

        // Proportional to the help given, so splitting one rebalance into many
        // pays exactly the same total: the payouts telescope.
        uint256 earned = (uint256(acct.bountyQuote) * (driftBefore - driftAfter)) / 10000;

        // And then the bill. Whatever the fills cost the wallet is taken out of
        // the worker's pay, so a rebalance that lost a percent to slippage pays
        // nothing, and one filled at the feed pays in full. The wallet is never
        // asked to pay twice for the same trade.
        uint256 bounty = earned > slippageQuote ? earned - slippageQuote : 0;
        if (bounty > 0) {
            (uint256 cut, address author) = _royaltyOn(acct, bounty);
            if (cut > 0) {
                if (!quote.transferFrom(user, author, cut)) revert TransferFailed();
                emit Royalty(author, user, cut);
            }
            if (!quote.transferFrom(user, msg.sender, bounty - cut)) revert TransferFailed();
        }
        emit Rebalanced(user, msg.sender, driftBefore, driftAfter, bounty);
        emit Priced(user, msg.sender, earned, slippageQuote, bounty);
    }

    /// The desk. Anyone may cross two configured wallets: shares walk from the
    /// seller to the buyer, the buyer's cash walks back, and the price is not
    /// quoted, negotiated, or typed in by anyone. It is the feed, to the cent.
    ///
    /// Both wallets must end strictly closer to their own law or everything
    /// reverts, so the cross can only exist where both sides genuinely wanted
    /// the opposite trade. Nothing was lost to any pool, so there is nothing
    /// to deduct from the pay: the worker who found the match collects from
    /// both sides, each in proportion to the help their wallet received.
    function cross(address seller, address buyer, uint256 asset, uint256 amount) external {
        Account storage sAcct = _accounts[seller];
        Account storage bAcct = _accounts[buyer];
        if (sAcct.targetBps.length == 0 && sAcct.policyId == 0) revert NotConfigured();
        if (bAcct.targetBps.length == 0 && bAcct.policyId == 0) revert NotConfigured();
        if (asset == 0 || asset >= _assets.length) revert BadAsset();   // cash is the leg that walks back
        if (amount == 0) revert BadParams();

        uint256[] memory prices = _priceAll();
        uint256 sBefore = _drift(seller, prices);
        uint256 bBefore = _drift(buyer, prices);
        if (sBefore < sAcct.minDriftBps) revert DriftBelowThreshold(sBefore, sAcct.minDriftBps);
        if (bBefore < bAcct.minDriftBps) revert DriftBelowThreshold(bBefore, bAcct.minDriftBps);

        // The independent current market price, produced by code instead of
        // demanded by a rule. Rounding gives the dust, under one cent, to the
        // buyer.
        uint256 quoteAmount = _usd(asset, amount, prices) / (10 ** (18 - quoteDecimals));
        if (quoteAmount == 0) revert BadParams();

        // Wallet to wallet, both directions. The desk holds nothing at any
        // point in between.
        if (!IERC20(_assets[asset].token).transferFrom(seller, buyer, amount)) revert TransferFailed();
        if (!quote.transferFrom(buyer, seller, quoteAmount)) revert TransferFailed();

        uint256 sAfter = _drift(seller, prices);
        uint256 bAfter = _drift(buyer, prices);
        if (sAfter >= sBefore) revert DriftNotImproved(sBefore, sAfter);
        if (bAfter >= bBefore) revert DriftNotImproved(bBefore, bAfter);

        _pay(seller, sBefore, sAfter, uint256(sAcct.bountyQuote));
        _pay(buyer, bBefore, bAfter, uint256(bAcct.bountyQuote));
        emit Crossed(seller, buyer, msg.sender, asset, amount, quoteAmount);
    }

    /// A crossed side pays its whole fee: the fill was at the feed, so there is
    /// no slippage bill to subtract.
    function _pay(address user, uint256 before_, uint256 after_, uint256 bountyQuote) internal {
        uint256 earned = (bountyQuote * (before_ - after_)) / 10000;
        if (earned > 0) {
            (uint256 cut, address author) = _royaltyOn(_accounts[user], earned);
            if (cut > 0) {
                if (!quote.transferFrom(user, author, cut)) revert TransferFailed();
                emit Royalty(author, user, cut);
            }
            if (!quote.transferFrom(user, msg.sender, earned - cut)) revert TransferFailed();
        }
        emit Rebalanced(user, msg.sender, before_, after_, earned);
        emit Priced(user, msg.sender, earned, 0, earned);
    }

    /// Runs one leg and returns what it cost the wallet, in quote units, judged
    /// against the feeds. Zero means the fill was at the feed or better.
    function _execute(address user, Trade calldata t, uint256[] memory prices, uint16 bandBps)
        internal
        returns (uint256 costQuote)
    {
        if (t.sellAsset != 0 && t.buyAsset != 0) revert BadAsset();   // every leg touches cash
        if (t.sellAsset == t.buyAsset) revert BadAsset();
        if (t.sellAsset >= _assets.length || t.buyAsset >= _assets.length) revert BadAsset();

        Asset memory sellA = _assets[t.sellAsset];
        Asset memory buyA = _assets[t.buyAsset];
        uint256 heldBefore = IERC20(buyA.token).balanceOf(user);
        uint256 out;

        if (t.fill == Fill.INVENTORY) {
            // The worker is the counterparty. Their asset goes to the owner and
            // the owner's goes to them, in that order, so a worker who cannot
            // deliver never gets paid first.
            if (t.amountOut == 0) revert BadParams();
            if (!IERC20(buyA.token).transferFrom(msg.sender, user, t.amountOut)) revert TransferFailed();
            if (!IERC20(sellA.token).transferFrom(user, msg.sender, t.amountIn)) revert TransferFailed();
            out = IERC20(buyA.token).balanceOf(user) - heldBefore;
        } else {
            if (!IERC20(sellA.token).transferFrom(user, address(this), t.amountIn)) revert TransferFailed();
            if (!_routerApproved[sellA.token]) {
                _routerApproved[sellA.token] = true;
                IERC20(sellA.token).approve(address(router), type(uint256).max);
            }
            router.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: sellA.token,
                    tokenOut: buyA.token,
                    fee: t.sellAsset == 0 ? buyA.poolFee : sellA.poolFee,
                    recipient: user,          // the owner is the only destination
                    amountIn: t.amountIn,
                    amountOutMinimum: 0,      // the band check below is the real guard
                    sqrtPriceLimitX96: 0
                })
            );
            out = IERC20(buyA.token).balanceOf(user) - heldBefore;
        }

        // Wall two, on what the wallet actually received. The band still stands
        // as the outer limit; the price of the fill is settled below.
        uint256 inUsd = _usd(t.sellAsset, t.amountIn, prices);
        uint256 outUsd = _usd(t.buyAsset, out, prices);
        if (outUsd < (inUsd * (10000 - bandBps)) / 10000) revert FillOutsideBand(inUsd, outUsd, bandBps);

        // The bill for this leg: what the wallet gave up, less what it got back,
        // both valued at the feed. A fill at or above the feed costs nothing.
        // _usd speaks in eighteen decimals; the bounty is paid in the quote.
        if (inUsd > outUsd) costQuote = (inUsd - outUsd) / (10 ** (18 - quoteDecimals));
    }

    // -- valuation, read straight off the wallet -------------------------------

    function _priceAll() internal view returns (uint256[] memory prices) {
        uint256 n = _assets.length;
        prices = new uint256[](n);
        prices[0] = 1e8;
        for (uint256 i = 1; i < n; ++i) {
            (, int256 p, , uint256 updatedAt, ) = IFeed(_assets[i].feed).latestRoundData();
            if (p <= 0) revert BadPrice(p);
            if (block.timestamp - updatedAt > maxPriceAge) revert StaleFeed(i);
            prices[i] = uint256(p);
        }
    }

    function _usd(uint256 asset, uint256 amount, uint256[] memory prices) internal view returns (uint256) {
        return (amount * prices[asset] * 1e10) / (10 ** _assets[asset].decimals);
    }

    function _drift(address user, uint256[] memory prices) internal view returns (uint256 d) {
        Account storage acct = _accounts[user];
        if (acct.targetBps.length == 0 && acct.policyId == 0) return 0;   // no law, no distance from it
        uint256 n = _assets.length;
        uint256 total;
        uint256[] memory usd = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            usd[i] = _usd(i, IERC20(_assets[i].token).balanceOf(user), prices);
            total += usd[i];
        }
        if (total == 0) return 0;
        uint16[] memory tgt = _targetNow(acct);
        for (uint256 i; i < n; ++i) {
            uint256 w = (usd[i] * 10000) / total;
            uint256 t = tgt[i];
            d += w > t ? w - t : t - w;
        }
    }

    // -- views -----------------------------------------------------------------

    function drift(address user) external view returns (uint256) {
        return _drift(user, _priceAll());
    }

    function valueOf(address user) external view returns (uint256 totalUsd) {
        uint256[] memory prices = _priceAll();
        for (uint256 i; i < _assets.length; ++i) {
            totalUsd += _usd(i, IERC20(_assets[i].token).balanceOf(user), prices);
        }
    }

    function heldBy(address user, uint256 asset) external view returns (uint256) {
        return IERC20(_assets[asset].token).balanceOf(user);
    }

    function accountOf(address user)
        external
        view
        returns (uint16[] memory targetBps, uint16 minDriftBps, uint16 bandBps, uint128 bountyQuote)
    {
        Account storage a = _accounts[user];
        return (_targetNow(a), a.minDriftBps, a.bandBps, a.bountyQuote);
    }

    function glideOf(address user)
        external
        view
        returns (uint16[] memory fromBps, uint16[] memory toBps, uint64 start, uint64 end)
    {
        Account storage a = _accounts[user];
        return (a.targetBps, a.endBps, a.glideStart, a.glideEnd);
    }

    function policyCount() external view returns (uint256) {
        return _policies.length;
    }

    function policyAt(uint256 id)
        external
        view
        returns (address author, uint16[] memory targetNowBps, uint16 royaltyBps, uint32 followers, bool retired)
    {
        Policy storage p = _policyAt(id);
        return (p.author, _interp(p.targetBps, p.endBps, p.glideStart, p.glideEnd), p.royaltyBps, p.followers, p.retired);
    }

    function policyOf(address user) external view returns (uint256) {
        return _accounts[user].policyId;
    }

    function assetCount() external view returns (uint256) {
        return _assets.length;
    }

    function assetAt(uint256 i) external view returns (address token, address feed, uint24 poolFee, uint8 decimals) {
        Asset memory a = _assets[i];
        return (a.token, a.feed, a.poolFee, a.decimals);
    }
}
