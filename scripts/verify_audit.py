"""Verify a layout against another export, including a known scan regression."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import tempfile

from verify_cli import ROOT, dataset, run, write_case
from verify_layouts import case_args, read_json, write_json


def cases(base):
    base.mkdir()
    source = dataset(False)
    holdout = source + [
        (f"t{i}".encode(), b"pump\x00A", timestamp, seq, b"holdout")
        for i in range(10) for timestamp in range(21, 33) for seq in range(3)
    ]
    query = {
        "id": "fleet-window", "eq": {"device": {"bytes_hex": b"pump\x00A".hex()}},
        "range": {"field": "time", "lower": {"int64": "-2"}, "upper": {"int64": "4"}},
        "max_target_scanned": 1500, "page_size": 13,
    }
    for label, rows in (("training", source), ("holdout", holdout), ("healthy", source[:-1])):
        write_case(base / label, rows)
        write_json(base / label / "layout-workload.json", {"schema_version": 1, "queries": [query]})
    batch = {"id": "holdout", "input": "holdout/input.jsonl",
             "source_contract": "holdout/source.json", "queries": "holdout/layout-workload.json"}
    write_json(base / "batches.json", {"schema_version": 1, "batches": [batch]})
    return holdout, batch


def run_audit(exe, selection, batches, output, success, *, locked=False):
    run(exe, "audit-layout", ["--selection", str(selection), "--batches", str(batches),
                               "--out", str(output), *(["--locked"] if locked else [])], success=success)
    assert {f.name for f in output.iterdir()} == {"audit-report.json"}
    return read_json(output / "audit-report.json")


def verify_audit(exe, base):
    rows, batch = cases(base)
    training, holdout = base / "training", base / "holdout"
    selection = base / "selection"
    comparison = json.loads(run(exe, "compare-layouts", [
        *case_args(training), "--candidate", str(training / "target.json"),
        "--out", str(selection),
    ]))
    assert comparison["status"] == "selected"
    initial = comparison["layouts"][1]["queries"][0]
    assert (initial["scanned"], initial["matched"]) == (1230, 180)
    protected = [base / batch[k] for k in ("input", "source_contract", "queries")]
    protected.extend([selection / "selection.json", selection / "target.contract"])
    before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in protected}
    report = run_audit(exe, selection, base / "batches.json", base / "regression", False)
    assert report["status"] == "regression" and not report["ready"]
    entry = report["batches"][0]
    query = entry["target"]["queries"][0]
    assert (entry["source"]["queries"][0]["scanned"], query["scanned"], query["matched"]) == (10200, 1590, 180)
    assert query["failures"] == ["scan_budget"] and query["budget"] == 1500

    # Build the holdout separately to validate the prediction, including the residual filter.
    output = holdout / "db-verification"
    inputs = case_args(holdout)
    run(exe, "build", [*inputs[:4], "--target-contract", str(holdout / "target.json"),
                       "--out", str(output)])
    measured_report = base / "measured.json"
    run(exe, "check-queries", ["--out", str(output), "--queries", inputs[5],
                                "--report", str(measured_report)], success=False)
    observed = read_json(measured_report)["queries"][0]
    with sqlite3.connect(":memory:") as db:
        db.execute("CREATE TABLE r(tenant BLOB, device BLOB, time INTEGER, seq INTEGER, value BLOB)")
        db.executemany("INSERT INTO r VALUES (?, ?, ?, ?, ?)", rows)
        logical, = db.execute("SELECT count(*) FROM r WHERE device=? AND time>=? AND time<?",
                              (b"pump\x00A", -2, 4)).fetchone()
    assert observed["target_scanned"] == query["scanned"]
    assert observed["matched"] == logical == query["matched"]
    assert not observed["within_budget"] and observed["results_match"]

    batches = base / "batches.json"
    healthy = {k: (v.replace("holdout", "healthy") if isinstance(v, str) else v)
               for k, v in batch.items()}
    write_json(batches, {"schema_version": 1, "batches": [healthy]})
    passed = run_audit(exe, selection, batches, base / "passed", True)
    assert passed["status"] == "passed"
    write_json(batches, {"schema_version": 1, "batches": [healthy, batch]})
    mixed = run_audit(exe, selection, batches, base / "mixed", False)
    assert [r["status"] for r in mixed["batches"]] == ["passed", "regression"]
    write_json(base / "wrong-source.json", {**read_json(training / "source.json"), "generation": "2"})
    wrong = {**batch, "id": "wrong-generation", "source_contract": "wrong-source.json"}
    duplicate = {**batch, "id": "duplicate"}
    write_json(batches, {"schema_version": 1, "batches": [wrong, batch, duplicate]})
    invalid = run_audit(exe, selection, batches, base / "invalid", False)
    assert [r["status"] for r in invalid["batches"]] == ["invalid", "regression", "invalid"]
    assert {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in protected} == before
    write_json(batches, {"schema_version": 1, "batches": [healthy, batch]})
    locked = run_audit(exe, selection, batches, base / "locked", False, locked=True)
    assert [r["status"] for r in locked["batches"]] == ["passed", "regression"]
    workload = read_json(holdout / "layout-workload.json")
    q = workload["queries"][0]
    write_json(base / "policy.json", {"allow_order_change": [q["id"]]})
    for label, query in {
        "budget": {**q, "max_target_scanned": 2000},
        "predicate": {**q, "eq": {"device": {"bytes_hex": b"fan".hex()}}},
        "missing": {**q, "id": "replacement"},
        "policy": q,
    }.items():
        write_json(base / "changed.json", {**workload, "queries": [query]})
        changed = {**batch, "queries": "changed.json"}
        if label == "policy":
            changed["policy"] = "policy.json"
        write_json(batches, {"schema_version": 1, "batches": [changed]})
        if label == "budget":
            assert run_audit(exe, selection, batches, base / "unlocked-budget", True)["ready"]
        rejected = run_audit(exe, selection, batches, base / f"locked-{label}", False, locked=True)
        assert rejected["status"] == "invalid" and not rejected["ready"]
        digest = "policy_sha256" if label == "policy" else "workload_sha256"
        assert digest in rejected["batches"][0]["error"]
    return {"ready": True, "training_scanned": 1230, "holdout_scanned": 1590,
            "unchanged_matches": logical, "budget": 1500, "regression": report,
            "checks": ["zero-audit-databases", "full-batch-results", "wrong-contract",
                       "repeated-export", "source-unchanged", "measured-by-moonlsm-and-sqlite",
                       "locked-budget-predicate-query-policy"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    write_json(args.report, {"ready": False})
    exe = ROOT / "_build/bin" / ("orderkey.exe" if os.name == "nt" else "orderkey")
    with tempfile.TemporaryDirectory(prefix="audit-", dir=ROOT / "_build") as temp:
        report = verify_audit(exe, Path(temp) / "regression")
    write_json(args.report, report)
    print("Holdout scan 1590 > 1500; SQLite and both native engines agree on 180 matches")


if __name__ == "__main__":
    main()
