"""Replay original predicates on one or several bounded index ranges."""
import argparse
import json
import os
from pathlib import Path
import tempfile

from verify_cli import ROOT, key, run
from verify_earthquakes import cases, compare_order
from verify_layouts import case_args, read_json, write_json


def rebuild(exe, case, target):
    run(exe, "build", [*case_args(case)[:4], "--target-contract", str(case / "target.json"),
                       "--out", str(target)])


def query_args(where, target, mode, page_size):
    return ["--out", str(target), "--where", str(where), "--limit", str(page_size),
            "--scan-mode", mode]


def pages(exe, args):
    rows, scanned, cursors = [], 0, set()
    cursor = []
    while True:
        page = json.loads(run(exe, "query", args + cursor))
        rows.extend(page["rows"])
        scanned += page["scanned"]
        token = page["cursor"]
        if not token:
            return rows, scanned, page.get("segmented_scan")
        assert token not in cursors
        cursors.add(token)
        cursor = ["--cursor", token]


def boundary_case(exe, base):
    base.mkdir()
    fields = [{"id": name, "kind": kind, "direction": direction} for name, kind, direction in (
        ("tenant", "bytes", "asc"), ("group", "bytes", "desc"), ("time", "int64", "asc"))]
    contract = {"index_id": "segment-boundary", "generation": "1", "fields": fields}
    write_json(base / "source.json", contract)
    write_json(base / "target.json", {**contract, "generation": "2"})
    query = {"id": "window", "eq": {"tenant": {"bytes_hex": "00"}},
             "range": {"field": "time", "lower": {"int64": "-1"}, "upper": {"int64": "2"}}}
    where = base / "where.json"
    write_json(where, query)

    def fixture(size):
        rows = [(b"\x00", b"\xff\x00" + bytes([i]), t) for i in range(size) for t in (-2, -1, 1, 2)]
        rows.append((b"\xff", b"other", 0))
        payload = lambda row: key(row, fields).hex()
        (base / "input.jsonl").write_text("".join(
            json.dumps({"key_hex": payload(row), "value_hex": payload(row)}) + "\n" for row in rows
        ), encoding="utf-8")
        target = base / str(size)
        rebuild(exe, base, target)
        args = query_args(where, target, "segmented", 3)
        actual, scanned, stats = pages(exe, args)
        expected = sorted(payload(row) for row in rows if row[0] == b"\x00" and -1 <= row[2] < 2)
        assert [r["value_hex"] for r in actual] == expected
        return args, scanned, stats

    args, scanned, stats = fixture(16)
    assert scanned == 32 and stats["ranges"] == 16 and stats["fallback"] is None
    cursor = json.loads(run(exe, "query", args))["cursor"]
    newer, scanned, stats = fixture(17)
    assert scanned == 68 and stats["fallback"] == "group_limit"
    run(exe, "query", [*newer, "--cursor", cursor], success=False)
    run(exe, "query", [*args[:-1], "single", "--cursor", cursor], success=False)
    plain = json.loads(run(exe, "query", [*args[:-1], "single"]))["cursor"]
    run(exe, "query", [*args, "--cursor", plain], success=False)
    write_json(where, {**query, "range": {**query["range"], "upper": {"int64": "-1"}}})
    assert pages(exe, args)[:2] == ([], 0)


def verify(exe, base):
    case = base / "earthquakes"
    records = cases(case)
    late, delivery = case / "late", base / "late-index"
    rebuild(exe, late, delivery)
    expected, single, _ = pages(exe, query_args(late / "where.json", delivery, "single", 7))
    actual, segmented, plan = pages(exe, query_args(late / "where.json", delivery, "segmented", 7))
    assert actual == expected and len(actual) == 33
    assert (single, segmented, plan["planned_scanned"], plan["ranges"]) == (71, 33, 33, 1)
    oracle = compare_order(exe, late, records["late"], delivery)
    boundary_case(exe, base / "boundary")
    return {"ready": True, "single_scanned": single, "segmented_scanned": segmented,
            "matched": len(actual), "sqlite_ordered_result_sha256": oracle, "plan": plan,
            "checks": ["cross-range-pagination", "descending-binary-groups", "group-limit",
                       "cross-mode-cursor", "cross-snapshot-cursor", "empty-interval"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    exe = ROOT / "_build/bin" / ("orderkey.exe" if os.name == "nt" else "orderkey")
    write_json(args.report, {"ready": False})
    with tempfile.TemporaryDirectory(prefix="segments-", dir=ROOT / "_build") as tmp:
        report = verify(exe, Path(tmp))
    write_json(args.report, report)
    print("Snapshot replay: 71 -> 33 with all 33 ordered results retained; 16/17 group bounds exercised")


if __name__ == "__main__":
    main()
