// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BloodcoinToken} from "./BloodcoinToken.sol";

/// @title Sterbe-Index-Emission für BCUS
/// @notice Gibt pro Woche (Epoche) neue BCUS aus: die Hälfte an das Mining (`miner`), die andere
///         Hälfte an das Staking (`recipient`). Ohne Mining-Contract (`miner` = 0) geht alles an
///         `recipient`. Die Menge folgt einem
///         Halbierungsplan wie bei Bitcoin und wird mit dem Sterbe-Faktor multipliziert.
///
///         Sterbe-Faktor: Verglichen werden die US-Todesfälle der letzten 4 CDC-Wochen mit dem
///         Durchschnitt derselben 4 Wochen in den 3 Vorjahren (Übersterblichkeit). Liegt die
///         Abweichung innerhalb von 3 %, bleibt das Ziel bei 1,0 (normales Rauschen und
///         Alterungstrend). Darüber kostet jedes weitere Prozent Übersterblichkeit 5 % der neuen
///         Coins, jedes Prozent Untersterblichkeit bringt 5 % mehr, begrenzt auf 0,5 bis 1,5.
///         Der tatsächliche Faktor läuft pro Meldung höchstens 0,05 auf dieses Ziel zu. Eine
///         einzelne (auch falsche) Meldung verschiebt die Ausgabe also um höchstens 5 %.
///         Die Rechnung steht gleich in oracle/cre-workflow/cdc.js und oracle/signed/report.py.
///
///         Jede Epoche bekommt den Faktor, der an ihrem Ende galt: Eine neue Meldung rechnet
///         vor dem Umstellen erst alle bereits abgelaufenen Epochen mit dem alten Faktor ab.
///         Wann jemand `mint()` aufruft, ändert die Menge deshalb nicht.
///
///         Wird das Orakel abgeschaltet, setzt es den Faktor einmalig auf 1,0 zurück
///         (`resetFactor`). Sonst könnte ein Dieb des Orakel-Schlüssels den Faktor über zehn
///         Meldungen an den Rand treiben und ihn dann mit dem Abschalten dort festschreiben.
///
///         Alle Parameter sind unveränderlich. Es gibt keinen Besitzer.
contract MortalityEmission {
    uint256 public constant EPOCH = 1 weeks;
    /// Erste Halbierungsperiode: 10,5 Mio. BCUS über 416 Wochen (rund 8 Jahre).
    uint256 public constant HALVING_EPOCHS = 416;
    uint256 public constant BASE_EMISSION = 10_500_000e18 / HALVING_EPOCHS;

    uint256 public constant LAG = 8 weeks;          // CDC-Zahlen sind vorher unvollständig
    uint256 public constant DEAD_ZONE_BP = 300;     // ±3 % Abweichung zählen nicht
    uint256 public constant SENSITIVITY = 5;        // jedes Prozent darüber -> 5 % weniger neue Coins
    uint256 public constant MAX_STEP = 50;          // Promille pro Meldung
    uint256 public constant FACTOR_MIN = 500;       // Promille
    uint256 public constant FACTOR_MAX = 1500;
    uint256 public constant MAX_DEATHS = 10_000_000;
    uint256 public constant MINING_SHARE_BP = 5000; // 50 % jeder Ausgabe an das Mining

    BloodcoinToken public immutable token;
    address public immutable oracle;
    address public immutable recipient;
    address public immutable miner;
    uint256 public immutable start;

    uint256 public settledEpochs;       // so viele Epochen sind abgerechnet
    uint256 public pending;             // abgerechnet, aber noch nicht ausgegeben
    uint256 public factorMilli = 1000;
    uint256 public targetMilli = 1000;  // Ziel aus der letzten Meldung, factorMilli läuft darauf zu
    uint256 public lastWeekEnding;      // Unix-Zeit (00:00 UTC, Samstag) der letzten Meldung

    event MortalityReported(
        uint256 indexed weekEnding, uint256 recentDeaths, uint256 baselineDeaths, uint256 targetMilli, uint256 factorMilli
    );
    event Minted(address indexed to, uint256 amount, uint256 settledEpochs);
    event FactorReset();

    error OnlyOracle();
    error WeekNotNewer();
    error WeekTooRecent();
    error NotASaturday();
    error BadDeaths();

    constructor(address oracle_, address recipient_, address miner_, address initialHolder, uint256 initialMint) {
        oracle = oracle_;
        recipient = recipient_;
        miner = miner_;
        start = block.timestamp;
        token = new BloodcoinToken(address(this), initialHolder, initialMint);
    }

    // ------------------------------------------------------------------ Sterbe-Faktor

    /// @notice Ziel-Faktor in Promille (1000 = unverändert).
    /// @param recentDeaths Todesfälle der 4 Wochen bis einschließlich der gemeldeten Woche
    /// @param baselineDeaths Durchschnitt derselben 4 Wochen in den 3 Vorjahren
    function targetFor(uint256 recentDeaths, uint256 baselineDeaths) public pure returns (uint256) {
        bool more = recentDeaths > baselineDeaths;
        uint256 diff = more ? recentDeaths - baselineDeaths : baselineDeaths - recentDeaths;
        uint256 bp = (diff * 10_000 + baselineDeaths / 2) / baselineDeaths;
        if (bp <= DEAD_ZONE_BP) return 1000;
        uint256 adj = SENSITIVITY * (bp - DEAD_ZONE_BP) / 10;
        if (more) return adj >= 1000 - FACTOR_MIN ? FACTOR_MIN : 1000 - adj;
        return adj >= FACTOR_MAX - 1000 ? FACTOR_MAX : 1000 + adj;
    }

    /// @notice Neuer Faktor: höchstens MAX_STEP vom alten in Richtung Ziel.
    function stepToward(uint256 current, uint256 target) public pure returns (uint256) {
        if (target > current) return target - current > MAX_STEP ? current + MAX_STEP : target;
        return current - target > MAX_STEP ? current - MAX_STEP : target;
    }

    /// @notice Neue CDC-Woche. Nur der Oracle-Contract darf melden.
    function report(uint256 weekEnding, uint256 recentDeaths, uint256 baselineDeaths) external {
        if (msg.sender != oracle) revert OnlyOracle();
        if (weekEnding <= lastWeekEnding) revert WeekNotNewer();
        if (weekEnding + LAG > block.timestamp) revert WeekTooRecent();
        // 1970-01-01 war ein Donnerstag, Samstag ist also Tag 2 modulo 7.
        if (weekEnding % 1 days != 0 || (weekEnding / 1 days) % 7 != 2) revert NotASaturday();
        if (recentDeaths == 0 || baselineDeaths == 0 || recentDeaths >= MAX_DEATHS || baselineDeaths >= MAX_DEATHS) {
            revert BadDeaths();
        }
        // Mehr als doppelt oder weniger als halb so viele Tote wie üblich gab es selbst 2020/21 nicht;
        // so etwas ist ein Formatfehler (z. B. eine Woche statt vier gemeldet).
        if (recentDeaths > 2 * baselineDeaths || 2 * recentDeaths < baselineDeaths) revert BadDeaths();

        _settle();
        lastWeekEnding = weekEnding;
        uint256 target = targetFor(recentDeaths, baselineDeaths);
        targetMilli = target;
        factorMilli = stepToward(factorMilli, target);
        emit MortalityReported(weekEnding, recentDeaths, baselineDeaths, target, factorMilli);
    }

    /// @notice Faktor und Ziel zurück auf 1,0. Nur das Orakel; der signierte Melder ruft das
    ///         beim Abschalten auf. Bereits abgelaufene Epochen werden vorher mit dem alten Faktor
    ///         abgerechnet.
    function resetFactor() external {
        if (msg.sender != oracle) revert OnlyOracle();
        _settle();
        factorMilli = 1000;
        targetMilli = 1000;
        emit FactorReset();
    }

    // ------------------------------------------------------------------ Ausgabe

    function epochEmission(uint256 epoch) public pure returns (uint256) {
        uint256 halvings = epoch / HALVING_EPOCHS;
        return halvings >= 64 ? 0 : BASE_EMISSION >> halvings;
    }

    function completedEpochs() public view returns (uint256) {
        return (block.timestamp - start) / EPOCH;
    }

    /// @notice Gibt alles Fällige aus, geteilt zwischen `miner` und `recipient`. Darf jeder aufrufen.
    function mint() external returns (uint256 amount) {
        _settle();
        amount = pending;
        uint256 room = token.cap() - token.totalSupply();
        if (amount > room) amount = room;
        pending = 0;
        if (amount == 0) return 0;
        uint256 toMiner = miner == address(0) ? 0 : amount * MINING_SHARE_BP / 10_000;
        if (toMiner > 0) {
            token.mint(miner, toMiner);
            emit Minted(miner, toMiner, settledEpochs);
        }
        token.mint(recipient, amount - toMiner);
        emit Minted(recipient, amount - toMiner, settledEpochs);
    }

    function _settle() internal {
        uint256 done = completedEpochs();
        uint256 e = settledEpochs;
        if (e >= done) return;
        uint256 f = factorMilli;
        uint256 sum;
        for (; e < done; ++e) {
            uint256 base = epochEmission(e);
            if (base == 0) {
                e = done;
                break;
            }
            sum += base * f / 1000;
        }
        settledEpochs = done;
        pending += sum;
    }
}
