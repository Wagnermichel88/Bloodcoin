// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "./Test.sol";
import {BloodcoinToken} from "../src/BloodcoinToken.sol";
import {MortalityEmission} from "../src/MortalityEmission.sol";
import {BcusStaking} from "../src/BcusStaking.sol";

contract StakingTest is Test {
    uint256 constant START = 1_800_000_000;
    address constant HOLDER = address(0xCAFE);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    BcusStaking st;
    MortalityEmission em;
    BloodcoinToken token;
    uint256 base;

    function setUp() public {
        vm.warp(START);
        st = new BcusStaking();
        em = new MortalityEmission(address(0x0A), address(st), address(0), HOLDER, 1_000_000e18);
        st.bind(address(em));
        token = em.token();
        base = em.BASE_EMISSION();
        give(ALICE, 300_000e18);
        give(BOB, 300_000e18);
    }

    function give(address to, uint256 amount) internal {
        vm.prank(HOLDER);
        token.transfer(to, amount);
        vm.prank(to);
        token.approve(address(st), type(uint256).max);
    }

    function stake(address who, uint256 amount) internal {
        vm.prank(who);
        st.stake(amount);
    }

    function claim(address who) internal returns (uint256) {
        uint256 before = token.balanceOf(who);
        vm.prank(who);
        st.claim();
        return token.balanceOf(who) - before;
    }

    /// |a - b| <= tol
    function assertNear(uint256 a, uint256 b, uint256 tol) internal pure {
        assertLe(a > b ? a - b : b - a, tol);
    }

    function assertSolvent() internal view {
        assertLe(st.totalStaked() + st.reserved(), token.balanceOf(address(st)));
    }

    // ---------------------------------------------------------------- Aufbau

    function testBindChecks() public {
        BcusStaking other = new BcusStaking();
        vm.expectRevert(BcusStaking.WrongRecipient.selector);
        other.bind(address(em));
        vm.expectRevert(BcusStaking.AlreadyBound.selector);
        st.bind(address(em));
    }

    function testUnboundCannotBeUsed() public {
        BcusStaking other = new BcusStaking();
        vm.expectRevert(BcusStaking.NotBound.selector);
        other.pull();
    }

    // ---------------------------------------------------------------- Verteilung

    function testSingleStakerGetsWholeWeekStreamedOver7Days() public {
        stake(ALICE, 100e18);
        vm.warp(START + 1 weeks);
        st.pull();                                       // Woche 1 kommt an, Strom startet
        vm.warp(START + 1 weeks + 3.5 days);
        assertNear(claim(ALICE), base / 2, 1e12);        // nach halber Zeit die Hälfte
        vm.warp(START + 2 weeks);
        st.pull();                                       // Woche 2 kommt dazu
        vm.warp(START + 4 weeks);
        st.pull();
        vm.warp(START + 6 weeks);
        claim(ALICE);
        assertSolvent();
    }

    function testSplitByStakeSize() public {
        stake(ALICE, 100e18);
        stake(BOB, 300e18);
        vm.warp(START + 1 weeks);
        st.pull();
        vm.warp(START + 1 weeks + 7 days);
        uint256 a = claim(ALICE);
        uint256 b = claim(BOB);
        assertNear(a, base / 4, 1e12);
        assertNear(b, base * 3 / 4, 1e12);
        assertSolvent();
    }

    function testFlashStakerGetsAlmostNothing() public {
        stake(ALICE, 100e18);
        vm.warp(START + 1 weeks - 1);
        stake(BOB, 100_000e18);                          // riesiger Einsatz kurz vor der Ausgabe
        vm.warp(START + 1 weeks);
        st.pull();
        vm.warp(START + 1 weeks + 1);
        vm.prank(BOB);
        st.exit();                                       // sofort wieder raus
        assertLe(token.balanceOf(BOB), 300_000e18 + base / 1000);
        vm.warp(START + 2 weeks + 1);
        assertNear(claim(ALICE), base, base / 1000);
        assertSolvent();
    }

    function testDirectMintByOutsiderStillDistributed() public {
        stake(ALICE, 100e18);
        vm.warp(START + 1 weeks);
        em.mint();                                       // jemand ruft direkt am Emissions-Contract
        assertEq(st.rewardRate(), 0);
        st.pull();                                       // wird trotzdem erkannt
        vm.warp(START + 1 weeks + 7 days);
        assertNear(claim(ALICE), base, 1e12);
        assertSolvent();
    }

    function testRewardsWithoutStakersAreBurned() public {
        vm.warp(START + 1 weeks);
        st.pull();                                       // niemand stakt: Strom läuft ins Leere
        vm.warp(START + 1 weeks + 7 days);
        stake(ALICE, 100e18);                            // verbrennt, was ohne Staker geflossen ist
        assertNear(st.burned(), base, 1e12);
        assertNear(token.balanceOf(st.BURN()), base, 1e12);
        vm.warp(START + 3 weeks);
        st.pull();
        vm.warp(START + 4 weeks);
        assertNear(claim(ALICE), 2 * base, base / 100);  // nur Woche 2 + 3, Woche 1 ist weg
        assertSolvent();
    }

    function testStakerJoiningMidStreamGetsOnlyTheRest() public {
        vm.warp(START + 1 weeks);
        st.pull();
        vm.warp(START + 1 weeks + 3.5 days);
        stake(ALICE, 100e18);
        vm.warp(START + 1 weeks + 7 days);
        assertNear(claim(ALICE), base / 2, 1e12);        // zweite Hälfte der Woche
        assertNear(st.burned(), base / 2, 1e12);         // erste Hälfte verbrannt
        assertSolvent();
    }

    // ---------------------------------------------------------------- Einsatz

    function testWithdrawReturnsStake() public {
        stake(ALICE, 100e18);
        vm.prank(ALICE);
        vm.expectRevert(BcusStaking.InsufficientStake.selector);
        st.withdraw(101e18);
        vm.prank(ALICE);
        st.withdraw(100e18);
        assertEq(token.balanceOf(ALICE), 300_000e18);
        assertEq(st.totalStaked(), 0);
    }

    function testZeroAmountsRejected() public {
        vm.prank(ALICE);
        vm.expectRevert(BcusStaking.ZeroAmount.selector);
        st.stake(0);
    }

    function testLongRunStaysSolvent() public {
        stake(ALICE, 100e18);
        stake(BOB, 100e18);
        for (uint256 i = 1; i <= 30; i++) {
            vm.warp(START + i * 1 weeks + i * 3 hours);
            if (i % 3 == 0) claim(ALICE);
            if (i % 5 == 0) {
                vm.prank(BOB);
                st.withdraw(10e18);
            }
            if (i % 7 == 0) stake(ALICE, 1e18);
            st.pull();
        }
        vm.warp(START + 40 weeks);
        vm.prank(ALICE);
        st.exit();
        vm.prank(BOB);
        st.exit();
        assertSolvent();
        assertEq(st.totalStaked(), 0);
    }
}
