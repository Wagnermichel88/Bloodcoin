// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

interface IMortalityEmission {
    function report(uint256 weekEnding, uint256 recentDeaths, uint256 baselineDeaths) external;
    function resetFactor() external;
}

/// @title CDC-Sterbezahlen, signiert vom eigenen Server (Plan B zu Chainlink CRE)
/// @notice Der Server holt jeden Montag die CDC-Zahlen, signiert sie mit einem festen Schlüssel
///         (EIP-712) und reicht sie ein. Einreichen darf jeder, angenommen wird nur, was `signer`
///         signiert hat. Die Signatur gilt nur für diesen Contract auf dieser Chain.
///
///         Gemeldet werden die Toten der letzten 4 Wochen und der Durchschnitt derselben 4 Wochen
///         in den 3 Vorjahren (siehe MortalityEmission).
///
///         Das ist ein vertrauter Melder: Wer den Schlüssel hat, kann falsche Zahlen melden. Die
///         Prüfungen hier fangen grobe Fehler ab, keine geschickte Manipulation. Begrenzt wird der
///         Schaden dadurch, dass MortalityEmission den Faktor pro Meldung nur um 0,05 bewegt;
///         verhindern lässt er sich nur, indem jede Meldung öffentlich mit den CDC-Rohdaten
///         vergleichbar ist.
///
///         Kein Besitzer. `signer` ist unveränderlich. Bei Schlüsselverlust oder -diebstahl wird
///         der Melder mit `retire` endgültig abgeschaltet; dabei geht der Faktor auf 1,0 zurück, und
///         die Emission läuft ohne Sterbe-Anpassung weiter. So kann ein Dieb einen verschobenen
///         Faktor nicht durch Abschalten festschreiben.
contract SignedMortalityOracle is EIP712 {
    bytes32 public constant REPORT_TYPEHASH =
        keccak256("MortalityReport(uint256 weekEnding,uint256 recentDeaths,uint256 baselineDeaths)");
    bytes32 public constant RETIRE_TYPEHASH = keccak256("Retire()");

    /// Summe über 4 Wochen. US-Wochenwerte lagen seit 2015 zwischen etwa 50.000 und 90.000,
    /// 4 Wochen also zwischen 200.000 und 360.000.
    uint256 public constant MIN_DEATHS = 80_000;
    uint256 public constant MAX_DEATHS = 1_000_000;

    address public immutable signer;
    address private immutable deployer;

    IMortalityEmission public emission;
    bool public retired;

    event Reported(uint256 indexed weekEnding, uint256 recentDeaths, uint256 baselineDeaths);
    event Retired();

    error AlreadyBound();
    error NotBound();
    error IsRetired();
    error BadSignature();
    error OutOfRange();

    constructor(address signer_) EIP712("Bloodcoin Mortality Oracle", "1") {
        if (signer_ == address(0)) revert BadSignature();
        signer = signer_;
        deployer = msg.sender;
    }

    function bind(address emission_) external {
        if (msg.sender != deployer || address(emission) != address(0)) revert AlreadyBound();
        emission = IMortalityEmission(emission_);
    }

    /// @notice Hash, den der Server signiert. Gleich dem EIP-712-Hash von MortalityReport.
    function reportDigest(uint256 weekEnding, uint256 recentDeaths, uint256 baselineDeaths)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(REPORT_TYPEHASH, weekEnding, recentDeaths, baselineDeaths)));
    }

    function retireDigest() public view returns (bytes32) {
        return _hashTypedDataV4(RETIRE_TYPEHASH);
    }

    /// @notice Reicht eine signierte Meldung ein. Wochen- und Altersprüfung macht MortalityEmission;
    ///         eine schon gemeldete Woche wird dort abgelehnt, deshalb lässt sich nichts wiederholen.
    function submit(uint256 weekEnding, uint256 recentDeaths, uint256 baselineDeaths, bytes calldata signature)
        external
    {
        if (retired) revert IsRetired();
        if (address(emission) == address(0)) revert NotBound();
        if (ECDSA.recover(reportDigest(weekEnding, recentDeaths, baselineDeaths), signature) != signer) {
            revert BadSignature();
        }
        if (
            recentDeaths < MIN_DEATHS || recentDeaths > MAX_DEATHS || baselineDeaths < MIN_DEATHS
                || baselineDeaths > MAX_DEATHS
        ) revert OutOfRange();

        emission.report(weekEnding, recentDeaths, baselineDeaths);
        emit Reported(weekEnding, recentDeaths, baselineDeaths);
    }

    /// @notice Schaltet den Melder endgültig ab und setzt den Faktor auf 1,0 zurück. Braucht eine
    ///         Signatur des Schlüssels.
    function retire(bytes calldata signature) external {
        if (retired) revert IsRetired();
        if (ECDSA.recover(retireDigest(), signature) != signer) revert BadSignature();
        retired = true;
        if (address(emission) != address(0)) emission.resetFactor();
        emit Retired();
    }
}
