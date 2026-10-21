// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "./Test.sol";
import {BloodcoinToken} from "../src/BloodcoinToken.sol";
import {MortalityEmission} from "../src/MortalityEmission.sol";
import {CreMortalityOracle} from "../src/CreMortalityOracle.sol";

/// Ersetzt den Chainlink-Forwarder: liefert signierte Berichte wie ein CRE-Netz.
contract MockForwarder {
    function deliver(CreMortalityOracle receiver, bytes memory metadata, bytes memory report) external {
        receiver.onReport(metadata, report);
    }
}

contract BloodcoinTest is Test {
    uint256 constant START = 1_800_000_000;          // 2027-01-15
    uint256 constant SAT = 1_790_985_600;            // 2026-10-03, ein Samstag 00:00 UTC
    address constant RECIPIENT = address(0xBEEF);
    address constant HOLDER = address(0xCAFE);
    bytes32 constant WF = keccak256("bcus-mortality");

    MockForwarder fwd;
    CreMortalityOracle oracle;
    MortalityEmission em;
    BloodcoinToken token;

    function setUp() public {
        vm.warp(START);
        fwd = new MockForwarder();
        oracle = new CreMortalityOracle(address(fwd));
        em = new MortalityEmission(address(oracle), RECIPIENT, address(0), HOLDER, 1_000_000e18);
        oracle.bind(address(em));
        token = em.token();
    }

    function meta(bytes32 id) internal pure returns (bytes memory) {
        return abi.encodePacked(id, bytes10("bcus-mort"), address(0xA11CE));
    }

    function deliver(uint256 weekEnding, uint256 deaths, uint256 prev) internal {
        fwd.deliver(oracle, meta(WF), abi.encode(weekEnding, deaths, prev));
    }

    // ---------------------------------------------------------------- Token

    function testTokenBasics() public {
        assertEq(token.name(), "Bloodcoin");
        assertEq(token.symbol(), "BCUS");
        assertEq(token.cap(), 21_000_000e18);
        assertEq(token.balanceOf(HOLDER), 1_000_000e18);
        assertEq(token.minter(), address(em));
    }

    function testOnlyEmissionCanMint() public {
        vm.expectRevert(BloodcoinToken.OnlyMinter.selector);
        token.mint(address(this), 1);
    }

    // ---------------------------------------------------------------- Faktor (wie cdc.js und report.py)

    function testTargetFor() public view {
        assertEq(em.targetFor(240_000, 240_000), 1000);
        assertEq(em.targetFor(247_200, 240_000), 1000);   // +3 %: noch Rauschen
        assertEq(em.targetFor(232_800, 240_000), 1000);   // -3 %
        assertEq(em.targetFor(247_440, 240_000), 995);    // +3,1 %
        assertEq(em.targetFor(252_000, 240_000), 900);    // +5 % -> 2 % über der Schwelle -> -10 %
        assertEq(em.targetFor(228_000, 240_000), 1100);   // -5 %
        assertEq(em.targetFor(264_000, 240_000), 650);    // +10 %
        assertEq(em.targetFor(276_000, 240_000), 500);    // +15 %: Untergrenze
        assertEq(em.targetFor(180_000, 240_000), 1500);   // -25 %: Obergrenze
        assertEq(em.targetFor(271_200, 240_000), 500);    // +13 %: Untergrenze erreicht
        assertEq(em.targetFor(271_000, 240_000), 504);
        assertEq(em.targetFor(1, 9_999_999), 1500);
        assertEq(em.targetFor(9_999_999, 1), 500);
    }

    function testStepToward() public view {
        assertEq(em.stepToward(1000, 900), 950);
        assertEq(em.stepToward(1000, 980), 980);
        assertEq(em.stepToward(1000, 1500), 1050);
        assertEq(em.stepToward(520, 500), 500);
        assertEq(em.stepToward(700, 700), 700);
    }

    function testFactorMovesGraduallyToTarget() public {
        // Zehn Wochen mit +15 % Übersterblichkeit: Faktor sinkt um 0,05 pro Woche bis 0,5.
        vm.warp(START + 20 weeks);
        for (uint256 i = 0; i < 10; ++i) {
            deliver(SAT + i * 1 weeks, 276_000, 240_000);
            assertEq(em.factorMilli(), 950 - 50 * i);
            assertEq(em.targetMilli(), 500);
        }
        deliver(SAT + 10 weeks, 276_000, 240_000);
        assertEq(em.factorMilli(), 500);
        // Danach normal: zurück in Schritten von 0,05.
        deliver(SAT + 11 weeks, 240_000, 240_000);
        assertEq(em.factorMilli(), 550);
        assertEq(em.targetMilli(), 1000);
    }

    // ---------------------------------------------------------------- Ausgabe

    function testNothingBeforeFirstWeek() public {
        vm.warp(START + 6 days);
        assertEq(em.mint(), 0);
    }

    function testWeeklyEmissionAndTimingDoesNotMatter() public {
        vm.warp(START + 3 weeks + 1);
        uint256 amount = em.mint();
        assertEq(amount, 3 * em.BASE_EMISSION());
        assertEq(token.balanceOf(RECIPIENT), amount);
        assertEq(em.mint(), 0);                    // zweimal abholen bringt nichts
    }

    function testHalving() public {
        assertEq(em.epochEmission(415), em.BASE_EMISSION());
        assertEq(em.epochEmission(416), em.BASE_EMISSION() / 2);
        assertEq(em.epochEmission(832), em.BASE_EMISSION() / 4);
        assertEq(em.epochEmission(64 * 416), 0);
    }

    function testReportSettlesOldEpochsAtOldFactor() public {
        vm.warp(START + 2 weeks + 1);
        deliver(SAT, 252_000, 240_000);            // Ziel 900, Faktor 950 ab jetzt
        vm.warp(START + 3 weeks + 1);
        uint256 base = em.BASE_EMISSION();
        assertEq(em.mint(), 2 * base + base * 950 / 1000);
    }

    function testCapIsNeverExceeded() public {
        vm.warp(START + 2000 weeks);
        em.mint();
        assertLe(token.totalSupply(), token.cap());
        vm.warp(START + 4000 weeks);
        em.mint();
        assertLe(token.totalSupply(), token.cap());
    }

    // ---------------------------------------------------------------- Meldungen

    function testOnlyOracleCanReport() public {
        vm.expectRevert(MortalityEmission.OnlyOracle.selector);
        em.report(SAT, 1000, 1000);
    }

    function testReportValidation() public {
        vm.startPrank(address(oracle));
        vm.expectRevert(MortalityEmission.WeekTooRecent.selector);
        em.report(1_795_219_200, 1000, 1000);         // 2026-11-21, juenger als 8 Wochen
        vm.expectRevert(MortalityEmission.NotASaturday.selector);
        em.report(SAT + 1 days, 1000, 1000);
        vm.expectRevert(MortalityEmission.NotASaturday.selector);
        em.report(SAT + 1 hours, 1000, 1000);
        vm.expectRevert(MortalityEmission.BadDeaths.selector);
        em.report(SAT, 0, 1000);
        vm.expectRevert(MortalityEmission.BadDeaths.selector);
        em.report(SAT, 10_000_000, 1000);
        vm.expectRevert(MortalityEmission.BadDeaths.selector);
        em.report(SAT, 2001, 1000);                   // mehr als doppelt so viele: Formatfehler
        vm.expectRevert(MortalityEmission.BadDeaths.selector);
        em.report(SAT, 499, 1000);
        em.report(SAT - 1 weeks, 2000, 1000);         // genau doppelt geht noch
        em.report(SAT, 252_000, 240_000);
        vm.expectRevert(MortalityEmission.WeekNotNewer.selector);
        em.report(SAT, 1000, 1000);
        vm.expectRevert(MortalityEmission.WeekNotNewer.selector);
        em.report(SAT - 1 weeks, 1000, 1000);
        em.report(SAT + 1 weeks, 990, 1010);
        vm.stopPrank();
        assertEq(em.lastWeekEnding(), SAT + 1 weeks);
    }

    // ---------------------------------------------------------------- Chainlink-Weg (CRE)

    function testOracleRoundTrip() public {
        deliver(SAT, 252_000, 240_000);
        assertEq(em.factorMilli(), 950);
        assertEq(em.lastWeekEnding(), SAT);
    }

    function testOnlyForwarderCanReport() public {
        vm.expectRevert(CreMortalityOracle.OnlyForwarder.selector);
        oracle.onReport(meta(WF), abi.encode(SAT, 252_000, 240_000));
    }

    function testBadAnswerIsRejectedWithoutRevert() public {
        deliver(SAT + 1 days, 1000, 1000);             // kein Samstag
        assertEq(em.factorMilli(), 1000);
        assertEq(em.lastWeekEnding(), 0);
    }

    function testMalformedReportReverts() public {
        vm.expectRevert(CreMortalityOracle.BadReport.selector);
        fwd.deliver(oracle, meta(WF), abi.encode(SAT, 1000));
    }

    function testPinnedWorkflow() public {
        oracle.pinWorkflow(WF);
        assertEq(oracle.workflowId(), WF);
        vm.expectRevert(CreMortalityOracle.WrongWorkflow.selector);
        fwd.deliver(oracle, meta(keccak256("anderer Workflow")), abi.encode(SAT, 252_000, 240_000));
        vm.expectRevert(CreMortalityOracle.WrongWorkflow.selector);
        fwd.deliver(oracle, "", abi.encode(SAT, 252_000, 240_000));
        deliver(SAT, 252_000, 240_000);
        assertEq(em.factorMilli(), 950);
    }

    function testPinOnlyOnceAndOnlyDeployer() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(CreMortalityOracle.AlreadyBound.selector);
        oracle.pinWorkflow(WF);
        vm.expectRevert(CreMortalityOracle.AlreadyBound.selector);
        oracle.pinWorkflow(bytes32(0));
        oracle.pinWorkflow(WF);
        vm.expectRevert(CreMortalityOracle.AlreadyBound.selector);
        oracle.pinWorkflow(keccak256("neu"));
    }

    function testUnboundOracleReverts() public {
        CreMortalityOracle fresh = new CreMortalityOracle(address(fwd));
        vm.expectRevert(CreMortalityOracle.NotBound.selector);
        fwd.deliver(fresh, meta(WF), abi.encode(SAT, 252_000, 240_000));
    }

    function testSupportsReceiverInterface() public view {
        assertTrue(oracle.supportsInterface(0x805f2132));   // onReport(bytes,bytes)
        assertTrue(oracle.supportsInterface(0x01ffc9a7));   // ERC-165
        assertFalse(oracle.supportsInterface(0xffffffff));
    }

    function testBindOnlyOnce() public {
        vm.expectRevert(CreMortalityOracle.AlreadyBound.selector);
        oracle.bind(address(1));
        vm.prank(address(0xBAD));
        vm.expectRevert(CreMortalityOracle.AlreadyBound.selector);
        oracle.bind(address(1));
    }
}
