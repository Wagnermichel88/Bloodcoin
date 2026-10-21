# Plan B: eigener signierter Melder statt Chainlink

Stand: 14.10.2026 (neue Faktor-Regel, siehe `FAKTOR.md`). Vorbereitet, **nicht deployt, nicht auditiert**.

Wenn Chainlink CRE fürs Mainnet zu teuer ist, meldet der eigene Server die CDC-Zahlen.
Token, Emission und Staking bleiben unverändert, nur der Oracle-Contract wird ausgetauscht.

## Was hier liegt

| Datei | Zweck |
|---|---|
| `src/SignedMortalityOracle.sol` | Nimmt nur Meldungen an, die der feste Server-Schlüssel signiert hat (EIP-712, gilt nur für diesen Contract auf dieser Chain). Einreichen darf jeder. |
| `script/DeploySigned.s.sol` | Wie `Deploy.s.sol`, nur mit diesem Oracle und dem Sperrvertrag `FounderLock` für die Startmenge. Braucht `ORACLE_SIGNER` statt `CRE_FORWARDER` und `FOUNDER_BENEFICIARY` statt `INITIAL_HOLDER`. |
| `oracle/signed/report.py` | Wöchentlicher Job: CDC abfragen, signieren, einreichen, Meldung samt CDC-Rohdaten als JSON ablegen. `verify` vergleicht eine abgelegte Meldung mit den aktuellen CDC-Zahlen. |
| `test/SignedOracle.t.sol` | 16 Tests. `test/Test.sol` hat dafür `vm.addr` und `vm.sign` dazubekommen. |

## Was der Contract prüft

- Signatur vom festen Schlüssel `signer` (unveränderlich, kein Besitzer).
- Gemeldet werden zwei Summen über je 4 Wochen: die letzten 4 Wochen und der Durchschnitt derselben
  4 Wochen in den 3 Vorjahren. Beide müssen zwischen 80.000 und 1.000.000 liegen (US-Werte seit
  2015: etwa 200.000 bis 360.000).
- Alles, was `MortalityEmission` ohnehin prüft (Samstag, mindestens 8 Wochen alt, neuer als die
  letzte Meldung, Verhältnis der Summen zwischen 1:2 und 2:1). Deshalb lässt sich keine Meldung
  wiederholen, und eine verrutschte Summe (eine Woche statt vier) wird abgelehnt.
- Die frühere Prüfung "Vorwoche muss zur letzten Meldung passen" ist weg, weil keine Vorwoche mehr
  gemeldet wird. Sie war ohnehin schwach. Ersetzt wird sie durch die Schrittgrenze in
  `MortalityEmission`: Eine einzelne Meldung bewegt den Faktor um höchstens 0,05.
- `retire(signatur)` schaltet den Melder endgültig ab, etwa wenn der Schlüssel gestohlen wurde.
  Dabei geht der Faktor auf 1,0 zurück (`MortalityEmission.resetFactor`), und die Emission läuft
  ohne Sterbe-Anpassung weiter. Ein Dieb kann einen verschobenen Faktor so nicht festschreiben.

## Was er nicht verhindert

Wer den Schlüssel hat, kann falsche Zahlen melden. Eine einzelne falsche Meldung verschiebt den
Faktor nur um 0,05, aber zehn Wochen hintereinander erfundene 15 % Übersterblichkeit drücken ihn
auf 0,5. Schutz ist hier nur die Öffentlichkeit: Jede Meldung liegt mit allen 16 verwendeten
CDC-Wochen und der Signatur offen, jeder kann sie mit `report.py verify` oder direkt bei
data.cdc.gov prüfen, und zehn Wochen sind genug Zeit, dass es jemandem auffällt.

## Server einrichten (erst wenn Plan B gewählt ist)

1. Foundry muss auf dem Server sein (`cast --version`).
2. Neuen Melder-Schlüssel anlegen, nur für diesen Zweck, nie den Deployer-Schlüssel:
   ```bash
   install -d -m 700 /root/bcus-oracle
   openssl rand -hex 32 > /root/bcus-oracle/password && chmod 600 /root/bcus-oracle/password
   cast wallet new /root/bcus-oracle --unsafe-password "$(cat /root/bcus-oracle/password)"
   cast wallet address --keystore /root/bcus-oracle/<datei> --password-file /root/bcus-oracle/password
   ```
   Keystore und Passwort ins tägliche Backup aufnehmen. Die Adresse ist `ORACLE_SIGNER`.
3. Die Adresse braucht etwas ETH auf Base für Gas (eine Meldung kostet um 100.000 Gas, also
   Bruchteile eines Cents pro Woche; 0,001 ETH reicht lange).
4. Deployen mit `DeploySigned.s.sol`:
   ```bash
   export ORACLE_SIGNER=0x...        # Melder-Adresse aus Schritt 2
   export FOUNDER_BENEFICIARY=0x...  # bekommt die Startmenge über 10 Jahre aus dem FounderLock
   export INITIAL_MINT_BCUS=1000000
   # Deployer-Schlüssel als Keystore oder Hardware-Wallet, nie als --private-key (landet sonst
   # in der Shell-History und ist in der Prozessliste sichtbar):
   cast wallet import deployer --interactive        # einmalig, oder --ledger / --trezor
   forge script script/DeploySigned.s.sol --rpc-url $BASE_RPC --broadcast --account deployer
   ```
5. Probelauf, dann echter Lauf:
   ```bash
   python3 oracle/signed/report.py send --rpc $BASE_RPC --oracle 0x... \
     --keystore /root/bcus-oracle/<datei> --password-file /root/bcus-oracle/password \
     --out-dir /opt/bloodcoin/public/oracle --dry-run
   ```
6. Cronjob montags 12:00 UTC (wie bisher der CRE-Workflow), Fehler gehen an den ntfy-Alarm.
7. `/opt/bloodcoin/public/oracle/` auf der Website öffentlich ausliefern und von der
   Staking-Seite verlinken ("Daten prüfen").

## Getestet

62 Contract-Tests grün (18.10.2026: Verbrennen ohne Staker, Faktor-Reset beim Abschalten). Ende-zu-Ende auf einer lokalen Anvil-Chain (14.10.2026, neue Regel):
Deploy, Meldung aus echten Wochenzahlen der Grippesaison 2017/18 (+3,5 % gegen die Vorjahre,
Ziel und Faktor 973 im Contract), zweiter Lauf erkennt "schon gemeldet". Die Faktor-Formel in
Python und JavaScript stimmt an 20.000 Zufallswerten überein, Solidity und JavaScript an 300.
Nicht getestet: echter Abruf bei data.cdc.gov (aus der Testumgebung gesperrt), Base-Mainnet.
