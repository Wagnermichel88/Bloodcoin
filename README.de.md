# BCUS-Token auf Base (mit Sterbe-Logik)

Stand: 11.10.2026. Entwurf, **nicht auditiert, nicht deployt**. Vor echtem Geld: externes Audit.

## Was hier liegt

| Datei | Zweck |
|---|---|
| `src/BloodcoinToken.sol` | ERC-20 "Bloodcoin" (BCUS), 18 Nachkommastellen, harte Grenze 21 Mio. Kein Besitzer, keine Pause, keine Sperrliste. Nur der Emissions-Contract kann neue Coins erzeugen. |
| `src/MortalityEmission.sol` | Gibt jede Woche neue BCUS aus: Halbierungsplan × Sterbe-Faktor (Übersterblichkeit, siehe `FAKTOR.md`). Deployt den Token selbst. Kein Besitzer, alles unveränderlich. |
| `src/BcusStaking.sol` | Bekommt die Hälfte aller neuen BCUS. Wer BCUS hier sperrt, bekommt sie anteilig, gleichmäßig über 7 Tage ausgezahlt. Ein- und Aussteigen jederzeit, kein Besitzer. |
| `src/BcusMining.sol` | Bekommt die andere Hälfte. Jeder kann BCUS schürfen (Proof of Work wie bei Bitcoin, keccak256): Lösung finden, `mine(nonce)` aufrufen. Die Belohnung richtet sich nach der Zeit seit der letzten Lösung (Anteil Zeit/Woche am Vorrat, höchstens 40 Minuten), nicht nach dem Tempo: Wer mit viel Rechenleistung Sekunden-Lösungen findet, bekommt fast nichts, und nach einer Pause gibt es keinen Topf. Schwierigkeit passt sich selbst an (Ziel: alle 10 Minuten eine Lösung). Kein Besitzer. |
| `miner/mine.py` | Einfacher CPU-Miner (Python + `cast`). |
| `src/CreMortalityOracle.sol` | Nimmt die CDC-Zahlen von Chainlink CRE entgegen (`onReport`). Nur der Chainlink-Forwarder darf melden, nach `pinWorkflow` nur noch genau ein Workflow. |
| `oracle/cre-workflow/` | Der CRE-Workflow (TypeScript): jeden Montag fragen unabhängige Chainlink-Knoten data.cdc.gov ab, einigen sich und schreiben das Ergebnis ins Oracle. |
| `script/Deploy.s.sol` | Deployt alles in einem Rutsch und verbindet die Teile. |
| `src/FounderLock.sol` | Sperrvertrag für die Gründer-BCUS (OpenZeppelin-`VestingWallet`): über 10 Jahre ab Deploy linear frei, bei 1 Mio. also 100.000 BCUS pro Jahr, an den festen Empfänger. Kein Admin, Zeitplan und Empfänger unveränderlich. |
| `script/DeploySigned.s.sol` | Plan B: Oracle (signierter Melder), Staking, Mining, Sperrvertrag, Emission und Token in einem Durchlauf. Die Startmenge geht direkt in den Sperrvertrag. (`Deploy.s.sol`, die Chainlink-Variante, deployt kein Mining.) |
| `oracle/sim/` | Simulation der Faktor-Regel an echten US-Wochenzahlen 2015 bis 2024 (`python3 -I oracle/sim/simulate.py`). |
| `test/` | 79 Contract-Tests (22 Token/Emission/Oracle, 11 Staking, 16 Mining, 20 Plan-B-Melder, 9 Sperrvertrag, 1 Gründer-Szenario). Der Workflow hat eigene Tests in `oracle/cre-workflow/`. |

## Regeln, die im Code stehen

- **Ausgabe:** 25.240,38 BCUS pro Woche in den ersten 416 Wochen (rund 8 Jahre), danach jeweils
  halbiert. Bei Faktor 1,0 ergibt das zusammen 21 Mio.; zusammen mit der Startmenge wird die
  Grenze also vorher erreicht, dann endet die Ausgabe.
