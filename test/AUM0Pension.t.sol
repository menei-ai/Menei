// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AUM0Pension} from "../src/AUM0Pension.sol";
import {StrictERC20, MockFeed, MockRouter} from "./AUM0Wallet.t.sol";

/// The claim under test: a law can age. The target it is measured against
/// slides from one allocation to another on a schedule carved once, drift
/// appears as the law walks away from the holdings, and every worker, wall
/// and desk serves the aging account without knowing the word pension.
contract AUM0PensionTest is Test {
    AUM0Pension aum;
    StrictERC20 usdg;
    StrictERC20 nvda;
    MockFeed nvdaFeed;
    MockRouter router;

    address young = address(0x1994);   // buys stock by law
    address old = address(0x1954);     // sells stock by law
    address desk = address(0xD5C);

    uint64 constant YEAR = 365 days;

    function setUp() public {
        vm.warp(1_900_000_000);        // somewhere in 2030, so glides can start in the past
        usdg = new StrictERC20("USDG", 6);
        nvda = new StrictERC20("NVDA", 18);
        nvdaFeed = new MockFeed(200e8);
        router = new MockRouter(usdg);
        router.register(nvda, nvdaFeed);

        address[] memory tokens = new address[](1);
        tokens[0] = address(nvda);
        address[] memory feeds = new address[](1);
        feeds[0] = address(nvdaFeed);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;
        uint8[] memory decs = new uint8[](1);
        decs[0] = 18;
        aum = new AUM0Pension(address(router), address(usdg), 6, 7 days, tokens, feeds, fees, decs);
    }

    function _approve(address who) internal {
        vm.startPrank(who);
        usdg.approve(address(aum), type(uint256).max);
        nvda.approve(address(aum), type(uint256).max);
        vm.stopPrank();
    }

    function _pair(uint16 a, uint16 b) internal pure returns (uint16[] memory t) {
        t = new uint16[](2);
        t[0] = a; t[1] = b;
    }

    /// The law at this second: the start before the start, the end after the
    /// end, the weighted average in between, always summing to ten thousand.
    function test_theLawSlidesBetweenItsAnchors() public {
        _approve(young);
        uint64 start = uint64(block.timestamp);
        vm.prank(young);
        aum.setGlide(_pair(1000, 9000), _pair(8000, 2000), start, start + 1000, 100, 200, 100e6);

        (uint16[] memory t0,,,) = aum.accountOf(young);
        assertEq(t0[1], 9000, "at the start the law is the young anchor");

        vm.warp(start + 500);
        (uint16[] memory tMid,,,) = aum.accountOf(young);
        assertEq(tMid[1], 5500, "halfway along, halfway between");
        assertEq(tMid[0] + tMid[1], 10000, "and it still sums whole");

        vm.warp(start + 5000);
        (uint16[] memory tEnd,,,) = aum.accountOf(young);
        assertEq(tEnd[1], 2000, "after the end the law is retired, forever");
    }

    /// Nothing happens to anyone who carves a law the old way.
    function test_aFixedLawNeverMoves() public {
        _approve(young);
        vm.startPrank(young);
        usdg.mint(young, 20000e6);
        aum.setTarget(_pair(5000, 5000), 100, 200, 100e6);
        vm.stopPrank();
        uint256 before_ = aum.drift(young);
        vm.warp(block.timestamp + 40 * uint256(YEAR));
        assertEq(aum.drift(young), before_, "forty years pass and the law has not blinked");
    }

    /// An account that does nothing falls behind a law that moves. Drift is
    /// the distance to the law, and here the law is the thing walking.
    function test_theAccountAgesWithoutATrade() public {
        _approve(young);
        usdg.mint(young, 10000e6);
        nvda.mint(young, 50e18);       // ten thousand of each: a perfect 50/50
        uint64 start = uint64(block.timestamp);
        vm.prank(young);
        aum.setGlide(_pair(5000, 5000), _pair(9000, 1000), start, start + 100 days, 100, 200, 100e6);

        assertLt(aum.drift(young), 50, "on day zero the law and the wallet agree");
        vm.warp(start + 50 days);
        assertEq(aum.drift(young), 4000, "fifty days later the law has walked four thousand bps away");
        vm.warp(start + 100 days);
        assertEq(aum.drift(young), 8000, "and at the end it stands where it said it would");
    }

    /// The generational trade, on one desk. The young account is a buyer of
    /// stock by law and the old one is a seller of it by law, so the desk does
    /// what pension systems have always done underneath: the young buy the
    /// market from the old, at the feed, with no one in the middle.
    function test_theYoungBuyTheMarketFromTheOld() public {
        _approve(young);
        _approve(old);
        usdg.mint(young, 20000e6);     // a career of cash ahead
        nvda.mint(old, 100e18);        // a career of stock behind
        uint64 nowTs = uint64(block.timestamp);

        vm.prank(young);
        aum.setGlide(_pair(1000, 9000), _pair(8000, 2000), nowTs, nowTs + 40 * YEAR, 100, 200, 100e6);
        vm.prank(old);
        aum.setGlide(_pair(1000, 9000), _pair(8000, 2000), nowTs - 40 * YEAR, nowTs - 1, 100, 200, 100e6);

        assertEq(aum.drift(young), 18000, "the young wallet is all cash against a ninety percent law");
        assertEq(aum.drift(old), 16000, "the old wallet is all stock against a twenty percent law");

        vm.prank(desk);
        aum.cross(old, young, 1, 80e18);   // sixteen thousand dollars of stock changes generations

        assertLt(aum.drift(old), 100, "the old wallet retired onto its law");
        // the young wallet went as far as the old wallet's inventory could
        // carry it; the rest of its law waits for the next seller
        assertLt(aum.drift(young), 2000, "the young wallet closed most of a career in one trade");
        assertEq(nvda.balanceOf(young), 80e18, "the stock moved to the young");
        assertApproxEqAbs(usdg.balanceOf(old), 15840e6, 10e6, "the cash moved to the old at the feed, less its fee");
        assertGt(usdg.balanceOf(desk), 300e6, "and the desk was paid in full by both generations");
        assertEq(nvda.balanceOf(address(aum)), 0, "the manager held nothing");
        assertEq(usdg.balanceOf(address(aum)), 0, "of either kind");
    }

    /// A worker can also close aging drift through the pool, judged against
    /// the law as it stands today, by the same walls as always.
    function test_aWorkerServesTheAgingLawThroughThePool() public {
        _approve(young);
        usdg.mint(young, 20000e6);
        uint64 start = uint64(block.timestamp);
        vm.prank(young);
        aum.setGlide(_pair(9000, 1000), _pair(1000, 9000), start, start + 100 days, 100, 200, 100e6);

        vm.warp(start + 50 days);      // the law now asks for half in stock
        address worker = address(0xC0FFEE);
        AUM0Pension.Trade[] memory tr = new AUM0Pension.Trade[](1);
        tr[0] = AUM0Pension.Trade({sellAsset: 0, buyAsset: 1, amountIn: 10000e6, fill: AUM0Pension.Fill.POOL, amountOut: 0});
        vm.prank(worker);
        aum.rebalance(young, tr);

        assertLt(aum.drift(young), 100, "the wallet caught up to where the law stands today");
        assertGt(usdg.balanceOf(worker), 39e6, "and the clean fill paid for the help given");
    }

    /// The glide refuses to be carved wrong.
    function test_aBrokenGlideIsRefused() public {
        uint64 nowTs = uint64(block.timestamp);
        vm.startPrank(young);
        vm.expectRevert(AUM0Pension.BadParams.selector);
        aum.setGlide(_pair(5000, 5000), _pair(5000, 5000), nowTs + 100, nowTs + 100, 100, 200, 100e6);   // no time passes
        uint16[] memory bad = _pair(5000, 4000);                                                          // sums short
        vm.expectRevert(AUM0Pension.BadWeights.selector);
        aum.setGlide(_pair(5000, 5000), bad, nowTs, nowTs + 100, 100, 200, 100e6);
        vm.stopPrank();
    }

    /// Wherever the clock stops, the law is whole.
    function test_theLawAlwaysSumsToTenThousand() public {
        _approve(young);
        uint64 start = uint64(block.timestamp);
        vm.prank(young);
        aum.setGlide(_pair(1234, 8766), _pair(7891, 2109), start, start + 999983, 100, 200, 100e6);
        for (uint256 k; k < 12; ++k) {
            vm.warp(start + (999983 * k) / 11);
            (uint16[] memory t,,,) = aum.accountOf(young);
            assertEq(uint256(t[0]) + uint256(t[1]), 10000);
        }
    }
}
