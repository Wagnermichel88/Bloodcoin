// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "./Test.sol";
import {BloodcoinToken} from "../src/BloodcoinToken.sol";
import {MortalityEmission} from "../src/MortalityEmission.sol";
import {BcusStaking} from "../src/BcusStaking.sol";
import {FounderLock} from "../src/FounderLock.sol";

/// Aufbau wie DeploySigned: alle Start-BCUS im FounderLock, niemand sonst hat BCUS.
/// Früher sammelte das Staking die Emission für den ersten Staker, und das war zwangsläufig der
/// Gründer. Jetzt wird verbrannt, was ohne Staker fließt. Der Gründer steigt hier nach zwei Jahren
/// mit dem ein, was bis dahin frei ist (200.000 BCUS), und bekommt trotzdem keinen Topf.
contract FounderScenarioTest is Test {
    uint256 constant START = 1_800_000_000;
    address constant FOUNDER = address(0xF00D);

    BcusStaking st;
    MortalityEmission em;
    BloodcoinToken token;
    FounderLock lock;
    uint256 base;

    function setUp() public {
        vm.warp(START);
        st = new BcusStaking();
        lock = new FounderLock(FOUNDER);
        em = new MortalityEmission(address(0x0A), address(st), address(0), address(lock), 1_000_000e18);
        st.bind(address(em));
        token = em.token();
        base = em.BASE_EMISSION();
    }

    function testFounderGetsNoWindfallAfterLock() public {
        // 730 Tage niemand stakt: wöchentlich ruft jemand pull() auf (oder auch nicht, das ist egal).
        for (uint256 i = 1; i <= 104; i++) {
            vm.warp(START + i * 1 weeks);
            st.pull();
        }
        vm.warp(START + 730 days);
        lock.release(address(token));
        uint256 own = 200_000e18;                        // 2 von 10 Jahren frei
        assertEq(token.balanceOf(FOUNDER), own);

        vm.startPrank(FOUNDER);
        token.approve(address(st), type(uint256).max);
        st.stake(own);
        vm.stopPrank();

        // Fast alles aus den zwei Jahren ist verbrannt; offen ist höchstens der laufende Wochenstrom.
        assertLe(104 * base - 2 * base, st.burned());

        vm.warp(START + 730 days + 1 weeks);
        st.pull();                                       // hier startete früher der Topf-Strom
        vm.warp(START + 730 days + 3 weeks);
        vm.prank(FOUNDER);
        st.exit();
        // Er bekommt nur, was ab seinem Einstieg fließt: rund 3 Wochen, nicht 106.
        assertLe(token.balanceOf(FOUNDER), own + 4 * base);
        assertLe(st.totalStaked() + st.reserved(), token.balanceOf(address(st)));
    }
}
