# Bloodcoin (BCUS)

An ERC-20 token on Base whose weekly emission follows US mortality data from the CDC.
This repository holds the contracts, the oracle that reports the data, and the public page
that lets anyone check every report.

> **Status:** in development, testnet only. Not audited. BCUS is not for sale and this is not
> an investment offer. The code here is newer than the current Base Sepolia deployment and will
> be redeployed before any further step.

Detailed documentation is in German: [README.de.md](README.de.md) (contracts, deployment) and
[FAKTOR.md](FAKTOR.md) (why the emission rule looks the way it does, with a simulation over 2015–2024).

## How it works

| Contract | Role |
|---|---|
| `BloodcoinToken` | ERC-20 "Bloodcoin" (BCUS), 18 decimals, hard cap 21 million. No owner, no pause, no blacklist. Only the emission contract can mint. |
| `MortalityEmission` | Mints a fixed weekly amount on a Bitcoin-like halving schedule (every 416 weeks, about 8 years), multiplied by a mortality factor between 0.5 and 1.5. No owner, all parameters immutable. |
| `BcusStaking` | Receives half of all new BCUS and streams them to stakers pro rata over 7 days. What streams while nobody stakes is burned, not saved for the first staker. |
| `BcusMining` | Receives the other half. Anyone can mine BCUS with proof of work (keccak256, like Bitcoin): find a nonce, call `mine(nonce)`. The reward follows the time since the last solution (that share of a week, capped at 40 minutes), not hashing speed, so fast solutions earn almost nothing and a long pause leaves no pot to grab. Difficulty adjusts itself towards one solution every 10 minutes. No owner. A simple CPU miner is in `miner/mine.py`. |
| `SignedMortalityOracle` | Accepts mortality reports signed by one fixed key (EIP-712). |
| `CreMortalityOracle` | Alternative: accepts reports from a Chainlink CRE workflow (`oracle/cre-workflow`). |

**The factor:** deaths in the 4 weeks up to the report week are compared with the same 4 weeks
in each of the previous 3 years. Within ±3 % the target is 1.0; each further percent of excess
deaths lowers it by 0.05 (fewer deaths raise it), limited to 0.5–1.5. The factor in use moves at
most 0.05 per weekly report. Only weeks at least 8 weeks old are used.

## Trust model, stated plainly

With `SignedMortalityOracle`, the project founder runs the oracle and also holds BCUS. That is a
conflict of interest: whoever holds the signing key can report plausible but false numbers, and
the contract only rejects absurd values. The safeguards are:

- Every report is published with the exact CDC weeks it used, the full CDC answer and the
  signature (`oracle/signed/report.py` writes them; `web/oracle.html` displays them).
- Anyone can check a report against the CDC, either with the button on the public page (it
  queries data.cdc.gov from the visitor's browser) or with `python3 oracle/signed/report.py verify <report>.json`.
- The signing key is immutable and cannot be swapped silently. `retire()` can only switch the
  oracle off for good. It resets the factor to 1.0, so a stolen key cannot push the factor to an
  extreme and then lock it there.
- The founder's initial BCUS do not go to the founder's address. `script/DeploySigned.s.sol` mints
  them into `src/FounderLock.sol` (OpenZeppelin `VestingWallet`): they vest linearly over 10 years
  from deployment, 100,000 BCUS per year for an initial mint of 1M, to one fixed address. No
  admin, no cliff that the market has to fear, and neither the schedule nor the recipient can be
  changed.

## Build and test

```bash
git clone --recursive <this repo>
forge test            # Foundry, solc 0.8.28
```

Data source: CDC dataset [r8kw-7aab](https://data.cdc.gov/d/r8kw-7aab), total deaths, United States.

## License

MIT, see [LICENSE](LICENSE).