- **Sterbe-Faktor:** Tote der letzten 4 CDC-Wochen gegen den Durchschnitt derselben 4 Wochen in
  den 3 Vorjahren. Bis ±3 % Abweichung bleibt das Ziel 1,0; jedes Prozent darüber kostet 5 % der
  neuen Coins, bis hinunter auf 0,5. Weniger Tote als üblich bringen keine Extra-Coins (höchstens 1,0). Der Faktor läuft
  pro Meldung höchstens 0,05 auf das Ziel zu. Begründung und Simulation: `FAKTOR.md`. Gilt ab der
  Meldung bis zur nächsten. Jede Woche bekommt den Faktor, der an ihrem Ende galt; wann jemand
  abholt, ändert nichts an der Menge.
- **Meldungen** werden nur angenommen, wenn sie vom Oracle-Contract kommen (und dort nur vom Chainlink-Forwarder), die Woche an einem
  Samstag endet, mindestens 8 Wochen alt und neuer als die letzte ist und die Zahlen plausibel sind (die 4-Wochen-Summe höchstens doppelt
  oder halb so groß wie die der Vorjahre).
  Eine abgelehnte oder fehlerhafte Antwort ändert nichts.
- **Abfrage** macht der CRE-Workflow selbst, jeden Montag 12:00 UTC. **Abholung** (`mint`) darf jeder
  aufrufen. Neue Coins gehen immer an den Staking-Contract.
- **Staking:** Neue Coins werden nicht auf einen Schlag verteilt, sondern über die folgenden
  7 Tage gestreamt (bewährtes Verfahren von Synthetix). Wer kurz vor einer Ausgabe mit viel Geld
  einsteigt und gleich wieder raus geht, bekommt so gut wie nichts (Test
  `testFlashStakerGetsAlmostNothing`). Läuft der Strom, während niemand gestakt hat, wird er
  verbrannt (an `0x…dEaD`) und nicht aufgehoben. Früher sammelte sich dieser Teil für den ersten
  Staker an. Weil beim Deploy alle Start-BCUS im FounderLock liegen und sonst niemand BCUS
  hat, wäre das zwangsläufig der Gründer gewesen, mit Millionen BCUS
  (`test/FounderScenario.t.sol`).

## Entscheidungen, die ich als Standard gesetzt habe

- **Achtung Startmenge und Staking:** Wenn du deine Startmenge selbst stakst, während kaum jemand
  anderes stakt, bekommst du trotzdem fast die ganze Ausgabe. Das Staking verteilt fair nach
  Einsatz, es schützt nicht vor einem Großhalter. Ehrlicher Umgang: Startmenge in den
  Uniswap-Pool, nicht ins Staking, und das öffentlich sagen.
- **Startmenge** (`INITIAL_MINT_BCUS`) ist ein Deploy-Parameter. Vorschlag: 1.000.000 BCUS (knapp 5 %).
  Mit `DeploySigned.s.sol` (Plan B) geht sie direkt in `FounderLock` und wird über 10 Jahre
  linear frei (100.000 BCUS pro Jahr); nur `FOUNDER_BENEFICIARY` bekommt sie (`release(token)`,
  auslösen darf jeder). Für einen Uniswap-Pool steht jeweils nur der freie Teil zur Verfügung.
- **18 Nachkommastellen** statt 8 wie auf der eigenen Chain, weil das jede Wallet erwartet.

## Warum CRE statt Chainlink Functions

Chainlink hat Functions abgekündigt (laut Doku Testnetz-Ende 15.06.2026, Mainnet 30.06.2026).
Nachfolger ist die Chainlink Runtime Environment (CRE). Am Prinzip ändert sich nichts: Fremde
Chainlink-Knoten holen die Zahlen, nicht du. Token, Emission und Staking sind unverändert.

## Lokal testen

```bash
forge test                                  # Contracts (29 Tests)
cd oracle/cre-workflow && bun install && bun test && node test-cdc.mjs   # Workflow
bun x cre-compile main.ts dist/workflow.wasm   # baut den Workflow wie die CRE-CLI
```

