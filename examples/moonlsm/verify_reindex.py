"""Rebuild the fixtures and compare the reopened indexes with SQLite."""

import argparse
import csv
import hashlib
import json
from contextlib import closing
from itertools import zip_longest
from pathlib import Path
import sqlite3
import tempfile

from verify_sqlite import WEATHER, run_fixture, weather_fixture


def inputs(weather):
    if weather:
        packed, values = weather_fixture()
        with WEATHER.open(encoding="ascii", newline="") as source:
            payloads = [
                f"{row['TMAX']},{row['TMIN']}".encode("ascii")
                for row in csv.DictReader(source)
            ]
        return ["--weather-reindex", packed], [
            (*fields, payload) for fields, payload in zip(values, payloads, strict=True)
        ], (b"ghcnd", b"USW00094846", 20240201, 20240301), 29
    rows = [
        (f"t{tenant}".encode("ascii"), device, time, sequence, b"reading")
        for tenant in range(10)
        for device in (b"pump", b"pump\x00A", b"pump\x00B", b"pump\xff",
                       b"meter", b"valve", b"fan", b"edge")
        for time in range(-20, 21)
        for sequence in range(3)
    ]
    return ["--reindex"], rows, (b"t3", b"pump\x00A", -2, 4), 18


def read_rows(target, arguments):
    result = {name: [] for name in ("source-before", "source-after", "target", "match", "fst")}
    checks = set()
    contracts = None
    snapshot_bytes = None
    for line in run_fixture(target, arguments):
        tag, *fields = line.split(",")
        if tag == "target":
            tenant, device, timestamp, sequence, payload, key = fields
            result[tag].append((
                bytes.fromhex(tenant), bytes.fromhex(device), int(timestamp), int(sequence),
                bytes.fromhex(payload), bytes.fromhex(key),
            ))
        elif tag in result:
            key, payload = fields
            result[tag].append((bytes.fromhex(key), bytes.fromhex(payload)))
        elif tag == "checks":
            checks.update(fields)
        elif tag == "snapshot-bytes":
            if snapshot_bytes is not None or len(fields) != 1:
                raise ValueError("expected one snapshot size")
            snapshot_bytes = int(fields[0])
        elif tag == "contracts":
            if contracts is not None or len(fields) != 2:
                raise ValueError("expected one source and target contract")
            contracts = dict(zip(("source", "target"), fields, strict=True))
    return result, sorted(checks), contracts, snapshot_bytes


def describe(value):
    if isinstance(value, bytes):
        return value.hex()
    if isinstance(value, (tuple, list)):
        return [describe(item) for item in value]
    return value


def compare(label, actual, expected):
    for index, (left, right) in enumerate(zip_longest(actual, expected)):
        if left != right:
            raise ValueError(
                f"{label} row {index}: got {describe(left)}, expected {describe(right)}"
            )


def digest(rows):
    checksum = hashlib.sha256()
    for row in rows:
        for part in row:
            checksum.update(len(part).to_bytes(8, "big"))
            checksum.update(part)
    return checksum.hexdigest()


def verify_case(weather):
    arguments, source, query, match_count = inputs(weather)
    rows, checks, contracts, snapshot_bytes = read_rows("js", arguments)
    other_rows, other_checks, other_contracts, other_size = read_rows("wasm-gc", arguments)
    if checks != other_checks or contracts != other_contracts or snapshot_bytes != other_size:
        raise ValueError("JS and Wasm GC checks or contracts differ")
    for kind in rows:
        compare(f"JS versus Wasm GC {kind}", other_rows[kind], rows[kind])
    required = {"stale-cursor", "bad-key", "duplicate-target", "write-failure", "moonlsm-pages",
                "fst-reloaded", "fst-ordinals", "fst-pages"}
    if not weather:
        required.update(("legacy-accepted", "wrong-prefix-empty", "contract-rejected"))
    if not required.issubset(checks) or contracts is None or not snapshot_bytes:
        raise ValueError("required checks or contracts are missing")
    compare("unchanged source", rows["source-after"], rows["source-before"])
    if len(rows["source-before"]) != len(source):
        raise ValueError("source count differs from the fixture")
    order = "tenant, device, time ASC, seq" if weather else "device, tenant, time DESC, seq"
    with closing(sqlite3.connect(":memory:")) as db:
        db.execute("CREATE TABLE records(tenant BLOB, device BLOB, time INTEGER, seq INTEGER, payload BLOB)")
        db.executemany("INSERT INTO records VALUES (?,?,?,?,?)", source)
        expected = db.execute(f"SELECT * FROM records ORDER BY {order}").fetchall()
        expected_matches = db.execute(
            f"SELECT * FROM records WHERE tenant=? AND device=? AND time>=? AND time<? ORDER BY {order}",
            query,
        ).fetchall()
    if len(expected_matches) != match_count:
        raise ValueError("SQLite fixture query count changed")
    target_rows = rows["target"]
    compare("target logical rows", [row[:5] for row in target_rows], expected)
    keys = [row[5] for row in target_rows]
    duplicates = len(keys) - len(set(keys))
    if duplicates or keys != sorted(keys):
        raise ValueError(f"target byte order or uniqueness failed, duplicates={duplicates}")
    by_row = {row[:5]: (row[5], row[4]) for row in target_rows}
    expected_range = [by_row[row] for row in expected_matches]
    compare("MoonLSM range", rows["match"], expected_range)
    compare("MoonFST range", rows["fst"], expected_range)
    return {
        "fixture": "NOAA GHCNd" if weather else "synthetic telemetry",
        "contracts_hex": contracts,
        "source_rows": len(source),
        "target_rows": len(target_rows),
        "duplicates": duplicates,
        "range_rows": match_count,
        "source_before_sha256": digest(rows["source-before"]),
        "source_after_sha256": digest(rows["source-after"]),
        "target_sha256": digest([(row[5], row[4]) for row in target_rows]),
        "range_sha256": digest(rows["match"]),
        "fst_range_sha256": digest(rows["fst"]),
        "snapshot_bytes": snapshot_bytes,
        "checks": checks,
    }


def write_report(path, report):
    # Replace the receipt atomically, including on a failing run.
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=path.parent, delete=False
    ) as stream:
        staged = Path(stream.name)
        json.dump(report, stream, indent=2)
        stream.write("\n")
    try:
        staged.replace(path)
    finally:
        staged.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, help="Write the receipt to an existing directory")
    args = parser.parse_args()
    report = {"ready": False, "backends": ["js", "wasm-gc"], "cases": [], "first_difference": None}
    for weather in (False, True):
        try:
            case = verify_case(weather)
        except (OSError, RuntimeError, ValueError, AssertionError, sqlite3.Error) as error:
            fixture = "NOAA GHCNd" if weather else "synthetic telemetry"
            report["first_difference"] = f"{fixture}: {error}"
            break
        report["cases"].append(case)
        print(f"{case['fixture']}: {case['target_rows']} rebuilt, {case['range_rows']} range rows.")
    report["ready"] = report["first_difference"] is None
    if args.report:
        write_report(args.report, report)
    if not report["ready"]:
        parser.exit(1, f"{report['first_difference']}\n")
    print("MoonLSM and reloaded MoonFST agree with SQLite on JS and Wasm GC.")


if __name__ == "__main__":
    main()
