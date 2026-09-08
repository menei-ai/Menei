// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AUM0World} from "../src/AUM0World.sol";
import {DeployWorld2} from "../script/DeployWorld2.s.sol";
import {IERC20} from "../src/AUM0.sol";

/// Bitcoin joins the venue, against the live chain. cbBTC has an official
/// feed but its cash pool is still a puddle, and the machine does not care:
/// the desk settles two wallets at the feed without a pool, and a worker can
/// be the counterparty out of their own inventory. The walls hold at eight
/// decimals exactly as they do at eighteen.
///   forge test --match-contract WorldBtcForkTest --fork-url https://rpc.mainnet.chain.robinhood.com -vv
contract WorldBtcForkTest is Test {
    address constant USDG   = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant CBBTC  = 0xCEC185eB182c47d1bA1EFc84e6959e18cd620Be4;
    address constant BTC_F  = 0x3546407C5F94dD7Eab3a853D245b5C5EAb53318a;
    uint256 constant BTC    = 27;   // cash 0, the twenty six, then bitcoin

    address saver = address(0x5A0E9);    // all cash, wants half bitcoin
    address whale = address(0x88A1E);    // all bitcoin, wants half cash
    address desk = address(0xD5C);
    address worker = address(0xC0FFEE);

    function _venue() internal returns (AUM0World aum) {
        aum = new DeployWorld2().deployForTest();
    }

    function _law(AUM0World aum, address who) internal {
        vm.startPrank(who);
        IERC20(USDG).approve(address(aum), type(uint256).max);
        IERC20(CBBTC).approve(address(aum), type(uint256).max);
        uint16[] memory t = new uint16[](28);
        t[0] = 5000; t[BTC] = 5000;
        aum.setTarget(t, 100, 1000, 100e6);
        vm.stopPrank();
    }

    function _price() internal view returns (uint256) {
        (, int256 answer,,,) = IFeedLike(BTC_F).latestRoundData();
        return uint256(answer);
    }

    /// Eight decimals count as honestly as eighteen: a hundredth of a coin
    /// is worth what the official feed says it is, to the cent.
    function test_eightDecimalsCountHonestly() public {
        if (block.chainid != 4663) { vm.skip(true); return; }
        AUM0World aum = _venue();
        deal(CBBTC, saver, 1_000_000);         // 0.01 cbBTC
        deal(USDG, saver, 100e6);              // and a hundred dollars
        uint256 want = (_price() * 1e10) / 100 + 100e18;
        assertApproxEqRel(aum.valueOf(saver), want, 1e12, "the ledger reads the feed");
    }

    /// The first bitcoin desk. No pool exists worth the name, and none is
    /// needed: one cross moves the coin from the wallet with too much to the
    /// wallet with none, at the official price, and both land on their laws.
    function test_theDeskCrossesBitcoinAtTheOfficialFeed() public {
        if (block.chainid != 4663) { vm.skip(true); return; }
        AUM0World aum = _venue();

        uint256 px = _price();
        uint256 tenGrand = (10000e6 * 1e10) / px;   // ten thousand dollars of coin, 8 decimals
        deal(USDG, saver, 20000e6);
        deal(CBBTC, whale, tenGrand * 2);
        _law(aum, saver);
        _law(aum, whale);

        assertEq(aum.drift(saver), 10000, "the saver is all cash");
        assertEq(aum.drift(whale), 10000, "the whale is all coin");

        vm.prank(desk);
        aum.cross(whale, saver, BTC, tenGrand);

        emit log_named_uint("saver drift after", aum.drift(saver));
        emit log_named_uint("whale drift after", aum.drift(whale));
        emit log_named_decimal_uint("the desk collected", IERC20(USDG).balanceOf(desk), 6);
        assertLt(aum.drift(saver), 150, "half the savings became bitcoin, on the law");
        assertLt(aum.drift(whale), 150, "half the coin became cash, on the law");
        assertApproxEqAbs(IERC20(USDG).balanceOf(whale), 10000e6 - 100e6, 10000, "the whale got the feed, less his fee, to the cent");
        assertEq(IERC20(CBBTC).balanceOf(address(aum)), 0, "the venue held no coin");
        assertEq(IERC20(USDG).balanceOf(address(aum)), 0, "and no cash");
    }

    /// A worker with coin in their pocket is a market all by themselves:
    /// the inventory fill hands bitcoin to a buyer at the feed, no pool
    /// visited, and a clean fill is paid in full.
    function test_aWorkerIsTheBitcoinMarket() public {
        if (block.chainid != 4663) { vm.skip(true); return; }
        AUM0World aum = _venue();

        deal(USDG, saver, 20000e6);
        _law(aum, saver);
        uint256 px = _price();
        uint256 coin = (10000e6 * 1e10) / px;
        deal(CBBTC, worker, coin * 2);
        vm.startPrank(worker);
        IERC20(CBBTC).approve(address(aum), type(uint256).max);

        AUM0World.Trade[] memory tr = new AUM0World.Trade[](1);
        tr[0] = AUM0World.Trade({sellAsset: 0, buyAsset: BTC, amountIn: 10000e6, fill: AUM0World.Fill.INVENTORY, amountOut: coin});
        aum.rebalance(saver, tr);
        vm.stopPrank();

        emit log_named_uint("saver drift after", aum.drift(saver));
        emit log_named_decimal_uint("worker pay", IERC20(USDG).balanceOf(worker), 6);
        assertLt(aum.drift(saver), 150, "the wallet is on its law");
        assertEq(IERC20(CBBTC).balanceOf(saver), coin, "the coin arrived from the worker's own pocket");
        assertGt(IERC20(USDG).balanceOf(worker), 10099e6, "the sale price plus the full bounty");
    }
}

interface IFeedLike {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
