// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "./Test.sol";
import {MortalityEmission} from "../src/MortalityEmission.sol";
import {SignedMortalityOracle} from "../src/SignedMortalityOracle.sol";

contract SignedOracleTest is Test {
    uint256 constant START = 1_800_000_000;          // 2027-01-15
    uint256 constant SAT = 1_790_985_600;            // 2026-10-03, ein Samstag 00:00 UTC
    uint256 constant KEY = 0xB10D;
    uint256 constant OTHER_KEY = 0xBAD;

    SignedMortalityOracle oracle;
    MortalityEmission em;

    function setUp() public {
        vm.warp(START);
        oracle = new SignedMortalityOracle(vm.addr(KEY));
        em = new MortalityEmission(address(oracle), address(0xBEEF), address(0), address(0xCAFE), 1_000_000e18);
        oracle.bind(address(em));
    }

    function sig(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function submit(uint256 week, uint256 deaths, uint256 prev) internal {
        oracle.submit(week, deaths, prev, sig(KEY, oracle.reportDigest(week, deaths, prev)));
    }

    function testSignedReportReachesEmission() public {
        submit(SAT, 252_000, 240_000);
        assertEq(em.targetMilli(), 900);
        assertEq(em.factorMilli(), 950);
        assertEq(em.lastWeekEnding(), SAT);
    }

    function testAnyoneCanRelay() public {
        bytes memory s = sig(KEY, oracle.reportDigest(SAT, 252_000, 240_000));
        vm.prank(address(0x1234));
        oracle.submit(SAT, 252_000, 240_000, s);
        assertEq(em.lastWeekEnding(), SAT);
    }

    function testWrongKeyRejected() public {
        bytes memory s = sig(OTHER_KEY, oracle.reportDigest(SAT, 252_000, 240_000));
        vm.expectRevert(SignedMortalityOracle.BadSignature.selector);
        oracle.submit(SAT, 252_000, 240_000, s);
    }

    function testTamperedNumbersRejected() public {
        bytes memory s = sig(KEY, oracle.reportDigest(SAT, 252_000, 240_000));
        vm.expectRevert(SignedMortalityOracle.BadSignature.selector);
        oracle.submit(SAT, 253_000, 240_000, s);
    }

    function testSignatureBoundToContract() public {
        // Gleicher Schlüssel, zweiter Contract: die Signatur für den ersten gilt dort nicht.
        SignedMortalityOracle other = new SignedMortalityOracle(vm.addr(KEY));
        MortalityEmission em2 = new MortalityEmission(address(other), address(0xBEEF), address(0), address(0xCAFE), 0);
        other.bind(address(em2));
        bytes memory s = sig(KEY, oracle.reportDigest(SAT, 252_000, 240_000));
        vm.expectRevert(SignedMortalityOracle.BadSignature.selector);
        other.submit(SAT, 252_000, 240_000, s);
    }

    function testReplayRejected() public {
        bytes memory s = sig(KEY, oracle.reportDigest(SAT, 252_000, 240_000));
        oracle.submit(SAT, 252_000, 240_000, s);
        vm.expectRevert(MortalityEmission.WeekNotNewer.selector);
        oracle.submit(SAT, 252_000, 240_000, s);
    }

    function testEmissionRulesStillApply() public {
        uint256 tooRecent = 1_795_219_200;            // 2026-11-21, juenger als 8 Wochen
        bytes memory s = sig(KEY, oracle.reportDigest(tooRecent, 240_000, 240_000));
        vm.expectRevert(MortalityEmission.WeekTooRecent.selector);
        oracle.submit(tooRecent, 240_000, 240_000, s);
    }

    function testOutOfRange() public {
        bytes memory s = sig(KEY, oracle.reportDigest(SAT, 79_999, 240_000));
        vm.expectRevert(SignedMortalityOracle.OutOfRange.selector);
        oracle.submit(SAT, 79_999, 240_000, s);
        s = sig(KEY, oracle.reportDigest(SAT, 240_000, 1_000_001));
        vm.expectRevert(SignedMortalityOracle.OutOfRange.selector);
        oracle.submit(SAT, 240_000, 1_000_001, s);
    }

    function testFormatErrorRejected() public {
        // Versehentlich eine Woche statt vier gemeldet: Verhältnis 1:4, MortalityEmission lehnt ab.
        bytes memory s = sig(KEY, oracle.reportDigest(SAT, 240_000, 960_000));
        vm.expectRevert(MortalityEmission.BadDeaths.selector);
        oracle.submit(SAT, 240_000, 960_000, s);
    }

    function testFakeReportMovesFactorOnlyOneStep() public {
        // Der Schlüssel meldet eine erfundene Katastrophe: Ziel 0,5, Faktor nur 0,95.
        submit(SAT, 400_000, 240_000);
        assertEq(em.targetMilli(), 500);
        assertEq(em.factorMilli(), 950);
    }

    function testGapIsFine() public {
        // Fällt eine Woche aus, blockiert das nichts.
        submit(SAT, 252_000, 240_000);
        submit(SAT + 2 weeks, 240_000, 240_000);
        assertEq(em.lastWeekEnding(), SAT + 2 weeks);
        assertEq(em.factorMilli(), 1000);
    }

    function testRetireStopsReports() public {
        oracle.retire(sig(KEY, oracle.retireDigest()));
        assertTrue(oracle.retired());
        bytes memory s = sig(KEY, oracle.reportDigest(SAT, 252_000, 240_000));
        vm.expectRevert(SignedMortalityOracle.IsRetired.selector);
        oracle.submit(SAT, 252_000, 240_000, s);
    }

    function testRetireResetsFactor() public {
        // Ein Dieb des Schlüssels drückt den Faktor mit erfundenen Zahlen nach unten ...
        submit(SAT, 400_000, 240_000);
        submit(SAT + 1 weeks, 400_000, 240_000);
        submit(SAT + 2 weeks, 400_000, 240_000);
        assertEq(em.factorMilli(), 850);
        // ... das Abschalten schreibt das aber nicht fest, sondern setzt auf 1,0 zurück.
        oracle.retire(sig(KEY, oracle.retireDigest()));
        assertEq(em.factorMilli(), 1000);
        assertEq(em.targetMilli(), 1000);
    }

    function testRetireSettlesOldEpochsWithOldFactor() public {
        submit(SAT, 400_000, 240_000);                   // Faktor 0,95
        vm.warp(START + 2 weeks);
        oracle.retire(sig(KEY, oracle.retireDigest()));
        assertEq(em.pending(), 2 * (em.BASE_EMISSION() * 950 / 1000));
    }

    function testRetireOnlyOnce() public {
        bytes memory s = sig(KEY, oracle.retireDigest());
        oracle.retire(s);
        vm.expectRevert(SignedMortalityOracle.IsRetired.selector);
        oracle.retire(s);
    }

    function testResetFactorOnlyOracle() public {
        vm.expectRevert(MortalityEmission.OnlyOracle.selector);
        em.resetFactor();
    }

    function testRetireNeedsKey() public {
        bytes memory s = sig(OTHER_KEY, oracle.retireDigest());
        vm.expectRevert(SignedMortalityOracle.BadSignature.selector);
        oracle.retire(s);
    }

    function testBindOnlyOnceAndOnlyDeployer() public {
        vm.expectRevert(SignedMortalityOracle.AlreadyBound.selector);
        oracle.bind(address(1));
        SignedMortalityOracle o = new SignedMortalityOracle(vm.addr(KEY));
        vm.prank(address(0x1234));
        vm.expectRevert(SignedMortalityOracle.AlreadyBound.selector);
        o.bind(address(1));
    }

    function testUnboundRejects() public {
        SignedMortalityOracle o = new SignedMortalityOracle(vm.addr(KEY));
        bytes memory s = sig(KEY, o.reportDigest(SAT, 252_000, 240_000));
        vm.expectRevert(SignedMortalityOracle.NotBound.selector);
        o.submit(SAT, 252_000, 240_000, s);
    }

    function testZeroSignerRejected() public {
        vm.expectRevert(SignedMortalityOracle.BadSignature.selector);
        new SignedMortalityOracle(address(0));
    }
}
