// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AUM0Cross} from "../src/AUM0Cross.sol";
import {IERC20} from "../src/AUM0.sol";

/// The desk edition against the live chain, on the worst pool the venue has.
/// SanDisk's pool takes several hundred dollars out of a ten thousand dollar
/// pass. A cross between two wallets that wanted opposite trades pays that
/// pool nothing, delivers the feed to the cent, and the worker keeps the whole
/// fee from both sides.
///   forge test --match-contract CrossForkTest --fork-url https://rpc.mainnet.chain.robinhood.com -vv
contract CrossForkTest is Test {
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant USDG   = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant SNDK   = 0xB90A19fF0Af67f7779afF50A882A9CfF42446400;   // the chain's worst pool
    address constant SNDK_F = 0xfb133Fa4B7b385802B693a293606682Df47109A3;

    address alice = address(0xA11CE);   // routed through the pool
    address carol = address(0xCA401);   // crossed, buying
    address dave  = address(0xDA4E);    // crossed, selling
    address worker = address(0xC0FFEE);

    function _venue() internal returns (AUM0Cross) {
        address[] memory tokens = new address[](1);
        address[] memory feeds = new address[](1);
        uint24[] memory fees = new uint24[](1);
        uint8[] memory decs = new uint8[](1);
        tokens[0] = SNDK; feeds[0] = SNDK_F; fees[0] = 10000; decs[0] = 18;
        return new AUM0Cross(ROUTER, USDG, 6, 7 days, tokens, feeds, fees, decs);
    }

    function _law(AUM0Cross aum, address who, uint256 cash) internal {
        if (cash > 0) deal(USDG, who, cash);
        vm.startPrank(who);
        IERC20(USDG).approve(address(aum), type(uint256).max);
        IERC20(SNDK).approve(address(aum), type(uint256).max);
        uint16[] memory t = new uint16[](2);
        t[0] = 5000; t[1] = 5000;
        aum.setTarget(t, 100, 1000, 100e6);
        vm.stopPrank();
    }

    /// Ten thousand dollars into SanDisk, both ways, same block, same feed.
    function test_theCrossBeatsTheChainsWorstPool() public {
        if (block.chainid != 4663) { vm.skip(true); return; }

        (, int256 answer,,,) = IFeedLike(SNDK_F).latestRoundData();
        uint256 atFeed = (10000e6 * 1e20) / uint256(answer);   // what ten thousand dollars is, in shares

        // The old way: through the pool.
        AUM0Cross poolVenue = _venue();
        _law(poolVenue, alice, 20000e6);
        AUM0Cross.Trade[] memory tr = new AUM0Cross.Trade[](1);
        tr[0] = AUM0Cross.Trade({sellAsset: 0, buyAsset: 1, amountIn: 10000e6, fill: AUM0Cross.Fill.POOL, amountOut: 0});
        vm.prank(worker);
        poolVenue.rebalance(alice, tr);
        uint256 viaPool = IERC20(SNDK).balanceOf(alice);
        uint256 poolPay = IERC20(USDG).balanceOf(worker);
        uint256 lostToPool = ((atFeed - viaPool) * uint256(answer)) / 1e20;

        // The desk: carol wants in, dave wants out, nobody visits the pool.
        AUM0Cross deskVenue = _venue();
        _law(deskVenue, carol, 20000e6);
        deal(SNDK, dave, atFeed * 2);
        _law(deskVenue, dave, 0);
        address desk = address(0xD5C);
        vm.prank(desk);
        deskVenue.cross(dave, carol, 1, atFeed);
        uint256 viaCross = IERC20(SNDK).balanceOf(carol);
        uint256 deskPay = IERC20(USDG).balanceOf(desk);

        emit log_named_decimal_uint("shares at the feed           ", atFeed, 18);
        emit log_named_decimal_uint("shares through the pool      ", viaPool, 18);
        emit log_named_decimal_uint("the pool kept (USD)          ", lostToPool, 6);
        emit log_named_decimal_uint("shares through the cross     ", viaCross, 18);
        emit log_named_decimal_uint("worker pay, pool route       ", poolPay, 6);
        emit log_named_decimal_uint("worker pay, the cross        ", deskPay, 6);

        assertEq(viaCross, atFeed, "the cross delivers the feed exactly");
        assertGt(viaCross, viaPool, "and more stock than the pool for the same money");
        assertGt(deskPay, poolPay, "the worker who skipped the pool earned more");
        assertEq(IERC20(SNDK).balanceOf(address(deskVenue)), 0, "the desk held nothing");
        assertEq(IERC20(USDG).balanceOf(address(deskVenue)), 0, "of either kind");
    }

    /// The seller's side of the same cross: paid the official price to the
    /// cent, on a stock whose pool would have taken hundreds.
    function test_theSellerGetsTheFeedToTheCent() public {
        if (block.chainid != 4663) { vm.skip(true); return; }

        (, int256 answer,,,) = IFeedLike(SNDK_F).latestRoundData();
        uint256 atFeed = (10000e6 * 1e20) / uint256(answer);

        AUM0Cross aum = _venue();
        _law(aum, carol, 20000e6);
        deal(SNDK, dave, atFeed * 2);
        _law(aum, dave, 0);

        vm.prank(address(0xD5C));
        aum.cross(dave, carol, 1, atFeed);

        uint256 received = IERC20(USDG).balanceOf(dave);
        emit log_named_decimal_uint("the seller received (USD)", received, 6);
        // ten thousand dollars, minus his own fee, minus at most a cent of rounding
        assertApproxEqAbs(received, 10000e6 - 100e6, 10000, "the feed, to the cent");
    }
}

interface IFeedLike {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
