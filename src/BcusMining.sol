// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IMiningEmission {
    function token() external view returns (IERC20);
    function miner() external view returns (address);
    function mint() external returns (uint256);
}

/// @title BCUS-Mining (Proof of Work auf Base)
/// @notice Jeder kann BCUS schürfen, ohne vorher BCUS zu besitzen und ohne den Gründer. Wie bei
///         Bitcoin sucht ein Miner eine Zahl (`nonce`), sodass
///         keccak256(challenge, Miner-Adresse, nonce) unter dem aktuellen Ziel (`target`) liegt.
///         Die Miner-Adresse steckt im Hash, deshalb kann niemand eine fremde Lösung aus der
///         Warteschlange kopieren und für sich einreichen.
///
///         Belohnung nach Zeit, nicht nach Tempo: Eine Lösung bekommt den Anteil des Vorrats, der
///         der Zeit seit der letzten Lösung entspricht (Zeit / 1 Woche), höchstens 40 Minuten. Bei
///         einer Lösung alle 10 Minuten ist das 1/1008 pro Lösung, über die Woche also ungefähr die
///         Wochenausgabe. Wer mit viel Rechenleistung in Sekundenabständen Lösungen findet, etwa
///         beim Start, solange die Schwierigkeit noch niedrig ist, bekommt fast nichts dafür. Und
///         wer nach einer langen Pause als Erster schürft, bekommt höchstens 40/10080 des Vorrats.
///         Es gibt keinen Topf, den einer auf einmal abräumt.
///
///         Schwierigkeit: alle 144 Lösungen (rund ein Tag) wird das Ziel so angepasst, dass im
///         Schnitt alle 10 Minuten eine Lösung kommt, höchstens Faktor 4 pro Anpassung. Kommen
///         vier Tage lang zu wenige Lösungen, wird schon vorher leichter gemacht, damit das Mining
///         nicht stehen bleibt, wenn Miner verschwinden.
///
///         Kein Besitzer, keine Parameter zum Ändern. `bind` kann nur der Deployer genau einmal
///         aufrufen.
contract BcusMining is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BLOCK_TIME = 10 minutes;
    uint256 public constant ADJUST_INTERVAL = 144;
    uint256 public constant MAX_REWARD_TIME = 40 minutes;
    /// Leichtestes Ziel: rund 65.000 Versuche pro Lösung, also auch für einen Laptop.
    uint256 public constant MAX_TARGET = 2 ** 240;
    uint256 public constant MIN_TARGET = 2 ** 16;

    address private immutable deployer;
    IMiningEmission public emission;
    IERC20 public token;

    bytes32 public challenge;
    uint256 public target = MAX_TARGET;
    uint256 public periodStart;             // Zeit der letzten Anpassung
    uint256 public periodSolutions;         // Lösungen seit der letzten Anpassung
    uint256 public lastMined;               // Zeit der letzten Lösung (zu Beginn: bind)
    uint256 public totalSolutions;
    uint256 public totalMined;

    event Bound(address emission, address token);
    event Mined(address indexed miner, uint256 reward, uint256 nonce, bytes32 newChallenge);
    event Retarget(uint256 oldTarget, uint256 newTarget, uint256 solutions, uint256 elapsed);

    error AlreadyBound();
    error NotBound();
    error WrongMiner();
    error BadSolution();
    error NothingToMine();

    constructor() {
        deployer = msg.sender;
    }

    function bind(address emission_) external {
        if (msg.sender != deployer || address(emission) != address(0)) revert AlreadyBound();
        if (IMiningEmission(emission_).miner() != address(this)) revert WrongMiner();
        emission = IMiningEmission(emission_);
        token = IMiningEmission(emission_).token();
        challenge = keccak256(abi.encode(block.chainid, address(this), blockhash(block.number - 1)));
        periodStart = block.timestamp;
        lastMined = block.timestamp;
        emit Bound(emission_, address(token));
    }

    // ------------------------------------------------------------------ Ansichten

    /// @notice Ziel, gegen das die nächste Lösung geprüft wird (mit einer fälligen Anpassung).
    function currentTarget() public view returns (uint256) {
        (uint256 t,) = _retarget();
        return t;
    }

    /// @notice Hash einer Lösung. Gültig, wenn uint256(hash) <= currentTarget().
    function solutionHash(address miner, uint256 nonce) public view returns (bytes32) {
        return keccak256(abi.encodePacked(challenge, miner, nonce));
    }

    /// @notice Belohnung, wenn jetzt eine Lösung käme (ohne noch nicht abgeholte Ausgabe).
    function nextReward() public view returns (uint256) {
        if (address(token) == address(0)) return 0;
        uint256 dt = block.timestamp - lastMined;
        if (dt > MAX_REWARD_TIME) dt = MAX_REWARD_TIME;
        return token.balanceOf(address(this)) * dt / 1 weeks;
    }

    // ------------------------------------------------------------------ Schürfen

    /// @notice Reicht eine Lösung ein. Die Belohnung geht an msg.sender, der auch im Hash steckt.
    function mine(uint256 nonce) external nonReentrant returns (uint256 reward) {
        if (address(emission) == address(0)) revert NotBound();
        (uint256 t, bool adjust) = _retarget();
        if (adjust) {
            emit Retarget(target, t, periodSolutions, block.timestamp - periodStart);
            target = t;
            periodStart = block.timestamp;
            periodSolutions = 0;
        }
        if (uint256(solutionHash(msg.sender, nonce)) > t) revert BadSolution();

        emission.mint();
        reward = nextReward();
        if (reward == 0) revert NothingToMine();       // auch: zweite Lösung im selben Block

        // Neue Aufgabe: hängt an der alten und am letzten Base-Block, ist also nicht vorab berechenbar.
        challenge = keccak256(abi.encode(challenge, nonce, blockhash(block.number - 1)));
        periodSolutions += 1;
        totalSolutions += 1;
        lastMined = block.timestamp;
        totalMined += reward;
        token.safeTransfer(msg.sender, reward);
        emit Mined(msg.sender, reward, nonce, challenge);
    }

    // ------------------------------------------------------------------ intern

    /// Neues Ziel und ob jetzt angepasst wird: nach ADJUST_INTERVAL Lösungen, oder wenn seit der
    /// letzten Anpassung viermal so viel Zeit vergangen ist wie geplant.
    function _retarget() internal view returns (uint256 t, bool adjust) {
        t = target;
        uint256 elapsed = block.timestamp - periodStart;
        uint256 planned = ADJUST_INTERVAL * BLOCK_TIME;
        if (periodSolutions < ADJUST_INTERVAL && elapsed < 4 * planned) return (t, false);
        adjust = true;
        uint256 expected = periodSolutions * BLOCK_TIME;
        uint256 next;
        if (expected == 0 || elapsed >= 4 * expected) {
            next = t * 4;                                    // höchstens 4x leichter
        } else {
            next = t / expected * elapsed;                   // < 4t, kein Überlauf (t <= 2^240)
        }
        if (next < t / 4) next = t / 4;
        if (next > MAX_TARGET) next = MAX_TARGET;
        if (next < MIN_TARGET) next = MIN_TARGET;
        t = next;
    }
}
