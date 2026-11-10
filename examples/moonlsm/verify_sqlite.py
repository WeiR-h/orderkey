"""Compare keys emitted by the compiled MoonBit demo with SQLite's ordering."""

from contextlib import closing
from pathlib import Path
import sqlite3
import subprocess


PROJECT = Path(__file__).resolve().parents[2]


def read_fixture(target):
    result = subprocess.run(
        ["moon", "run", "--target", target, "examples/moonlsm", "--", "--sqlite-fixture"],
        cwd=PROJECT,
        capture_output=True,
        encoding="utf-8",
        check=False,
    )
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    rows = []
    matches = []
    for line in result.stdout.splitlines():
        if line.startswith("key,"):
            _, tenant, device, timestamp, sequence, key = line.split(",")
            rows.append(
                (
                    bytes.fromhex(tenant),
                    bytes.fromhex(device),
                    int(timestamp),
                    int(sequence),
                    bytes.fromhex(key),
                )
            )
        elif line.startswith("match,"):
            matches.append(bytes.fromhex(line.removeprefix("match,")))
    if len(rows) != 9840 or len(matches) != 18:
        raise AssertionError(f"{target} emitted {len(rows)} keys and {len(matches)} matches")
    return rows, matches


def verify_order(rows, matches):
    with closing(sqlite3.connect(":memory:")) as database:
        database.execute(
            "CREATE TABLE events(tenant BLOB, device BLOB, timestamp INTEGER, "
            "sequence INTEGER, encoded BLOB UNIQUE)"
        )
        database.executemany("INSERT INTO events VALUES (?, ?, ?, ?, ?)", rows)
        typed_order = database.execute(
            "SELECT encoded FROM events ORDER BY tenant, device, timestamp DESC, sequence"
        ).fetchall()
        byte_order = database.execute(
            "SELECT encoded FROM events ORDER BY encoded"
        ).fetchall()
        expected_matches = database.execute(
            "SELECT encoded FROM events WHERE tenant=? AND device=? "
            "AND timestamp>=? AND timestamp<? ORDER BY timestamp DESC, sequence",
            (b"t3", b"pump\x00A", -2, 4),
        ).fetchall()
    if typed_order != byte_order:
        raise AssertionError("SQLite tuple order differs from encoded BLOB order")
    if [(key,) for key in matches] != expected_matches:
        raise AssertionError("MoonLSM results differ from SQLite's typed range query")


def main():
    js = read_fixture("js")
    wasm_gc = read_fixture("wasm-gc")
    if js != wasm_gc:
        raise AssertionError("JS and Wasm GC emitted different key or result bytes")
    verify_order(*js)
    print("SQLite verified 9840 keys and 18 matches. JS and Wasm GC bytes agree.")


if __name__ == "__main__":
    main()
