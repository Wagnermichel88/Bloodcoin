#!/usr/bin/env python3
"""BCUS-Miner für normale Computer (CPU). Sucht Lösungen für BcusMining und reicht sie ein.

Braucht: Python 3.9+, `pip install pycryptodome`, Foundry (`cast`) und eine Wallet mit etwas ETH auf
Base für Gas. Die Belohnung geht an die Adresse, die einreicht; sie steckt im Hash.

    python3 miner/mine.py --rpc https://sepolia.base.org --mining 0x... --account miner

`--account` ist ein Foundry-Keystore (`cast wallet import miner --interactive`). Mit `--dry-run`
sucht der Miner nur und reicht nichts ein.

Eine gefundene Lösung wird erst eingereicht, wenn seit der letzten Lösung im Vertrag mindestens
`--min-interval` Sekunden vergangen sind (Standard 600). Früher lohnt es sich kaum: Die Belohnung
wächst mit der Zeit seit der letzten Lösung, das Gas kostet jedes Mal gleich viel.

Ehrlich: Mit einer CPU ist man langsam. Sobald jemand mit Grafikkarten schürft, steigt die
Schwierigkeit, und eine CPU findet kaum noch etwas. Das ist bei Bitcoin genauso.
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time

try:
    from Crypto.Hash import keccak
except ImportError:
    sys.exit("pycryptodome fehlt: pip install pycryptodome")


def keccak256(data: bytes) -> bytes:
    return keccak.new(digest_bits=256, data=data).digest()


def solution_hash(challenge: bytes, miner: bytes, nonce: int) -> int:
    """Gleich wie BcusMining.solutionHash: keccak256(abi.encodePacked(challenge, miner, nonce))."""
    return int.from_bytes(keccak256(challenge + miner + nonce.to_bytes(32, "big")), "big")


class CastError(Exception):
    pass


def cast(*args: str) -> str:
    r = subprocess.run(["cast", *args], capture_output=True, text=True)
    if r.returncode != 0:
        lines = r.stderr.strip().splitlines() or [f"cast endete mit {r.returncode}"]
        raise CastError(lines[-1])
    return r.stdout.strip()


def cast_read(*args: str) -> str:
    """Lesender Aufruf; bei Netzfehlern bis zu rund 2 Minuten lang neu versuchen."""
    for wait in (2, 4, 8, 16, 30, 30, 30, None):
        try:
            return cast(*args)
        except CastError as e:
            if wait is None:
                raise
            print(f"RPC-Fehler (error): {e} - neuer Versuch in {wait} s", flush=True)
            time.sleep(wait)
    raise AssertionError


def read_state(rpc: str, mining: str) -> tuple[bytes, int]:
    challenge = bytes.fromhex(cast_read("call", mining, "challenge()(bytes32)", "--rpc-url", rpc)[2:])
    target = int(cast_read("call", mining, "currentTarget()(uint256)", "--rpc-url", rpc).split()[0])
    return challenge, target


def seconds_since_last(rpc: str, mining: str) -> int:
    """Sekunden seit der letzten Lösung, gemessen an der Zeit des letzten Blocks (nicht der Uhr)."""
    last = int(cast_read("call", mining, "lastMined()(uint256)", "--rpc-url", rpc).split()[0])
    now = int(cast_read("block", "latest", "-f", "timestamp", "--rpc-url", rpc))
    return now - last


def search(challenge: bytes, miner: bytes, target: int, start: int, count: int) -> int | None:
    for nonce in range(start, start + count):
        if solution_hash(challenge, miner, nonce) <= target:
            return nonce
    return None


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rpc", required=True)
    ap.add_argument("--mining", required=True, help="Adresse des BcusMining-Contracts")
    ap.add_argument("--account", help="Foundry-Keystore zum Einreichen")
    ap.add_argument("--address", help="eigene Adresse (nur mit --dry-run nötig)")
    ap.add_argument("--batch", type=int, default=200_000, help="Versuche zwischen zwei Abfragen")
    ap.add_argument("--min-interval", type=int, default=600,
                    help="frühestens so viele Sekunden nach der letzten Lösung einreichen (Standard 600)")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    if a.dry_run:
        if not a.address:
            sys.exit("--dry-run braucht --address")
        me = a.address
    else:
        if not a.account:
            sys.exit("--account fehlt")
        me = cast("wallet", "address", "--account", a.account)
    miner = bytes.fromhex(me[2:].rjust(40, "0"))

    nonce = int.from_bytes(os.urandom(8), "big")     # zufälliger Start, damit zwei Miner nicht dasselbe suchen
    found, found_for = None, None                    # bereitgehaltene Lösung und ihre Aufgabe
    failures = 0
    while True:
        challenge, target = read_state(a.rpc, a.mining)
        if found is not None and (found_for != challenge or solution_hash(challenge, miner, found) > target):
            print("Aufgabe hat sich geändert (jemand war schneller oder die eigene Lösung ging doch durch)", flush=True)
            found = None
        if found is None:
            t0 = time.time()
            found = search(challenge, miner, target, nonce, a.batch)
            rate = a.batch / max(time.time() - t0, 1e-9)
            nonce += a.batch
            if found is None:
                print(f"{rate:,.0f} Hashes/s, noch nichts gefunden", flush=True)
                continue
            found_for = challenge
            print(f"Lösung gefunden: nonce {found}", flush=True)
            if a.dry_run:
                return

        # Warten, bis sich das Einreichen lohnt, und nie zweimal im selben Block (sonst NothingToMine).
        wait = max(a.min_interval, 1) - seconds_since_last(a.rpc, a.mining)
        if wait > 0:
            print(f"Bereit, warte noch {wait} s", flush=True)
            time.sleep(min(wait, 15))
            continue

        try:
            out = cast("send", a.mining, "mine(uint256)", str(found), "--rpc-url", a.rpc, "--account", a.account)
        except CastError as e:
            failures += 1
            print(f"Einreichen fehlgeschlagen (error): {e}", flush=True)
            if failures >= 10:
                sys.exit("Abbruch (error): 10 Fehlschläge hintereinander")
            time.sleep(2)
            continue                                 # Zustand neu lesen: vielleicht ging die Lösung doch durch
        failures = 0
        found = None
        print(out, flush=True)


if __name__ == "__main__":
    main()
