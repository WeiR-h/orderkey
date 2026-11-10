"""Compare keys emitted by the compiled MoonBit demo with SQLite's ordering."""

import argparse
from contextlib import closing
from pathlib import Path
import csv
import hashlib
import io
import sqlite3
import subprocess
import tempfile
import zipfile


PROJECT = Path(__file__).resolve().parents[2]
WEATHER = Path(__file__).with_name("fixtures") / "noaa-ghcnd-2024-q1.csv"
WEATHER_SHA256 = "8b95d0fc273a6af5b13593f9c5b51259304f1d212abe2cb3150c3d3f58094308"


def read_fixture(target, arguments, expected_counts, project=PROJECT):
    result = subprocess.run(
        ["moon", "run", "--target", target, "examples/moonlsm", "--", *arguments],
        cwd=project,
        capture_output=True,
        encoding="utf-8",
        check=False,
    )
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    rows = []
    matches = []
    snapshot_matches = []
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
        elif line.startswith("fst,"):
            snapshot_matches.append(bytes.fromhex(line.removeprefix("fst,")))
    counts = (len(rows), len(matches), len(snapshot_matches))
    if counts != expected_counts:
        raise AssertionError(
            f"{target} emitted {counts} keys / MoonLSM matches / MoonFST matches "
            f"but expected {expected_counts}"
        )
    return rows, matches, snapshot_matches


def verify_order(rows, matches, snapshot_matches, query):
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
            query,
        ).fetchall()
    if typed_order != byte_order:
        raise AssertionError("SQLite tuple order differs from encoded BLOB order")
    if [(key,) for key in matches] != expected_matches:
        raise AssertionError("MoonLSM results differ from SQLite's typed range query")
    if [(key,) for key in snapshot_matches] != expected_matches:
        raise AssertionError("MoonFST results differ from SQLite's typed range query")


def verify_case(name, arguments, counts, query, expected_values=None):
    js = read_fixture("js", arguments, counts)
    wasm_gc = read_fixture("wasm-gc", arguments, counts)
    if js != wasm_gc:
        raise AssertionError(f"{name}: JS and Wasm GC emitted different key or result bytes")
    if expected_values is not None and [row[:4] for row in js[0]] != expected_values:
        raise AssertionError(f"{name}: emitted values differ from the source fixture")
    verify_order(*js, query)
    print(
        f"{name}: SQLite verified {counts[0]} keys and {counts[1]} matches per engine. "
        "JS and Wasm GC bytes agree."
    )
    return js


def weather_fixture():
    raw = WEATHER.read_bytes()
    if hashlib.sha256(raw).hexdigest() != WEATHER_SHA256:
        raise AssertionError("NOAA fixture SHA-256 mismatch")
    packed = []
    values = []
    for row in csv.DictReader(io.StringIO(raw.decode("ascii"), newline="")):
        station = row["STATION"]
        day = row["DATE"].replace("-", "")
        packed.append("|".join((station, day, row["TMAX"], row["TMIN"])))
        values.append((b"ghcnd", station.encode("ascii"), int(day), 0))
    return ";".join(packed), values


def verify_baseline(current):
    archive = subprocess.run(
        ["git", "archive", "--format=zip", "v0.0.1"],
        cwd=PROJECT,
        capture_output=True,
        check=True,
    ).stdout
    temp_root = Path(tempfile.gettempdir()).resolve()
    with tempfile.TemporaryDirectory(prefix="orderkey-v001-", dir=temp_root) as temp:
        baseline_root = Path(temp).resolve()
        if baseline_root.parent != temp_root:
            raise RuntimeError("unexpected baseline directory")
        with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
            zipped.extractall(baseline_root)
        baseline = read_fixture(
            "js", ["--sqlite-fixture"], (9840, 18, 0), project=baseline_root
        )
    if baseline[:2] != current[:2]:
        raise AssertionError("v0.0.1 and the current version emitted different keys")
    print("Compatibility: 9840 encoded keys and 18 MoonLSM results match v0.0.1 byte for byte.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--baseline",
        action="store_true",
        help="rebuild the v0.0.1 Git tag and compare the emitted synthetic keys",
    )
    arguments = parser.parse_args()
    synthetic = verify_case(
        "Synthetic",
        ["--sqlite-fixture"],
        (9840, 18, 18),
        (b"t3", b"pump\x00A", -2, 4),
    )
    weather, values = weather_fixture()
    verify_case(
        "NOAA GHCNd",
        ["--weather-fixture", weather],
        (273, 29, 29),
        (b"ghcnd", b"USW00094846", 20240201, 20240301),
        values,
    )
    if arguments.baseline:
        verify_baseline(synthetic)


if __name__ == "__main__":
    main()
