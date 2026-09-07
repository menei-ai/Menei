// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AUM0World} from "../src/AUM0World.sol";
import {StrictERC20, MockFeed, MockRouter} from "./AUM0Wallet.t.sol";

/// The claim under test: anyone may publish a policy and anyone may follow it
/// without moving a coin. The author steers weights and collects a royalty out
/// of bounties actually paid; they can never touch a follower's assets, and a
/// follower leaves with one signature of their own.
contract AUM0WorldTest is Test {
    AUM0World aum;
    StrictERC20 usdg;
    StrictERC20 nvda;
    MockFeed nvdaFeed;
    MockRouter router;

    address author = address(0xA07704);
    address f1 = address(0xF001);
    address f2 = address(0xF002);
    address worker = address(0xC0FFEE);

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
        aum = new AUM0World(address(router), address(usdg), 6, 7 days, tokens, feeds, fees, decs);

        usdg.mint(f1, 20000e6);
        usdg.mint(f2, 20000e6);
        for (uint256 i; i < 2; ++i) {
            address who = i == 0 ? f1 : f2;
            vm.startPrank(who);
            usdg.approve(address(aum), type(uint256).max);
            nvda.approve(address(aum), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _pair(uint16 a, uint16 b) internal pure returns (uint16[] memory t) {
        t = new uint16[](2);
        t[0] = a; t[1] = b;
    }

    function _none() internal pure returns (uint16[] memory t) {
        t = new uint16[](0);
    }

    function _publish5050(uint16 royalty) internal returns (uint256 id) {
        vm.prank(author);
        id = aum.publish(_pair(5000, 5000), _none(), 0, 0, royalty);
    }

    /// Following costs nothing and moves nothing: the account is simply
    /// measured against the author's law from then on.
    function test_followingIsASignatureNotADeposit() public {
        uint256 id = _publish5050(1000);
        vm.prank(f1);
        aum.follow(id, 100, 200, 100e6);

        assertEq(aum.policyOf(f1), id, "the account carries the policy");
        (uint16[] memory law,,,) = aum.accountOf(f1);
        assertEq(law[1], 5000, "and is measured against the author's weights");
        assertEq(usdg.balanceOf(f1), 20000e6, "while not a coin has moved");
        assertEq(aum.drift(f1), 10000, "all cash against a half stock law: drift is real");
    }

    /// The aumworld moment. The author revises once, and every follower in the
    /// world drifts at the same instant, with no trade and no notice.
    function test_oneRevisionMovesEveryFollower() public {
        uint256 id = _publish5050(1000);
        vm.prank(f1);
        aum.follow(id, 100, 200, 100e6);
        vm.prank(f2);
        aum.follow(id, 100, 200, 100e6);

        // both walk onto the law first
        vm.startPrank(worker);
        AUM0World.Trade[] memory tr = new AUM0World.Trade[](1);
        tr[0] = AUM0World.Trade({sellAsset: 0, buyAsset: 1, amountIn: 10000e6, fill: AUM0World.Fill.POOL, amountOut: 0});
        aum.rebalance(f1, tr);
        aum.rebalance(f2, tr);
        vm.stopPrank();
        assertLt(aum.drift(f1), 150, "follower one on the law");
        assertLt(aum.drift(f2), 150, "follower two on the law");

        vm.prank(author);
        aum.revise(id, _pair(8000, 2000), _none(), 0, 0);

        assertGt(aum.drift(f1), 2500, "one revision, follower one drifts");
        assertGt(aum.drift(f2), 2500, "and follower two drifts the same instant");
    }

    /// The royalty comes out of bounties actually paid, at the rate carved at
    /// publish. The author is paid for steering; the worker for working.
    function test_theAuthorIsPaidOutOfPaidBounties() public {
        uint256 id = _publish5050(1000);   // ten percent of every paid bounty
        vm.prank(f1);
        aum.follow(id, 100, 200, 100e6);

        AUM0World.Trade[] memory tr = new AUM0World.Trade[](1);
        tr[0] = AUM0World.Trade({sellAsset: 0, buyAsset: 1, amountIn: 10000e6, fill: AUM0World.Fill.POOL, amountOut: 0});
        vm.prank(worker);
        aum.rebalance(f1, tr);

        uint256 authorGot = usdg.balanceOf(author);
        uint256 workerGot = usdg.balanceOf(worker);
        emit log_named_decimal_uint("author royalty", authorGot, 6);
        emit log_named_decimal_uint("worker pay    ", workerGot, 6);
        assertGt(authorGot, 9e6, "the author collected about a tenth");
        assertApproxEqAbs(authorGot * 9, workerGot, 1e6, "and the worker kept the other nine tenths");
        assertEq(usdg.balanceOf(address(aum)), 0, "the manager held nothing");
    }

    /// A worker who fills badly is paid nothing, so the author is paid nothing
    /// either: royalties ride on real work, not on existing.
    function test_noBountyNoRoyalty() public {
        uint256 id = _publish5050(1000);
        vm.prank(f1);
        aum.follow(id, 100, 200, 100e6);

        router.setSlippage(150);   // the fill eats more than the whole bounty
        AUM0World.Trade[] memory tr = new AUM0World.Trade[](1);
        tr[0] = AUM0World.Trade({sellAsset: 0, buyAsset: 1, amountIn: 10000e6, fill: AUM0World.Fill.POOL, amountOut: 0});
        vm.prank(worker);
        aum.rebalance(f1, tr);

        assertEq(usdg.balanceOf(author), 0, "no paid bounty, no royalty");
        assertEq(usdg.balanceOf(worker), 0, "and no pay for a bad fill, as always");
    }

    /// Leaving is one signature of your own. The policy link clears, the
    /// follower count falls, and the author earns nothing from you again.
    function test_leavingIsOneSignature() public {
        uint256 id = _publish5050(1000);
        vm.prank(f1);
        aum.follow(id, 100, 200, 100e6);
        (,,, uint32 followers,) = aum.policyAt(id);
        assertEq(followers, 1, "one follower on the book");

        vm.prank(f1);
        aum.setTarget(_pair(5000, 5000), 100, 200, 100e6);   // any law of your own

        assertEq(aum.policyOf(f1), 0, "the link is gone");
        (,,, followers,) = aum.policyAt(id);
        assertEq(followers, 0, "and the book says so");

        AUM0World.Trade[] memory tr = new AUM0World.Trade[](1);
        tr[0] = AUM0World.Trade({sellAsset: 0, buyAsset: 1, amountIn: 10000e6, fill: AUM0World.Fill.POOL, amountOut: 0});
        vm.prank(worker);
        aum.rebalance(f1, tr);
        assertEq(usdg.balanceOf(author), 0, "the author earns nothing from a wallet that left");
    }

    /// Only the author steers; the royalty is immutable; a retired policy
    /// takes no new followers.
    function test_theAuthorsPowersEndAtTheEdges() public {
        uint256 id = _publish5050(1000);
        vm.prank(f1);
        vm.expectRevert(AUM0World.NotAuthor.selector);
        aum.revise(id, _pair(8000, 2000), _none(), 0, 0);

        vm.prank(author);
        vm.expectRevert(AUM0World.BadParams.selector);
        aum.publish(_pair(5000, 5000), _none(), 0, 0, 5001);   // more than half is not a royalty

        vm.prank(author);
        aum.retire(id);
        vm.prank(f2);
        vm.expectRevert(AUM0World.BadParams.selector);
        aum.follow(id, 100, 200, 100e6);
    }

    /// A policy can be a pension: publish a glide once and every follower ages
    /// on the author's schedule.
    function test_aPolicyCanAge() public {
        vm.warp(1_900_000_000);
        vm.prank(author);
        uint256 id = aum.publish(_pair(1000, 9000), _pair(8000, 2000), uint64(block.timestamp), uint64(block.timestamp) + 1000, 0);
        vm.prank(f1);
        aum.follow(id, 100, 200, 100e6);

        (uint16[] memory law0,,,) = aum.accountOf(f1);
        assertEq(law0[1], 9000, "young at the start");
        vm.warp(block.timestamp + 500);
        (uint16[] memory lawMid,,,) = aum.accountOf(f1);
        assertEq(lawMid[1], 5500, "halfway along, halfway between");
    }

    /// Crossed followers pay their authors too: the royalty rides every kind
    /// of paid work.
    function test_royaltyRidesTheDeskAsWell() public {
        uint256 id = _publish5050(1000);
        vm.prank(f1);
        aum.follow(id, 100, 200, 100e6);
        vm.prank(f2);
        aum.follow(id, 100, 200, 100e6);

        // f2 becomes the seller: all stock, wants half cash
        vm.prank(f2);
        usdg.transfer(address(0xDEAD), 20000e6);
        nvda.mint(f2, 100e18);

        address desk = address(0xD5C);
        vm.prank(desk);
        aum.cross(f2, f1, 1, 50e18);

        assertGt(usdg.balanceOf(author), 18e6, "the author was paid by both sides of the cross");
        assertGt(usdg.balanceOf(desk), 170e6, "and the desk kept the rest");
    }
}
