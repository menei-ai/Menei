// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AUM0Cross} from "../src/AUM0Cross.sol";
import {StrictERC20, MockFeed, MockRouter} from "./AUM0Wallet.t.sol";

/// The claim under test: when one wallet must sell what another must buy, the
/// desk can settle them against each other at the feed, no pool is paid, both
/// wallets land on their laws, and the worker who found the match is paid in
/// full by both sides.
contract AUM0CrossTest is Test {
    AUM0Cross aum;
    StrictERC20 usdg;
    StrictERC20 nvda;
    MockFeed nvdaFeed;
    MockRouter router;

    address alice = address(0xA11CE);   // all cash, wants half stock
    address bob = address(0xB0B);       // all stock, wants half cash
    address desk = address(0xD5C);      // the worker who spots the match

    function setUp() public {
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
        aum = new AUM0Cross(address(router), address(usdg), 6, 7 days, tokens, feeds, fees, decs);

        usdg.mint(alice, 20000e6);      // twenty thousand in cash
        nvda.mint(bob, 100e18);         // twenty thousand in stock

        _law(alice, 5000);
        _law(bob, 5000);
    }

    function _law(address who, uint16 stockBps) internal {
        vm.startPrank(who);
        usdg.approve(address(aum), type(uint256).max);
        nvda.approve(address(aum), type(uint256).max);
        uint16[] memory t = new uint16[](2);
        t[0] = 10000 - stockBps;
        t[1] = stockBps;
        aum.setTarget(t, 100, 200, 100e6);
        vm.stopPrank();
    }

    /// The headline. One cross, two wallets fixed, zero lost to any pool, and
    /// the worker collects the full fee from both sides.
    function test_oneCrossFixesBothWalletsAndPaysTwice() public {
        assertEq(aum.drift(alice), 10000, "alice is all cash");
        assertEq(aum.drift(bob), 10000, "bob is all stock");

        vm.prank(desk);
        aum.cross(bob, alice, 1, 50e18);   // ten thousand dollars of stock at the feed

        assertEq(nvda.balanceOf(alice), 50e18, "alice holds her half in stock");
        assertEq(nvda.balanceOf(bob), 50e18, "bob kept his half in stock");
        assertLt(aum.drift(alice), 100, "alice is on her law");
        assertLt(aum.drift(bob), 100, "bob is on his law");

        // Each side improved by its full ten thousand bps, so each pays its
        // entire fee: nothing was lost to a pool, so nothing is deducted.
        uint256 paid = usdg.balanceOf(desk);
        emit log_named_decimal_uint("the desk collected", paid, 6);
        assertEq(paid, 200e6, "the whole fee, from both sides");
    }

    /// The price is the feed and only the feed. Bob sold ten thousand dollars
    /// of stock, so ten thousand dollars is what arrives, less only his fee.
    function test_theSellerIsPaidTheFeedToTheCent() public {
        vm.prank(desk);
        aum.cross(bob, alice, 1, 50e18);
        assertEq(usdg.balanceOf(bob), 10000e6 - 100e6, "the feed price, minus his own fee");
    }

    /// Wall one holds for the seller: a cross that flips a wallet past its law
    /// is not an improvement and cannot happen.
    function test_aCrossThatHurtsTheSellerReverts() public {
        vm.prank(desk);
        vm.expectRevert(abi.encodeWithSelector(AUM0Cross.DriftNotImproved.selector, 10000, 10000));
        aum.cross(bob, alice, 1, 100e18);   // selling everything just swaps his problem
    }

    /// And for the buyer, independently. Alice wants a tenth in stock; a cross
    /// that buries her in it reverts even though it would help the seller.
    function test_aCrossThatHurtsTheBuyerReverts() public {
        _law(alice, 1000);
        vm.prank(desk);
        vm.expectRevert();
        aum.cross(bob, alice, 1, 75e18);
    }

    /// Both wallets must have carved a law. The desk cannot volunteer anyone.
    function test_bothSidesMustHaveALaw() public {
        address carol = address(0xCA401);
        usdg.mint(carol, 20000e6);
        vm.prank(desk);
        vm.expectRevert(AUM0Cross.NotConfigured.selector);
        aum.cross(bob, carol, 1, 50e18);
    }

    /// Cash is the leg that walks back; it cannot be the thing crossed.
    function test_crossingCashIsNotAThing() public {
        vm.prank(desk);
        vm.expectRevert(AUM0Cross.BadAsset.selector);
        aum.cross(bob, alice, 0, 1000e6);
    }

    /// Each side pays by its own law. Bob set a smaller fee than alice, so the
    /// same cross pays the desk differently from each pocket.
    function test_eachSidePaysByItsOwnLaw() public {
        vm.startPrank(bob);
        uint16[] memory t = new uint16[](2);
        t[0] = 5000; t[1] = 5000;
        aum.setTarget(t, 100, 200, 40e6);   // bob's fee cap is forty dollars
        vm.stopPrank();

        vm.prank(desk);
        aum.cross(bob, alice, 1, 50e18);
        assertEq(usdg.balanceOf(desk), 140e6, "a hundred from alice, forty from bob");
    }

    /// A half-sized cross pays half: the payouts telescope, exactly as they do
    /// for rebalances.
    function test_payIsProportionalToTheHelp() public {
        vm.prank(desk);
        aum.cross(bob, alice, 1, 25e18);
        // paying the fee itself nudges the weights a few bps, which is honest
        assertApproxEqAbs(aum.drift(alice), 5000, 25, "alice is half fixed");
        assertApproxEqAbs(usdg.balanceOf(desk), 100e6, 1e6, "so each side paid half its fee");
    }

    /// Wall three. The desk in the middle holds nothing at any point.
    function test_theDeskHoldsNothing() public {
        vm.prank(desk);
        aum.cross(bob, alice, 1, 50e18);
        assertEq(usdg.balanceOf(address(aum)), 0);
        assertEq(nvda.balanceOf(address(aum)), 0);
    }

    /// The bid edition underneath is intact: a plain pool rebalance still works
    /// on the same venue.
    function test_theBidEditionUnderneathIsUntouched() public {
        router.setSlippage(0);
        address worker = address(0xC0FFEE);
        AUM0Cross.Trade[] memory tr = new AUM0Cross.Trade[](1);
        tr[0] = AUM0Cross.Trade({sellAsset: 0, buyAsset: 1, amountIn: 10000e6, fill: AUM0Cross.Fill.POOL, amountOut: 0});
        vm.prank(worker);
        aum.rebalance(alice, tr);
        assertLt(aum.drift(alice), 100, "rebalanced through the pool as before");
        assertGt(usdg.balanceOf(worker), 99e6, "and the clean fill paid in full");
    }
}
