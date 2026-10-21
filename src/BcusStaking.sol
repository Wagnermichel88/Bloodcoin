// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IEmission {
    function token() external view returns (IERC20);
    function recipient() external view returns (address);
    function mint() external returns (uint256);
}

/// @title BCUS-Staking
/// @notice Wer BCUS hier sperrt, bekommt die wöchentlich neu ausgegebenen BCUS anteilig.
///         Neue Coins werden nicht auf einen Schlag verteilt, sondern gleichmäßig über die
///         folgenden 7 Tage ausgezahlt (Verfahren von Synthetix StakingRewards). Wer nur kurz
///         vor einer Ausgabe einsteigt, bekommt deshalb nur seinen zeitlichen Anteil.
///
///         Läuft der Strom, während niemand gestakt hat, wird dieser Teil verbrannt (an BURN
///         geschickt) und nicht aufgehoben. Sonst sammelt sich alles, was ausgegeben wird, solange
///         noch niemand BCUS hat, in einem Topf, und der erste Staker bekäme ihn ganz. Beim Deploy
///         liegen alle Start-BCUS im FounderLock und sonst hat niemand BCUS, dieser erste Staker
///         wäre also der Gründer gewesen.
///
///         Einzahlen, Abheben und Abholen geht jederzeit und ohne Sperrfrist. Es gibt keinen
///         Besitzer. `bind` kann nur der Deployer genau einmal aufrufen.
contract BcusStaking is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant DURATION = 7 days;
    /// Übliche Verbrennungsadresse; zu ihr gibt es keinen Schlüssel.
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;

    address private immutable deployer;
    IEmission public emission;
    IERC20 public token;

    uint256 public totalStaked;
    mapping(address => uint256) public stakedOf;

    uint256 public rewardRate;              // BCUS pro Sekunde (18 Dezimalen)
    uint256 public periodFinish;
    uint256 public lastUpdate;
    uint256 public rewardPerTokenStored;
    uint256 public undistributed;           // Rundungsrest, fließt in die nächste Ausgabe
    uint256 public burned;                  // Summe, die ohne Staker verbrannt wurde
    uint256 private toBurn;                 // in _accrue gesammelt, in _sync verbrannt
    uint256 public reserved;                // alle BCUS im Contract, die Belohnung sind (nicht Einsatz)
    mapping(address => uint256) public paidPerToken;
    mapping(address => uint256) public rewards;

    event Bound(address emission, address token);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);
    event RewardAdded(uint256 amount, uint256 rewardRate, uint256 periodFinish);
    event Burned(uint256 amount);

    error AlreadyBound();
    error NotBound();
    error WrongRecipient();
    error ZeroAmount();
    error InsufficientStake();

    constructor() {
        deployer = msg.sender;
    }

    function bind(address emission_) external {
        if (msg.sender != deployer || address(emission) != address(0)) revert AlreadyBound();
        if (IEmission(emission_).recipient() != address(this)) revert WrongRecipient();
        emission = IEmission(emission_);
        token = IEmission(emission_).token();
        emit Bound(emission_, address(token));
    }

    // ------------------------------------------------------------------ Ansichten

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + (lastTimeRewardApplicable() - lastUpdate) * rewardRate * 1e18 / totalStaked;
    }

    /// @notice Bereits verdiente, noch nicht abgeholte Belohnung (ohne noch nicht abgeholte Ausgabe).
    function earned(address user) public view returns (uint256) {
        return stakedOf[user] * (rewardPerToken() - paidPerToken[user]) / 1e18 + rewards[user];
    }

    // ------------------------------------------------------------------ Aktionen

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _sync(msg.sender);
        totalStaked += amount;
        stakedOf[msg.sender] += amount;
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > stakedOf[msg.sender]) revert InsufficientStake();
        _sync(msg.sender);
        totalStaked -= amount;
        stakedOf[msg.sender] -= amount;
        token.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function claim() public nonReentrant {
        _sync(msg.sender);
        uint256 r = rewards[msg.sender];
        if (r > 0) {
            rewards[msg.sender] = 0;
            reserved -= r;
            token.safeTransfer(msg.sender, r);
            emit RewardPaid(msg.sender, r);
        }
    }

    function exit() external {
        if (stakedOf[msg.sender] > 0) withdraw(stakedOf[msg.sender]);
        claim();
    }

    /// @notice Holt fällige neue BCUS beim Emissions-Contract ab und startet ihre Auszahlung über
    ///         7 Tage. Darf jeder aufrufen; passiert auch bei jedem Stake, Abheben und Abholen.
    ///         Was ohne Staker geflossen ist, wird dabei verbrannt.
    function pull() external nonReentrant {
        _sync(address(0));
    }

    // ------------------------------------------------------------------ intern

    function _sync(address user) internal {
        if (address(emission) == address(0)) revert NotBound();
        _accrue(user);
        uint256 b = toBurn;
        if (b > 0) {
            toBurn = 0;
            reserved -= b;
            burned += b;
            token.safeTransfer(BURN, b);
            emit Burned(b);
        }
        emission.mint();
        // Was neu angekommen ist, egal wer mint() aufgerufen hat (auch direkt am Emissions-Contract).
        uint256 fresh = token.balanceOf(address(this)) - totalStaked - reserved;
        if (fresh > 0) {
            reserved += fresh;
            _notify(fresh);
        }
    }

    function _accrue(address user) internal {
        uint256 applicable = lastTimeRewardApplicable();
        if (totalStaked == 0) {
            // Ohne Staker gehört der Strom niemandem; er wird verbrannt statt für den ersten Staker
            // aufgehoben.
            if (applicable > lastUpdate) toBurn += (applicable - lastUpdate) * rewardRate;
        } else {
            rewardPerTokenStored = rewardPerToken();
        }
        lastUpdate = applicable;
        if (user != address(0)) {
            rewards[user] = earned(user);
            paidPerToken[user] = rewardPerTokenStored;
        }
    }

    function _notify(uint256 amount) internal {
        uint256 add = amount + undistributed;
        undistributed = 0;
        if (block.timestamp < periodFinish) add += (periodFinish - block.timestamp) * rewardRate;
        rewardRate = add / DURATION;
        // Rundungsrest bleibt für die nächste Runde erhalten.
        undistributed += add - rewardRate * DURATION;
        lastUpdate = block.timestamp;
        periodFinish = block.timestamp + DURATION;
        emit RewardAdded(amount, rewardRate, periodFinish);
    }
}
