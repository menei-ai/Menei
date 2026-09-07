// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AUM0World} from "../src/AUM0World.sol";
import {IERC20} from "../src/AUM0.sol";

/// The world edition against the live chain: a manager publishes a sixty
/// forty, a stranger follows it with real prices around them, a worker walks
/// the wallet onto the author's law through the real pools, and the royalty
/// arrives without the author ever touching a coin.
///   forge test --match-contract WorldForkTest --fork-url https://rpc.mainnet.chain.robinhood.com -vv
contract WorldForkTest is Test {
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant USDG   = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant NVDA   = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant NVDA_F = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address constant SGOV   = 0x92FD66527192E3e61d4DDd13322Aa222DE86F9B5;
    address constant SGOV_F = 0xa0DF4ee0fFf975306345875E3548Fcc519577A11;

    function test_aManagerAndAFollowerWhoNeverMet() public {
        if (block.chainid != 4663) { vm.skip(true); return; }

        address[] memory tokens = new address[](2);
        address[] memory feeds = new address[](2);
        uint24[] memory fees = new uint24[](2);
        uint8[] memory decs = new uint8[](2);
        tokens[0] = NVDA; feeds[0] = NVDA_F; fees[0] = 500;  decs[0] = 18;
        tokens[1] = SGOV; feeds[1] = SGOV_F; fees[1] = 3000; decs[1] = 18;
        AUM0World aum = new AUM0World(ROUTER, USDG, 6, 7 days, tokens, feeds, fees, decs);

        address manager = address(0xA07704);
        address client = address(0xC11E27);

        // the manager publishes a sixty forty and asks a tenth of any bounty
        uint16[] memory mix = new uint16[](3);
        mix[0] = 500; mix[1] = 5500; mix[2] = 4000;
        vm.prank(manager);
        uint256 id = aum.publish(mix, new uint16[](0), 0, 0, 1000);

        // a stranger follows it: one signature, no deposit, no minimum
        deal(USDG, client, 10000e6);
        vm.startPrank(client);
        IERC20(USDG).approve(address(aum), type(uint256).max);
        IERC20(NVDA).approve(address(aum), type(uint256).max);
        IERC20(SGOV).approve(address(aum), type(uint256).max);
        aum.follow(id, 100, 1000, 100e6);
        vm.stopPrank();

        uint256 before_ = aum.drift(client);

        AUM0World.Trade[] memory tr = new AUM0World.Trade[](2);
        tr[0] = AUM0World.Trade({sellAsset: 0, buyAsset: 1, amountIn: 5450e6, fill: AUM0World.Fill.POOL, amountOut: 0});
        tr[1] = AUM0World.Trade({sellAsset: 0, buyAsset: 2, amountIn: 3960e6, fill: AUM0World.Fill.POOL, amountOut: 0});
        vm.prank(address(0xC0FFEE));
        aum.rebalance(client, tr);

        emit log_named_uint("drift before", before_);
        emit log_named_uint("drift after ", aum.drift(client));
        emit log_named_decimal_uint("manager royalty", IERC20(USDG).balanceOf(manager), 6);
        emit log_named_decimal_uint("worker pay     ", IERC20(USDG).balanceOf(address(0xC0FFEE)), 6);

        assertLt(aum.drift(client), 1000, "the stranger landed on the manager's law");
        assertGt(IERC20(USDG).balanceOf(manager), 0, "the manager was paid without touching a coin");
        assertEq(IERC20(NVDA).balanceOf(address(aum)), 0, "the firm held nothing");
        assertEq(IERC20(USDG).balanceOf(address(aum)), 0, "of either kind");
    }
}
