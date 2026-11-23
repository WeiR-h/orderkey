"""Replay original predicates on one or several bounded index ranges."""
import argparse
import json
import os
from pathlib import Path
import tempfile

from verify_cli import ROOT, key, run
from verify_earthquakes import cases, compare_order
from verify_gate import gate
from verify_layouts import build_args, case_args, compare, read_json, write_json
import hashlib


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
    write_json(base / "queries.json", {"schema_version": 1, "queries": [
        {**query, "max_target_scanned": 40, "page_size": 3},
    ]})
    measurement = base / "group-limit-report.json"
    run(exe, "check-queries", ["--out", str(base / "17"), "--queries",
                              str(base / "queries.json"), "--scan-mode", "segmented",
                              "--report", str(measurement)], success=False)
    failure, = read_json(measurement)["queries"]
    assert failure["target_scanned"] == failure["fst_scanned"] == 68
    assert failure["segmented_scan"]["fallback"] == "group_limit" and not failure["within_budget"]
    run(exe, "query", [*newer, "--cursor", cursor], success=False)
    run(exe, "query", [*args[:-1], "single", "--cursor", cursor], success=False)
    plain = json.loads(run(exe, "query", [*args[:-1], "single"]))["cursor"]
    run(exe, "query", [*args, "--cursor", plain], success=False)
    write_json(where, {**query, "range": {**query["range"], "upper": {"int64": "-1"}}})
    assert pages(exe, args)[:2] == ([], 0)


def release_recovery(exe, base, case, late_delivery, result_sha):
    training, near, late = (case / name for name in ("training", "near", "late"))
    selection, delivery = base / "approved-selection", base / "approved-delivery"
    compare(exe, training, selection, ["--candidate", str(training / "target.json")])
    approved = hashlib.sha256((selection / "selection.json").read_bytes()).hexdigest()
    run(exe, "build-selected", build_args(training, selection, delivery))
    old = gate(exe, selection, approved, case / "late.json", delivery, base / "gate-single", 1)
    assert old["batches"][0]["queries"][0]["predicted_scanned"] == 71
    near_delivery = base / "near-index"
    rebuild(exe, near, near_delivery)
    records = []
    for folder, snapshot in [(near, near_delivery), (late, late_delivery)]:
        batch = folder.name
        batches = case / f"{batch}.json"
        passed = gate(exe, selection, approved, batches, delivery, base / f"gate-{batch}", 0, mode="segmented")
        assert passed["scan_mode"] == "segmented" and passed["selection_sha256"] == approved
        planned, = passed["batches"][0]["queries"]
        assert (planned["predicted_scanned"], planned["budget"], planned["matched"]) == (33, 50, 33)
        report = base / f"measured-{batch}.json"
        workspace = folder / "layout-workload.json"
        run(exe, "check-queries", ["--out", str(snapshot), "--queries", str(workspace),
                                   "--report", str(report), "--scan-mode", "segmented"])
        measured = read_json(report)
        assert measured["workload_sha256"] == hashlib.sha256(workspace.read_bytes()).hexdigest()
        actual, = measured["queries"]
        assert actual["target_scanned"] == actual["fst_scanned"] == planned["predicted_scanned"]
        assert measured["workload_passed"] and actual["results_match"] and actual["pagination_match"]
        rows, _, _ = pages(exe, query_args(folder / "where.json", snapshot, "segmented", 7))
        assert hashlib.sha256("\n".join(row["value_hex"] for row in rows).encode()).hexdigest() == result_sha
        records.append({"batch": batch, "forecast_scanned": planned["predicted_scanned"],
                        "moonlsm_scanned": actual["target_scanned"], "moonfst_scanned": actual["fst_scanned"],
                        "ordered_result_sha256": result_sha, "plan": actual["segmented_scan"]})
    output = base / "segmented-audit"
    run(exe, "audit-layout", ["--selection", str(selection), "--batches", str(case / "late.json"),
                              "--out", str(output), "--locked", "--scan-mode", "segmented"])
    assert read_json(output / "audit-report.json")["batches"][0]["target"]["queries"][0]["scanned"] == 33
    changed = read_json(late / "layout-workload.json")
    changed["queries"][0]["max_target_scanned"] = 100
    write_json(late / "layout-workload.json", changed)
    denied = gate(exe, selection, approved, case / "late.json", delivery, base / "gate-changed", 2, mode="segmented")
    assert denied["status"] == "invalid"
    return records


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
    measured = release_recovery(exe, base, case, delivery, oracle)
    return {"ready": True, "single_scanned": single, "segmented_scanned": segmented,
            "matched": len(actual), "sqlite_ordered_result_sha256": oracle, "plan": plan,
            "measured_batches": measured,
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