Einzige Abhängigkeit: OpenZeppelin 5.6.1 als Git-Submodul in `lib/` (`git clone --recursive`).
Compiler: solc 0.8.28. Der Workflow nutzt `@chainlink/cre-sdk` 1.23.0 und braucht [Bun](https://bun.sh).

## Deployment auf das Base-Testnetz

Ablauf in zwei Stufen. Stufe 1 geht ohne Freischaltung bei Chainlink, Stufe 2 braucht sie.

**Stufe 1: Simulation mit echten Transaktionen.** Die CRE-CLI führt den Workflow auf dem eigenen
Rechner aus und schickt das Ergebnis über Chainlinks *Simulations-Forwarder* an die Chain.

1. CRE-CLI installieren (docs.chain.link/cre/getting-started/cli-installation), `cre login`
   (kostenloses Chainlink-Konto).
2. Contracts deployen, Forwarder = Simulations-Forwarder für Base Sepolia aus dem
   Forwarder-Verzeichnis der Chainlink-Doku (laut Doku `0x82300bd7c3958625581cc2f77bc6464dcecdf3e5`,
   vor dem Deployment dort nachsehen):
   ```bash
   export CRE_FORWARDER=0x...
   export INITIAL_HOLDER=0x...
   export INITIAL_MINT_BCUS=1000000
   forge script script/Deploy.s.sol --rpc-url https://base-sepolia-rpc.publicnode.com --broadcast --account deployer
   ```
3. `cre init` (TypeScript), die Dateien aus `oracle/cre-workflow/` in den Workflow-Ordner kopieren,
   in `config.staging.json` die Oracle-Adresse eintragen.
4. `cre workflow simulate --target staging-settings --broadcast` (mit `CRE_ETH_PRIVATE_KEY` in `.env`).
   Danach muss `factorMilli()` und `lastWeekEnding()` am Emissions-Contract die neue Woche zeigen.

**Achtung Stufe 1:** Der Simulations-Forwarder prüft keine Signaturen, über ihn kann jeder
melden. Ein so deployter Contract ist nur zum Testen da und wird für Stufe 2 neu deployt.

**Stufe 2: echter Betrieb.** Workflow mit `cre workflow deploy` beim Chainlink-Netz anmelden
(laut Entwicklerberichten teils noch Early Access, Zugang bei Chainlink beantragen). Contracts mit
dem echten Forwarder aus dem Forwarder-Verzeichnis deployen, Workflow deployen, dann mit
`pinWorkflow(workflowId)` den Oracle-Contract auf genau diesen Workflow festlegen. Erst danach
hat der Deployer-Schlüssel keine Rechte mehr.

Lokal auf einer Anvil-Testchain ist das Deploy-Skript durchgelaufen.

## Was nicht geprüft ist

- Ob data.cdc.gov und die Chainlink-Doku die erwarteten Daten liefern, konnte ich aus meiner
  Umgebung nicht live abrufen. Der CDC-Datensatz `r8kw-7aab` ist der, den auch der Python-Knoten
  nutzt. Wird er eingestellt, bleibt der Faktor einfach auf dem letzten Wert stehen.
- Chainlink-Knoten müssen sich auf ein identisches Ergebnis einigen. Ändert die CDC genau während
  der Abfrage Daten, scheitert diese eine Woche; die nächste läuft normal.
- Der Workflow ist mit den Test-Werkzeugen des CRE-SDK geprüft und lässt sich zu WASM kompilieren,
  aber noch nie auf echten Chainlink-Knoten gelaufen. Die CRE-CLI war in meiner Umgebung nicht
  installierbar.
- Wer den Workflow besitzt, kann ihn neu deployen. Gegen geänderten Code schützt erst
  `pinWorkflow`; danach lässt sich der Workflow nie mehr ändern. Fällt er aus, bleibt der Faktor
  auf dem letzten Wert stehen, die Ausgabe läuft weiter.
- Staking-Oberfläche: exchange.bloodcoin-us.com/stake (im Börsen-Code).
- **Kein Audit.** Ein Contract, der Geld druckt, gehört vor dem Mainnet in fremde Hände.
