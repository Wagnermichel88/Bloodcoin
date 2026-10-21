// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";

/// Sperrvertrag für die Gründer-BCUS: die Startmenge wird ab Deploy über 10 Jahre linear frei,
/// bei 1 Mio. BCUS also 100.000 pro Jahr, sekundengenau. Kein grosser Block an einem Stichtag,
/// vor dem der Markt sich fürchten muss. OpenZeppelin-VestingWallet, dazu:
/// - Beginn und Dauer werden im Constructor festgelegt und sind unveränderlich (kein Admin).
/// - Empfänger ist fest: transferOwnership und renounceOwnership sind abgeschaltet. Sonst könnte der
///   Empfänger die gesperrten Coins vorab verkaufen oder sie durch renounce für immer verlieren.
/// Auslösen darf jeder (release), die Coins gehen immer an den Empfänger.
contract FounderLock is VestingWallet {
    uint64 public constant VESTING_DURATION = 3650 days;

    error BeneficiaryFixed();

    constructor(address beneficiary) VestingWallet(beneficiary, uint64(block.timestamp), VESTING_DURATION) {}

    function transferOwnership(address) public pure override {
        revert BeneficiaryFixed();
    }

    function renounceOwnership() public pure override {
        revert BeneficiaryFixed();
    }
}
