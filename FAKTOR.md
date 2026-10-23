# Sterbe-Faktor: neue Regel (14.10.2026)

Stand: umgesetzt in Contracts, Chainlink-Workflow und Plan-B-Skript. **Nicht deployt.**

## Was an der alten Regel falsch war

Alt: Tote dieser Woche gegen Tote der Vorwoche, 1 % mehr Tote = 10 % weniger neue Coins.

Gemessen an echten US-Wochenzahlen (2015 bis 2024, `oracle/sim/`) stimmt die Befürchtung
"der Faktor hängt fast jede Woche am Anschlag" nicht ganz: Das passiert nur in etwa 1 % der
Wochen. Das eigentliche Problem ist schlimmer:

- Der Faktor springt **von Woche zu Woche typischerweise um 13 %**, in 5 % der Wochen unter 0,77
  oder über 1,22. Das ist reines Rauschen: Wochenwerte schwanken normal um ±2,7 %.
- Im Mittel liegt er bei 1,0, auch **2020/21 während Covid (Mittel 0,99)**. Eine Pandemie mit
  über einer Million Toten hat die Ausgabe praktisch nicht verändert, weil ein Anstieg in einer
  Woche durch einen Rückgang in der nächsten wieder aufgehoben wird.

Die alte Regel misst also nicht die Sterblichkeit, sondern die Wochen-Schwankung. Sie ist ein
Zufallsgenerator mit Sterbe-Etikett.

## Neue Regel

1. **Signal:** Tote der letzten 4 Wochen gegen den Durchschnitt derselben 4 Wochen in den
   3 Vorjahren. So misst man Übersterblichkeit üblicherweise. Saison (Winter immer höher) und
   Wochenrauschen fallen weg.
2. **Toleranz:** Bis ±3 % Abweichung bleibt das Ziel bei 1,0. Darin steckt normales Rauschen und
   der Alterungstrend der Bevölkerung (jedes Jahr etwas mehr Tote).
3. **Kurve:** Jedes Prozent darüber kostet 5 % der neuen Coins, die Untergrenze 0,5 ist ab 13 %
   Übersterblichkeit erreicht. Weniger Tote als üblich bringen nichts extra, das Ziel bleibt 1,0
   (bis 23.10.2026 waren es bis zu 1,5, siehe unten "Warum kein Bonus").
4. **Trägheit:** Der Faktor läuft pro Meldung höchstens 0,05 auf das Ziel zu. Von 1,0 auf 0,5
   braucht es zehn Wochen. Das glättet zusätzlich und begrenzt den Schaden einer falschen
   Meldung (egal ob Chainlink-Fehler oder gestohlener Plan-B-Schlüssel) auf 5 %.
5. **Plausibilität:** Ist die 4-Wochen-Summe mehr als doppelt oder weniger als halb so groß wie
   die der Vorjahre, lehnt der Contract ab. Das gab es nicht einmal 2020/21; so etwas ist ein
   Formatfehler.

## Ergebnis an echten Daten

`python3 -I oracle/sim/simulate.py` (Faktor in Promille, 1000 = normal):

| | p5 | Median | p95 | am Anschlag | Sprung/Woche | Mittel |
|---|---|---|---|---|---|---|
| Alt, normale Jahre 2018/19 | 765 | 1000 | 1218 | 1 % | 134 | 1006 |
| Alt, Covid 2020/21 | 500 | 997 | 1397 | 11 % | 143 | 991 |
| **Neu, normale Jahre 2018/19** | 800 | 1000 | 1000 | 0 % | 0 | 974 |
| **Neu, Covid 2020/21** | 500 | 533 | 1000 | 46 % | 0 | 663 |

In normalen Jahren steht der Faktor fast immer still bei 1,0. Er sank nur in der schweren
Grippesaison 2017/18 für einige Wochen bis 0,65 (echte Übersterblichkeit von etwa 10 %). Covid
drückte ihn ab Ende März 2020 innerhalb von knapp drei Monaten auf 0,5, wo er blieb, solange die Übersterblichkeit
anhielt. Genau so soll sich ein Sterbe-Index verhalten.

## Was du wissen musst

- **Der Faktor wird fast nie über 1,0 steigen.** Weniger Tote als in den Vorjahren gibt es selten,
  weil die Bevölkerung altert. Langfristig liegt die Ausgabe in normalen Jahren bei etwa 97 % des
  Halbierungsplans. Das ist ehrlicher als vorher, aber es heisst: Der Coin belohnt keine "guten"
  Jahre, er bestraft nur schlechte. Wenn du das symmetrisch willst, müsste die Toleranz um den
  Trend verschoben werden. Das würde ich erst nach einem Jahr echter Meldungen entscheiden.
