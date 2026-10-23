#!/usr/bin/env python3
"""Unabhängige Prüfung der Orakel-Meldungen, läuft auf GitHub statt auf dem Server.

Liest die Meldungen direkt von der Chain (Event `Reported` von SignedMortalityOracle), rechnet jede
mit den heutigen CDC-Zahlen nach und schlägt Alarm, wenn sie nicht passt. Die abgelegten JSON-Dateien
des Servers werden bewusst nicht benutzt: Wer den Server übernimmt, kann die auch fälschen.

    check.py --rpc URL --oracle 0x.. --from-block N [--days 21] [--max-silence-days 15]

Alarm (Exit-Code 1) bei:
- einer Meldung, deren Summen nicht zu den CDC-Wochen passen,
- einer Meldung mit Wochen, die es bei der CDC nicht gibt,
- `Retired` (Melder abgeschaltet),
- keiner Meldung seit `--max-silence-days` Tagen (Server-Job steht).
Ist NTFY_URL gesetzt, geht der Alarm zusätzlich als Push dorthin.

Braucht nur Python 3. Holt die Rechenregel aus oracle/signed/report.py, damit sie nur an einer
Stelle steht.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "signed"))
import report  # noqa: E402

# keccak256 der Event-Signaturen und Funktions-Selektoren
TOPIC_REPORTED = "0x4229c473bc7b232472389f581f258012ee8d5d83be43bf9e2fba8ed310f22313"  # Reported(uint256,uint256,uint256)
TOPIC_RETIRED = "0xc15f68f0a72806ff3f8bf2435385a67c4c22413f1c7931ef7bcea718e6ffcf03"   # Retired()
SEL_RETIRED = "0x2eb38ae0"                                                              # retired()
SEL_EMISSION = "0x827c049e"                                                             # emission()
SEL_LAST_WEEK = "0xe1ce7fde"                                                            # lastWeekEnding()


# Toleranzen. Die CDC trägt bei jüngeren Wochen oft noch 1 bis 2 % Tote nach, also darf die
# Meldung bei `recent` etwas unter den heutigen Zahlen liegen, aber kaum darüber. Die Vorjahre
# (`baseline`) sind abgeschlossen und müssen fast genau stimmen.
RECENT_LOW = -0.03
RECENT_HIGH = 0.01
BASELINE_TOL = 0.01


class Rpc:
    def __init__(self, url: str):
        self.url = url
        self.n = 0

    def call(self, method: str, params: list):
        for attempt in range(5):
            self.n += 1
            body = json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}).encode()
            req = urllib.request.Request(self.url, body, {"content-type": "application/json",
                                                          "user-agent": "bloodcoin-watch"})
            try:
                with urllib.request.urlopen(req, timeout=30) as r:
                    res = json.loads(r.read())
            except urllib.error.HTTPError as e:
                # sepolia.base.org antwortet auf zu grosse Blockspannen mit HTTP 413
                if e.code == 413:
                    raise RangeError(str(e)) from e
                err = str(e)
            except OSError as e:
                err = str(e)
            else:
                if "error" not in res:
                    return res["result"]
                err = res["error"].get("message", str(res["error"]))
                if "range" in err or "limit" in err or "too many" in err.lower():
                    raise RangeError(err)
            time.sleep(2 ** attempt)
        raise SystemExit(f"Fehler: RPC {method}: {err}")


class RangeError(Exception):
    pass


def get_logs(rpc: Rpc, oracle: str, start: int, end: int) -> list:
    """Alle Logs des Orakels zwischen start und end. Halbiert die Spanne, wenn der RPC zu viel findet."""
    logs, lo, step = [], start, 10_000
    while lo <= end:
        hi = min(end, lo + step - 1)
        try:
            logs += rpc.call("eth_getLogs", [{"address": oracle, "fromBlock": hex(lo), "toBlock": hex(hi),
                                              "topics": [[TOPIC_REPORTED, TOPIC_RETIRED]]}])
        except RangeError:
            if step <= 100:
                raise SystemExit("Fehler: RPC lehnt selbst kleine Blockspannen ab")
            step //= 2
            continue
        lo = hi + 1
    return logs


def block_before(rpc: Rpc, first: int, head: int, ts: int) -> int:
    """Letzter Block ab `first` mit Zeitstempel <= ts (sonst `first`), per Halbierungssuche. Die
    Blockzeit ist nicht fest (Base hat sie schon verkürzt), darum wird nicht mit Sekunden pro Block
    gerechnet. Unter `first` wird nicht gesucht, weil öffentliche RPCs alte Blöcke verwerfen."""
    lo, hi = first, head
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if int(rpc.call("eth_getBlockByNumber", [hex(mid), False])["timestamp"], 16) <= ts:
            lo = mid
        else:
            hi = mid - 1
    return lo


def cdc_weeks(days: list[str]) -> dict[int, int]:
    q = {
        "state": "United States",
        "$select": "week_ending_date,total_deaths",
        "$where": "`group` = 'By Week' AND week_ending_date in(" + ",".join(f"'{d}T00:00:00.000'" for d in days) + ")",
    }
    return report.parse_rows(report.fetch(report.CDC_BASE + "?" + urllib.parse.urlencode(q, quote_via=urllib.parse.quote)))


def check_report(week_ending: int, recent: int, baseline: int, weeks: dict[int, int]) -> list[str]:
    """Vergleicht eine Meldung mit CDC-Wochenwerten {Tag seit 1970: Tote}. Leere Liste = in Ordnung."""
    groups = report.window_days(week_ending // report.DAY)
    missing = [report.iso(d * report.DAY) for g in groups for d in g if d not in weeks]
    if missing:
        return [f"CDC kennt diese Wochen nicht: {', '.join(missing)}"]
    cdc_recent = sum(weeks[d] for d in groups[0])
    cdc_baseline = (sum(weeks[d] for g in groups[1:] for d in g) + 1) // report.BASELINE_YEARS
    problems = []
    r = (recent - cdc_recent) / cdc_recent
    b = (baseline - cdc_baseline) / cdc_baseline
    if not RECENT_LOW <= r <= RECENT_HIGH:
        problems.append(f"letzte 4 Wochen: gemeldet {recent}, CDC heute {cdc_recent} ({r:+.2%})")
    if abs(b) > BASELINE_TOL:
        problems.append(f"Vorjahre: gemeldet {baseline}, CDC heute {cdc_baseline} ({b:+.2%})")
    if problems:
        t_rep, t_cdc = report.target_milli(recent, baseline), report.target_milli(cdc_recent, cdc_baseline)
        problems.append(f"Ziel-Faktor laut Meldung {t_rep}, laut CDC {t_cdc}")
    return problems


def alarm(lines: list[str]) -> None:
    text = "Bloodcoin-Orakel: " + " | ".join(lines)
    for line in lines:
        print(f"::error::{line}")
    url = os.environ.get("NTFY_URL")
    if url:
        req = urllib.request.Request(url, text.encode(), {"Title": "Bloodcoin Orakel-Alarm", "Priority": "high",
                                                          "Tags": "warning"})
        try:
            urllib.request.urlopen(req, timeout=30).close()
        except OSError as e:
            print(f"::warning::ntfy nicht erreichbar: {e}")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--rpc", required=True)
    p.add_argument("--oracle", required=True)
    p.add_argument("--from-block", type=int, required=True, help="Deploy-Block des Orakels")
    p.add_argument("--days", type=int, default=21, help="so weit zurück prüfen (0 = alles ab --from-block)")
    p.add_argument("--max-silence-days", type=int, default=15)
    a = p.parse_args()

    rpc = Rpc(a.rpc)
    head = int(rpc.call("eth_blockNumber", []), 16)
    now = int(rpc.call("eth_getBlockByNumber", [hex(head), False])["timestamp"], 16)
    start = a.from_block if a.days == 0 else block_before(rpc, a.from_block, head, now - a.days * 86400)
    start_ts = int(rpc.call("eth_getBlockByNumber", [hex(start), False])["timestamp"], 16)
    logs = get_logs(rpc, a.oracle, start, head)
    print(f"Blöcke {start} bis {head}: {len(logs)} Ereignisse")

    problems: list[str] = []
    if int(rpc.call("eth_call", [{"to": a.oracle, "data": SEL_RETIRED}, "latest"]), 16):
        problems.append("Melder ist abgeschaltet (retired).")

    emission = "0x" + rpc.call("eth_call", [{"to": a.oracle, "data": SEL_EMISSION}, "latest"])[-40:]
    chain_last = int(rpc.call("eth_call", [{"to": emission, "data": SEL_LAST_WEEK}, "latest"]), 16)
    print(f"Emission {emission}, letzte Woche laut Vertrag: {report.iso(chain_last) if chain_last else 'keine'}")

    last_ts, last_week = None, 0
    for log in logs:
        if log["topics"][0] == TOPIC_RETIRED:
            problems.append(f"Retired in Transaktion {log['transactionHash']}")
            continue
        week = int(log["topics"][1], 16)
        data = log["data"][2:]
        recent, baseline = int(data[:64], 16), int(data[64:128], 16)
        groups = report.window_days(week // report.DAY)
        weeks = cdc_weeks([report.iso(d * report.DAY) for g in groups for d in g])
        found = check_report(week, recent, baseline, weeks)
        print(f"Meldung Woche {report.iso(week)} ({log['transactionHash']}): "
              f"{recent} / {baseline} -> {'NICHT OK' if found else 'ok'}")
        problems += [f"Woche {report.iso(week)}: {f}" for f in found]
        last_ts = int(rpc.call("eth_getBlockByNumber", [log["blockNumber"], False])["timestamp"], 16)
        last_week = max(last_week, week)

    # Kennt der Vertrag eine neuere Woche als die gefundenen Ereignisse, hat die Suche etwas verpasst.
    if chain_last > last_week and (logs or a.days == 0):
        problems.append(f"Vertrag meldet Woche {report.iso(chain_last)}, die Wache hat sie nicht gefunden.")

    silent = (now - last_ts) / 86400 if last_ts else None
    if silent is None:
        if now - start_ts >= a.max_silence_days * 86400:
            problems.append(f"Keine Meldung seit Block {start} ({(now - start_ts) / 86400:.0f} Tage).")
    elif silent > a.max_silence_days:
        problems.append(f"Letzte Meldung vor {silent:.0f} Tagen.")

    if problems:
        alarm(problems)
        sys.exit(1)
    print("Alles in Ordnung.")


if __name__ == "__main__":
    main()
