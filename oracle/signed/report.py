#!/usr/bin/env python3
"""Wöchentliche CDC-Meldung an SignedMortalityOracle (Plan B ohne Chainlink).

Holt die US-Sterbezahlen bei data.cdc.gov und rechnet nach derselben Regel wie
cre-workflow/cdc.js: Tote der letzten 4 Wochen (recent) und Durchschnitt derselben 4 Wochen in den
3 Vorjahren (baseline). Signiert das mit dem Server-Schlüssel (EIP-712, über `cast`) und reicht es ein. Jede Meldung wird samt CDC-Rohdaten als JSON abgelegt, damit
jeder sie nachprüfen kann.

    report.py send   --rpc URL --oracle 0x.. --keystore F --password-file F --out-dir DIR [--dry-run]
    report.py verify DATEI.json      # vergleicht eine abgelegte Meldung mit den heutigen CDC-Zahlen

Braucht nur Python 3 und Foundry (`cast`). Exit-Code ungleich 0 bei jedem Fehler.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

CDC_BASE = "https://data.cdc.gov/resource/r8kw-7aab.json"
LAG_DAYS = 56
WINDOW_WEEKS = 4
BASELINE_YEARS = 3
DAY = 86400


def cdc_url(today: dt.date) -> str:
    cutoff = (today - dt.timedelta(days=LAG_DAYS)).isoformat()
    q = {
        "state": "United States",
        "$select": "week_ending_date,total_deaths",
        # "group" ist in SoQL reserviert, deshalb im $where mit Backticks.
        "$where": f"`group` = 'By Week' AND week_ending_date <= '{cutoff}T00:00:00.000'",
        "$order": "week_ending_date DESC",
        "$limit": "180",   # 3 Jahre plus 4 Wochen plus Spielraum
    }
    return CDC_BASE + "?" + urllib.parse.urlencode(q, quote_via=urllib.parse.quote)


def fetch(url: str) -> list:
    req = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "bloodcoin-oracle"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def parse_rows(rows: list) -> dict[int, int]:
    """CDC-Zeilen -> {Tag seit 1970: Tote}. Kaputte Zeilen werden übergangen."""
    weeks: dict[int, int] = {}
    for r in rows:
        try:
            day = (dt.date.fromisoformat(str(r["week_ending_date"])[:10]) - dt.date(1970, 1, 1)).days
            deaths = int(float(r["total_deaths"]))
        except (KeyError, ValueError, TypeError):
            continue
        if 0 < deaths < 10_000_000:
            weeks[day] = deaths
    return weeks


def window_days(day: int) -> list[list[int]]:
    """Die 4 Wochen bis `day`, danach dieselben 4 Wochen in jedem der 3 Vorjahre (je 52 Wochen zurück)."""
    return [[day - 364 * k - 7 * j for j in range(WINDOW_WEEKS)] for k in range(BASELINE_YEARS + 1)]


def pick_window(rows: list, today: dt.date) -> tuple[int, int, int]:
    """Neueste Woche, die mindestens 8 Wochen alt ist und für die alle 16 Wochen vorliegen.
    Rückgabe: (weekEnding in Sekunden, recent, baseline)."""
    weeks = parse_rows(rows)
    limit = (today - dt.date(1970, 1, 1)).days - LAG_DAYS
    for day in sorted(weeks, reverse=True):
        if day > limit:
            continue
        groups = window_days(day)
        if all(d in weeks for g in groups for d in g):
            recent = sum(weeks[d] for d in groups[0])
            past = sum(weeks[d] for g in groups[1:] for d in g)
            return day * DAY, recent, (past + 1) // BASELINE_YEARS
    raise SystemExit("Fehler: keine ausreichend alte Woche mit vollständigen Vorjahren in den CDC-Daten")


def target_milli(recent: int, baseline: int) -> int:
    """Ziel-Faktor in Promille, gleiche Formel wie MortalityEmission.targetFor.
    Weniger Tote als üblich ergeben 1000, nie mehr."""
    if recent <= baseline:
        return 1000
    bp = ((recent - baseline) * 10_000 + baseline // 2) // baseline
    if bp <= 300:
        return 1000
    return max(500, 1000 - 5 * (bp - 300) // 10)


def step_toward(current: int, target: int) -> int:
    """Wie MortalityEmission.stepToward: höchstens 50 Promille pro Meldung."""
    return current + max(-50, min(50, target - current))


def cast(*args: str) -> str:
    r = subprocess.run(["cast", *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"Fehler: cast {args[0]}: {r.stderr.strip()}")
    return r.stdout.strip()


def call_uint(rpc: str, to: str, sig: str, *args: str) -> int:
    return int(cast("call", "--rpc-url", rpc, to, sig, *args).split()[0])


def iso(week_ending: int) -> str:
    return dt.datetime.fromtimestamp(week_ending, dt.timezone.utc).date().isoformat()


def cmd_send(a) -> None:
    today = dt.datetime.now(dt.timezone.utc).date()
    url = cdc_url(today)
    rows = json.loads(Path(a.cdc_file).read_text()) if a.cdc_file else fetch(url)
    week, recent, baseline = pick_window(rows, today)
    target = target_milli(recent, baseline)
    print(f"CDC: 4 Wochen bis {iso(week)}: {recent} Tote, Vorjahre {baseline} "
          f"({(recent - baseline) / baseline:+.2%}), Ziel-Faktor {target}")

    emission = cast("call", "--rpc-url", a.rpc, a.oracle, "emission()(address)")
    last = call_uint(a.rpc, emission, "lastWeekEnding()(uint256)")
    if week <= last:
        print(f"Nichts zu tun: {iso(last)} ist schon gemeldet.")
        return
    if cast("call", "--rpc-url", a.rpc, a.oracle, "retired()(bool)") == "true":
        raise SystemExit("Fehler: Melder ist abgeschaltet (retire).")
    factor_now = call_uint(a.rpc, emission, "factorMilli()(uint256)")
    print(f"Faktor jetzt {factor_now}, nach dieser Meldung {step_toward(factor_now, target)}")

    digest = cast("call", "--rpc-url", a.rpc, a.oracle,
                  "reportDigest(uint256,uint256,uint256)(bytes32)", str(week), str(recent), str(baseline))
    wallet = ["--keystore", a.keystore, "--password-file", a.password_file]
    signature = cast("wallet", "sign", "--no-hash", digest, *wallet)
    signer = cast("wallet", "address", *wallet)

    record = {
        "week_ending": iso(week),
        "week_ending_unix": week,
        "recent_deaths": recent,
        "baseline_deaths": baseline,
        "weeks_used": {iso(d * DAY): parse_rows(rows)[d] for g in window_days(week // DAY) for d in g},
        "target_milli": target,
        "cdc_query": url,
        "cdc_rows": rows,
        "fetched_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "chain_id": int(cast("chain-id", "--rpc-url", a.rpc)),
        "oracle": a.oracle,
        "signer": signer,
        "eip712_digest": digest,
        "signature": signature,
        "tx": None,
    }
    out = Path(a.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    path = out / f"{iso(week)}.json"

    if not a.dry_run:
        tx = cast("send", "--rpc-url", a.rpc, *wallet, "--json", a.oracle,
                  "submit(uint256,uint256,uint256,bytes)", str(week), str(recent), str(baseline), signature)
        receipt = json.loads(tx)
        if receipt.get("status") not in ("0x1", 1, "1"):
            path.write_text(json.dumps(record, indent=2) + "\n")
            raise SystemExit(f"Fehler: Transaktion fehlgeschlagen: {receipt.get('transactionHash')}")
        record["tx"] = receipt["transactionHash"]
        print(f"Gemeldet: {record['tx']}")
    else:
        print("Probelauf: nichts gesendet.")
    path.write_text(json.dumps(record, indent=2) + "\n")
    write_index(out)
    print(f"Abgelegt: {path}")


def write_index(out: Path) -> None:
    """index.json für die öffentliche Prüfseite (oracle.html): alle Meldungen ohne Rohdaten, neueste zuerst."""
    keep = ("week_ending", "recent_deaths", "baseline_deaths", "target_milli", "weeks_used",
            "fetched_at", "chain_id", "oracle", "signer", "signature", "tx")
    items = []
    for f in sorted(out.glob("????-??-??.json"), reverse=True):
        rec = json.loads(f.read_text())
        items.append({k: rec.get(k) for k in keep} | {"file": f.name})
    tmp = out / "index.json.tmp"
    tmp.write_text(json.dumps(items, indent=1) + "\n")
    tmp.replace(out / "index.json")


def cmd_verify(a) -> None:
    rec = json.loads(Path(a.file).read_text())
    days = ",".join(f"'{d}T00:00:00.000'" for d in rec["weeks_used"])
    q = {
        "state": "United States",
        "$select": "week_ending_date,total_deaths",
        "$where": f"`group` = 'By Week' AND week_ending_date in({days})",
    }
    now = parse_rows(fetch(CDC_BASE + "?" + urllib.parse.urlencode(q, quote_via=urllib.parse.quote)))
    ok = True
    for day, reported in rec["weeks_used"].items():
        cdc = now.get((dt.date.fromisoformat(day) - dt.date(1970, 1, 1)).days)
        diff = "fehlt" if cdc is None else f"{(reported - cdc) / cdc:+.2%}"
        print(f"Woche {day}: gemeldet {reported}, CDC heute {cdc} ({diff})")
        ok &= cdc is not None
    groups = window_days(rec["week_ending_unix"] // DAY)
    used = {(dt.date.fromisoformat(d) - dt.date(1970, 1, 1)).days: v for d, v in rec["weeks_used"].items()}
    recent = sum(used[d] for d in groups[0])
    baseline = (sum(used[d] for g in groups[1:] for d in g) + 1) // BASELINE_YEARS
    if (recent, baseline) != (rec["recent_deaths"], rec["baseline_deaths"]):
        print("Summen passen nicht zu den einzelnen Wochen!")
        ok = False
    if target_milli(recent, baseline) != rec["target_milli"]:
        print("Ziel-Faktor passt nicht zu den Zahlen!")
        ok = False
    print("Hinweis: Die CDC korrigiert jüngere Wochen oft noch um ein bis zwei Prozent nach oben.")
    sys.exit(0 if ok else 1)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("send")
    s.add_argument("--rpc", required=True)
    s.add_argument("--oracle", required=True)
    s.add_argument("--keystore", required=True)
    s.add_argument("--password-file", required=True)
    s.add_argument("--out-dir", required=True)
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--cdc-file", help="CDC-Antwort aus Datei statt Abruf (nur für Tests)")
    v = sub.add_parser("verify")
    v.add_argument("file")
    a = p.parse_args()
    cmd_send(a) if a.cmd == "send" else cmd_verify(a)


if __name__ == "__main__":
    main()