- **Das Testnetz muss neu deployt werden**, wenn du die neue Regel dort sehen willst.
  `MortalityEmission` ist unveränderlich und erzeugt den Token selbst, also bekommen Token,
  Emission, Staking und Oracle neue Adressen, und die 1 Mio. Test-BCUS werden neu ausgegeben.
  Fürs Mainnet ist das egal, das ist ohnehin noch nicht deployt. **Gut, dass das jetzt kommt und
  nicht nach dem Mainnet-Start.**
- **Server-Stand:** Der wöchentliche Job auf dem Server nutzt den älteren `cdc.js`. Die neuen
  Dateien müssen mit dem Neu-Deployment zusammen auf den Server, nicht vorher: Die alten Contracts
  verstehen das neue Format nicht (sie würden die Summen als Wochenwerte lesen).
- **Chainlink:** Das Berichtsformat bleibt drei Zahlen, nur ihre Bedeutung ändert sich. Die
  CDC-Abfrage holt jetzt 180 statt 6 Wochen (rund 15 KB), das ist für CRE kein Problem. Die
  Workflow-ID ändert sich, weil der Code anders ist; `pinWorkflow` kommt erst nach dem Deployment.
- **Bloodcoin-Node** (`bloodcoin/mortality.py`, eigene Chain) rechnet weiter nach der alten
  Regel. Das ist die Spiel-Chain ohne echtes Geld; eine Änderung dort wäre eine Konsensänderung
  ab einer bestimmten Blockhöhe. Lohnt sich erst, wenn die Node mehr als eine Demo ist.

## Geänderte Dateien

- `src/MortalityEmission.sol`: `targetFor`, `stepToward`, `targetMilli`, `report(week, recent, baseline)`
- `src/CreMortalityOracle.sol`, `src/SignedMortalityOracle.sol`: neue Bedeutung der Zahlen; im
  Plan-B-Melder Bereich 80.000 bis 1.000.000 pro 4 Wochen, Vorwochen-Prüfung entfernt
- `oracle/cre-workflow/cdc.js`, `workflow.ts`, Tests: 16 Wochen pro Meldung
- `oracle/signed/report.py`: gleiche Rechnung, legt alle 16 verwendeten Wochen offen ab, `verify` prüft jede
- `oracle/sim/`: Simulation und Daten (Our World in Data, Quelle dort CDC)

## Getestet

- 47 Contract-Tests grün (`forge test --offline`), darunter Schrittgrenze und erfundene Katastrophe.
- Workflow: `bun test` (3) und `node test-cdc.mjs` grün, `tsc` ohne Fehler, `cre-compile` baut die WASM-Datei.
- Gleiche Formel in Solidity, JavaScript und Python (Zufallsvergleich).
- Plan B Ende-zu-Ende auf lokaler Anvil-Chain: Deploy, Meldung, Faktor im Contract wie berechnet.
- **Nicht getestet:** echter Abruf bei data.cdc.gov (aus der Testumgebung gesperrt). Die CDC-Reihe
  r8kw-7aab beginnt 2020; für Meldungen ab Herbst 2026 reichen die Vorjahre 2023 bis 2025.

## Warum kein Bonus bei weniger Toten (23.10.2026)

Bis zum 23.10.2026 brachte jedes Prozent Untersterblichkeit 5 % mehr Coins, bis 1,5. Ein
Stresstest mit den echten Covid-Jahren zeigte, dass dieser Bonus fast nur aus zwei Fehlern kommt:

- **Echo:** Der Vergleichswert sind die 3 Vorjahre. 2023 sind das 2020 bis 2022, also die
  Covid-Jahre. Ein normales Jahr sieht dagegen wie 10 bis 15 % Untersterblichkeit aus. Mit der
  alten Regel hätte die Ausgabe 2023 um 25 % und 2024 um 22 % über dem Plan gelegen.
- **Untererfassung:** Meldet die CDC zu wenige Tote (fehlende Staaten, Verzug), stieg der Faktor.
  Ein Datenfehler hätte also mehr Coins erzeugt.

Seitdem bleibt das Ziel bei weniger Toten auf 1,0. Tote können neue Coins nur verringern, nie
vermehren. Die Ausgabe liegt damit nie über dem Halbierungsplan. Rechnung:
`/mnt/project-files/orakel-extrem/` (Projektablage, `extrem_sim.py`, `alternativen_sim.py`).
