// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AUM0Pension} from "../src/AUM0Pension.sol";
import {IERC20} from "../src/AUM0.sol";

/// The pension edition against the live chain. The venue is the real thing a
/// retirement needs: the market (NVDA) and the bond (SGOV), with their real
/// feeds. Feeds go stale if a test warps into the future, so age is carved
/// the other way: accounts whose glides began years in the past, read at the
/// present block.
///   forge test --match-contract PensionForkTest --fork-url https://rpc.mainnet.chain.robinhood.com -vv
contract PensionForkTest is Test {
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant USDG   = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant NVDA   = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant NVDA_F = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address constant SGOV   = 0x92FD66527192E3e61d4DDd13322Aa222DE86F9B5;
    address constant SGOV_F = 0xa0DF4ee0fFf975306345875E3548Fcc519577A11;

    uint64 constant YEAR = 365 days;
    address desk = address(0xD5C);

    function _venue() internal returns (AUM0Pension) {
        address[] memory tokens = new address[](2);
        address[] memory feeds = new address[](2);
        uint24[] memory fees = new uint24[](2);
        uint8[] memory decs = new uint8[](2);
        tokens[0] = NVDA; feeds[0] = NVDA_F; fees[0] = 500;  decs[0] = 18;
        tokens[1] = SGOV; feeds[1] = SGOV_F; fees[1] = 3000; decs[1] = 18;
        return new AUM0Pension(ROUTER, USDG, 6, 7 days, tokens, feeds, fees, decs);
    }

    function _glide() internal pure returns (uint16[] memory from, uint16[] memory to) {
        from = new uint16[](3); to = new uint16[](3);
        from[0] = 500; from[1] = 9000; from[2] = 500;   // young: ninety percent market
        to[0] = 4000; to[1] = 1000; to[2] = 5000;       // retired: half the bond, a cushion of cash
    }

    function _carve(AUM0Pension aum, address who, uint64 bornAgo) internal {
        deal(USDG, who, 10000e6);
        vm.startPrank(who);
        IERC20(USDG).approve(address(aum), type(uint256).max);
        IERC20(NVDA).approve(address(aum), type(uint256).max);
        IERC20(SGOV).approve(address(aum), type(uint256).max);
        (uint16[] memory from, uint16[] memory to) = _glide();
        uint64 start = uint64(block.timestamp) - bornAgo;
        aum.setGlide(from, to, start, start + 40 * YEAR, 100, 1000, 100e6);
        vm.stopPrank();
    }

    /// One law, three careers, one real block. The same glide carved at three
    /// ages reads as three different allocations right now, and no committee
    /// was consulted about any of them.
    function test_threeAgesOfOneLawAtOneBlock() public {
        if (block.chainid != 4663) { vm.skip(true); return; }
        AUM0Pension aum = _venue();

        address at25 = address(0x25); address at45 = address(0x45); address at64 = address(0x64);
        _carve(aum, at25, 0);              // just signed
        _carve(aum, at45, 20 * YEAR);      // signed twenty years ago
        _carve(aum, at64, 39 * YEAR);      // one year from the end

        (uint16[] memory law25,,,) = aum.accountOf(at25);
        (uint16[] memory law45,,,) = aum.accountOf(at45);
        (uint16[] memory law64,,,) = aum.accountOf(at64);

        emit log_string("the same signature, read today");
        emit log_named_uint("  at 25, market bps", law25[1]);
        emit log_named_uint("  at 45, market bps", law45[1]);
        emit log_named_uint("  at 64, market bps", law64[1]);
        emit log_named_uint("  at 64, bond bps  ", law64[2]);

        assertEq(law25[1], 9000, "a young law is all appetite");
        assertEq(law45[1], 5000, "a mid life law stands exactly halfway");
        assertGt(law64[2], 4500, "an old law leans on the bond");
        assertEq(uint256(law64[0]) + law64[1] + law64[2], 10000, "and every age sums whole");
    }

    /// The generational trade on real prices: an account one year from
    /// retirement holds the market, an account signed today holds cash, and
    /// the desk moves the market from one career to the other at the feed.
    function test_theYoungBuyTheMarketFromTheOldOnTheLiveChain() public {
        if (block.chainid != 4663) { vm.skip(true); return; }
        AUM0Pension aum = _venue();

        address youngW = address(0x1994); address oldW = address(0x1954);
        _carve(aum, youngW, 0);
        _carve(aum, oldW, 41 * YEAR);                             // fully retired law

        (, int256 answer,,,) = IFeedLike(NVDA_F).latestRoundData();
        deal(NVDA, oldW, (8000e6 * 1e20) / uint256(answer));      // a career of market
        deal(USDG, oldW, 1000e6);                                 // and a little cash beside it
        uint256 sellShares = (7000e6 * 1e20) / uint256(answer);   // seven thousand of it changes hands

        uint256 oldBefore = aum.drift(oldW);
        uint256 youngBefore = aum.drift(youngW);

        vm.prank(desk);
        aum.cross(oldW, youngW, 1, sellShares);

        emit log_named_uint("old drift, before ", oldBefore);
        emit log_named_uint("old drift, after  ", aum.drift(oldW));
        emit log_named_uint("young drift, before", youngBefore);
        emit log_named_uint("young drift, after ", aum.drift(youngW));
        emit log_named_decimal_uint("the desk collected", IERC20(USDG).balanceOf(desk), 6);

        assertLt(aum.drift(oldW), oldBefore, "the retiring wallet stepped toward its law");
        assertLt(aum.drift(youngW), youngBefore, "so did the young one, in the other direction");
        assertGt(IERC20(USDG).balanceOf(desk), 0, "and the desk was paid by both");
        assertEq(IERC20(NVDA).balanceOf(address(aum)), 0, "the manager held nothing");
        assertEq(IERC20(USDG).balanceOf(address(aum)), 0, "of either kind");
    }

    /// A mid-career account that slept for years is caught up through the real
    /// pools, judged against the law as it stands today.
    function test_twentyYearsOfDriftServedAtRealPrices() public {
        if (block.chainid != 4663) { vm.skip(true); return; }
        AUM0Pension aum = _venue();

        address sleeper = address(0x5EE9);
        _carve(aum, sleeper, 20 * YEAR);   // whole worth still in cash, law at 50/50

        uint256 before_ = aum.drift(sleeper);
        AUM0Pension.Trade[] memory tr = new AUM0Pension.Trade[](2);
        tr[0] = AUM0Pension.Trade({sellAsset: 0, buyAsset: 1, amountIn: 4950e6, fill: AUM0Pension.Fill.POOL, amountOut: 0});
        tr[1] = AUM0Pension.Trade({sellAsset: 0, buyAsset: 2, amountIn: 2720e6, fill: AUM0Pension.Fill.POOL, amountOut: 0});
        vm.prank(address(0xC0FFEE));
        aum.rebalance(sleeper, tr);

        emit log_named_uint("drift before", before_);
        emit log_named_uint("drift after ", aum.drift(sleeper));
        emit log_named_decimal_uint("worker kept ", IERC20(USDG).balanceOf(address(0xC0FFEE)), 6);

        assertLt(aum.drift(sleeper), 1000, "twenty years of drift closed in one transaction");
    }
}

interface IFeedLike {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
