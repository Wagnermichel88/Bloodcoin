// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "./Test.sol";
import {BloodcoinToken} from "../src/BloodcoinToken.sol";
import {MortalityEmission} from "../src/MortalityEmission.sol";
import {BcusStaking} from "../src/BcusStaking.sol";
import {BcusMining} from "../src/BcusMining.sol";
import {FounderLock} from "../src/FounderLock.sol";

/// Zum Testen: Ziel und Zähler direkt setzen, damit nicht jede Lösung echt gesucht werden muss.
contract MiningHarness is BcusMining {
    function setTarget(uint256 t) external { target = t; }
    function setPeriod(uint256 start, uint256 solutions) external {
        periodStart = start;
        periodSolutions = solutions;
    }
}

contract MiningTest is Test {
    uint256 constant START = 1_800_000_000;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant FOUNDER = address(0xF00D);

    MiningHarness mn;
    BcusStaking st;
    MortalityEmission em;
    BloodcoinToken token;
    FounderLock lock;
    uint256 base;

    function setUp() public {
        vm.warp(START);
        st = new BcusStaking();
        mn = new MiningHarness();
        lock = new FounderLock(FOUNDER);
        em = new MortalityEmission(address(0x0A), address(st), address(mn), address(lock), 1_000_000e18);
        st.bind(address(em));
        mn.bind(address(em));
        token = em.token();
        base = em.BASE_EMISSION();
    }

    function mineAs(address who) internal returns (uint256) {
        vm.prank(who);
        return mn.mine(0);
    }

    // ---------------------------------------------------------------- Aufbau

    function testBindChecks() public {
        BcusMining other = new BcusMining();
        vm.expectRevert(BcusMining.WrongMiner.selector);
        other.bind(address(em));
        vm.expectRevert(BcusMining.AlreadyBound.selector);
        mn.bind(address(em));
    }

    function testUnboundCannotMine() public {
        BcusMining other = new BcusMining();
        vm.expectRevert(BcusMining.NotBound.selector);
        other.mine(0);
    }

    function testEmissionSplitHalfHalf() public {
        vm.warp(START + 1 weeks);
        em.mint();
        assertEq(token.balanceOf(address(mn)), base / 2);
        assertEq(token.balanceOf(address(st)), base - base / 2);
    }

    // ---------------------------------------------------------------- Proof of Work

    function testRealProofOfWork() public {
        // Echtes Ziel (leichteste Stufe): eine gültige Nonce suchen wie ein Miner.
        assertEq(mn.currentTarget(), mn.MAX_TARGET());
        uint256 nonce;
        while (uint256(mn.solutionHash(ALICE, nonce)) > mn.MAX_TARGET()) nonce++;
        vm.warp(START + 1 weeks);
        bytes32 before = mn.challenge();
        vm.prank(ALICE);
        uint256 reward = mn.mine(nonce);
        assertEq(reward, (base / 2) * 40 minutes / 1 weeks);  // Pause länger als 40 Min.: gedeckelt
        assertEq(token.balanceOf(ALICE), reward);
        assertTrue(mn.challenge() != before);
    }

    function testBadSolutionRejected() public {
        mn.setTarget(mn.MIN_TARGET());
        vm.warp(START + 1 weeks);
        vm.prank(ALICE);
        vm.expectRevert(BcusMining.BadSolution.selector);
        mn.mine(12345);
    }

    function testCopiedSolutionDoesNotWorkForSomeoneElse() public {
        uint256 nonce;
        while (uint256(mn.solutionHash(ALICE, nonce)) > mn.MAX_TARGET()) nonce++;
        // Gleiche Nonce, andere Adresse: anderer Hash. Mit grosser Wahrscheinlichkeit ungültig.
        if (uint256(mn.solutionHash(BOB, nonce)) > mn.MAX_TARGET()) {
            vm.warp(START + 1 weeks);
            vm.prank(BOB);
            vm.expectRevert(BcusMining.BadSolution.selector);
            mn.mine(nonce);
        }
    }

    function testNothingToMineBeforeFirstWeek() public {
        mn.setTarget(type(uint256).max);
        vm.prank(ALICE);
        vm.expectRevert(BcusMining.NothingToMine.selector);
        mn.mine(0);
    }

    // ---------------------------------------------------------------- Belohnung

    function testNoWindfallAfterLongPause() public {
        mn.setTarget(type(uint256).max);
        vm.warp(START + 52 weeks);                       // ein Jahr schürft niemand
        uint256 pool = 52 * (base / 2);
        mn.setPeriod(block.timestamp, 0);                // keine Anpassung auslösen
        uint256 r = mineAs(ALICE);
        assertNear(r, pool * 40 minutes / 1 weeks, 1e15); // höchstens 40/10080 des Vorrats, kein Topf
    }

    function testAboutOneWeekOfRewardPerWeekOfSolutions() public {
        mn.setTarget(type(uint256).max);
        vm.warp(START + 1 weeks);
        mn.setPeriod(block.timestamp, 0);                // keine Anpassung auslösen
        uint256 got;
        for (uint256 i; i < 100; i++) {
            vm.warp(START + 1 weeks + (i + 1) * 10 minutes); // eine Lösung alle 10 Minuten
            got += mineAs(i % 2 == 0 ? ALICE : BOB);
        }
        // 100 Lösungen bekommen etwa 1 - (1007/1008)^100 = 9,4 % der Wochenhälfte.
        assertNear(got, (base / 2) * 94 / 1000, (base / 2) / 200);
        assertEq(token.balanceOf(ALICE) + token.balanceOf(BOB), got);
    }

    function testRapidSolutionsEarnAlmostNothing() public {
        mn.setTarget(type(uint256).max);
        vm.warp(START + 1 weeks);
        mn.setPeriod(block.timestamp, 0);
        mineAs(ALICE);
        vm.prank(BOB);
        vm.expectRevert(BcusMining.NothingToMine.selector);
        mn.mine(1);                                      // gleicher Block: nichts
        uint256 fast;
        for (uint256 i = 1; i <= 50; i++) {
            vm.warp(START + 1 weeks + i);                // 50 Lösungen in 50 Sekunden
            fast += mineAs(BOB);
        }
        assertLe(fast, (base / 2) / 10000);              // < 0,01 % der Wochenhälfte
    }

    function testMinedCoinsCanBeStaked() public {
        mn.setTarget(type(uint256).max);
        vm.warp(START + 1 weeks);
        mn.setPeriod(block.timestamp, 0);
        uint256 r = mineAs(ALICE);
        vm.startPrank(ALICE);
        token.approve(address(st), r);
        st.stake(r);                                     // Henne-Ei gelöst: Staker ohne Gründer
        vm.stopPrank();
        vm.warp(START + 2 weeks);
        st.pull();
        vm.warp(START + 3 weeks);
        vm.prank(ALICE);
        st.claim();
        assertLe(base / 2 - base / 100, token.balanceOf(ALICE));
    }

    // ---------------------------------------------------------------- Schwierigkeit

    function testTooFastMakesHarder() public {
        mn.setTarget(2 ** 200);
        mn.setPeriod(START, 144);                        // 144 Lösungen in 6 Stunden statt 24
        vm.warp(START + 6 hours);
        assertNearRel(mn.currentTarget(), 2 ** 198);     // 4x schwerer (Grenze)
        mn.setPeriod(START, 144);
        vm.warp(START + 12 hours);
        assertNearRel(mn.currentTarget(), 2 ** 199);     // halb so schnell wie geplant: 2x schwerer
    }

    function testTooSlowMakesEasier() public {
        mn.setTarget(2 ** 200);
        mn.setPeriod(START, 144);
        vm.warp(START + 48 hours);                       // doppelt so lange wie geplant
        assertNearRel(mn.currentTarget(), 2 ** 201);
    }

    function testStalledMiningGetsEasierAfterFourDays() public {
        mn.setTarget(2 ** 200);
        mn.setPeriod(START, 3);                          // Miner verschwinden
        vm.warp(START + 3 days);
        assertEq(mn.currentTarget(), 2 ** 200);          // noch keine Anpassung
        vm.warp(START + 4 days);
        assertEq(mn.currentTarget(), 2 ** 202);          // 4x leichter
    }

    function testTargetStaysWithinBounds() public {
        mn.setTarget(mn.MAX_TARGET());
        mn.setPeriod(START, 0);
        vm.warp(START + 30 days);
        assertEq(mn.currentTarget(), mn.MAX_TARGET());
        mn.setTarget(mn.MIN_TARGET());
        mn.setPeriod(START, 144);
        vm.warp(START + 1);
        assertEq(mn.currentTarget(), mn.MIN_TARGET());
    }

    function testRetargetIsAppliedOnMine() public {
        mn.setTarget(mn.MAX_TARGET() / 2);
        mn.setPeriod(START, 144);
        vm.warp(START + 1 weeks);                        // viel zu langsam: leichter, bis zur Obergrenze
        assertEq(mn.currentTarget(), mn.MAX_TARGET());
        uint256 nonce;
        while (uint256(mn.solutionHash(ALICE, nonce)) > mn.MAX_TARGET()) nonce++;
        vm.prank(ALICE);
        mn.mine(nonce);
        assertEq(mn.target(), mn.MAX_TARGET());          // auf die Obergrenze geklemmt
        assertEq(mn.periodSolutions(), 1);
        assertEq(mn.periodStart(), START + 1 weeks);
    }

    /// Abweichung höchstens ein Billionstel (Rundung in t / expected * elapsed).
    function assertNearRel(uint256 a, uint256 b) internal pure {
        assertNear(a, b, b / 1e12);
    }

    function assertNear(uint256 a, uint256 b, uint256 tol) internal pure {
        assertLe(a > b ? a - b : b - a, tol);
    }
}
