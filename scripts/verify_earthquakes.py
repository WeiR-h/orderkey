"""Rebuild three cumulative ComCat exports and verify the fixed query with SQLite."""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import tempfile

from verify_cli import ROOT, key, run
from verify_audit import run_audit
from verify_gate import gate
from verify_layouts import assert_measured, build_args, case_args, compare, read_json, write_json

CASE = ROOT / "examples/earthquakes"
LOW = 1711929600000  # 2024-04-01 UTC
HIGH = 1712534400000  # 2024-04-08 UTC
WEEK = HIGH - LOW
BATCHES = {"training": (599, 33), "near": (1021, 45), "late": (1516, 71)}


def write_lf_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8", newline="\n")


def cases(base):
    base.mkdir()
    raw = CASE / "events.tsv"
    assert hashlib.sha256(raw.read_bytes()).hexdigest() == (
        "7b62b108bc7154139ef794c5dcafcab153387dc3882d185168e234ae9a986cd8")
    with raw.open(encoding="ascii", newline="") as stream:
        rows = [(r["event_type"].encode(), r["network"].encode(),
                 int(r["time_ms"]), r["event_id"].encode())
                for r in csv.DictReader(stream, delimiter="\t")]
    fields = [{"id": name, "kind": kind, "direction": direction}
              for name, kind, direction in [
                  ("event_type", "bytes", "asc"), ("network", "bytes", "asc"),
                  ("time", "int64", "desc"), ("event_id", "bytes", "asc")]]
    source = {"index_id": "comcat", "generation": "1", "fields": fields}
    target = {**source, "generation": "2", "fields": [fields[1], fields[0], *fields[2:]]}
    query = {"id": "ak-week", "eq": {"network": {"bytes_hex": "616b"}},
             "range": {"field": "time", "lower": {"int64": str(LOW)}, "upper": {"int64": str(HIGH)}},
             "max_target_scanned": 50, "page_size": 7}
    by_batch = {}
    for week, name in enumerate(BATCHES, 1):
        directory = base / name
        directory.mkdir()
        records = [r for r in rows if LOW <= r[2] < LOW + WEEK * week]
        assert len(records) == BATCHES[name][0]
        by_batch[name] = records
        write_lf_json(directory / "source.json", source)
        write_lf_json(directory / "target.json", target)
        write_lf_json(directory / "layout-workload.json", {"schema_version": 1, "queries": [query]})
        write_lf_json(directory / "where.json", query)
        with (directory / "input.jsonl").open("w", encoding="utf-8", newline="\n") as stream:
            for row in records:
                stream.write(json.dumps({"key_hex": key(row, fields).hex(), "value_hex": row[-1].hex()}) + "\n")
        if name != "training":
            batch = {"id": name, "input": f"{name}/input.jsonl",
                     "source_contract": f"{name}/source.json", "queries": f"{name}/layout-workload.json"}
            write_lf_json(base / f"{name}.json", {"schema_version": 1, "batches": [batch]})
    return by_batch


def compare_order(exe, directory, source, target):
    with sqlite3.connect(":memory:") as db:
        db.execute("CREATE TABLE events(type BLOB, network BLOB, ms INTEGER, id BLOB)")
        db.executemany("INSERT INTO events VALUES (?,?,?,?)", source)
        expected = [event.hex() for event, in db.execute(
            "SELECT id FROM events WHERE network=? AND ms>=? AND ms<? ORDER BY type,ms DESC,id",
            (b"ak", LOW, HIGH))]
    actual, cursor = [], []
    args = ["--out", str(target), "--where", str(directory / "where.json"), "--limit", "7"]
    for _ in range(5):
        page = json.loads(run(exe, "query", args + cursor))
        actual.extend(r["value_hex"] for r in page["rows"])
        cursor = ["--cursor", page["cursor"]] if page["cursor"] else []
        if not cursor:
            break
    assert not cursor and len(actual) == 33 and actual == expected
    return hashlib.sha256("\n".join(actual).encode()).hexdigest()


def verify_earthquakes(exe, base):
    by_batch = cases(base)
    training = base / "training"
    selection, delivery = base / "selection", base / "delivery"
    comparison = compare(exe, training, selection, ["--candidate", str(training / "target.json")])
    assert comparison["layouts"][0]["queries"][0]["scanned"] == 599
    approved = hashlib.sha256((selection / "selection.json").read_bytes()).hexdigest()
    diagnostic = json.loads(run(exe, "explain", ["--where", str(training / "where.json"),
        "--source-contract", str(training / "source.json"), "--target-contract", str(training / "target.json")]))
    plan = diagnostic["target"]
    assert plan["prefix_field_ids_hex"] == [b"network".hex()]
    assert plan["blocking_field_id_hex"] == b"event_type".hex()
    assert plan["residual_field_ids_hex"] == [b"time".hex()]
    late = run_audit(exe, selection, base / "late.json", base / "late-diagnosis", False, locked=True)
    failure, = late["batches"][0]["target"]["queries"]
    assert (failure["scanned"], failure["residual_filtered"], failure["over_budget_by"]) == (71, 38, 21)
    receipt = json.loads(run(exe, "build-selected", build_args(training, selection, delivery)))
    assert assert_measured(comparison, receipt) == [("ak-week", 33, 33)]
    reports = []
    for name, (rows, scans) in BATCHES.items():
        directory = base / name
        target = delivery
        if name == "training":
            decision = "selected"
            measured = receipt["workload"]["queries"][0]
        else:
            expected = name == "near"
            check = gate(exe, selection, approved, base / f"{name}.json", delivery,
                         base / f"{name}-gate", 0 if expected else 1)
            decision = check["status"]
            assert check["batches"][0]["queries"][0]["predicted_scanned"] == scans
            target = directory / "target"
            run(exe, "build", [*case_args(directory)[:4], "--target-contract",
                               str(directory / "target.json"), "--out", str(target)])
            report_path = directory / "measured.json"
            run(exe, "check-queries", ["--out", str(target), "--queries",
                                       str(directory / "layout-workload.json"),
                                       "--report", str(report_path)], success=expected)
            measured = read_json(report_path)["queries"][0]
        assert measured["target_scanned"] == measured["fst_scanned"] == scans
        assert measured["matched"] == 33 and measured["results_match"] and measured["pagination_match"]
        reports.append({"batch": name, "rows": rows, "moonlsm_scanned": scans, "moonfst_scanned": scans,
                        "matched": 33, "budget": 50, "status": decision,
                        "ordered_result_sha256": compare_order(exe, directory, by_batch[name], target)})
    assert len({r["ordered_result_sha256"] for r in reports}) == 1
    return {"ready": True, "baseline_scanned": 599, "approved_selection_sha256": approved,
            "late_diagnosis": failure,
            "batches": reports}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    write_json(args.report, {"ready": False})
    exe = ROOT / "_build/bin" / ("orderkey.exe" if os.name == "nt" else "orderkey")
    with tempfile.TemporaryDirectory(prefix="comcat-", dir=ROOT / "_build") as temp:
        result = verify_earthquakes(exe, Path(temp) / "cases")
    write_json(args.report, result)
    print("ComCat: 599 -> 33 on selection, 45 PASS, 71 BLOCK; all 33 ordered matches agree")


if __name__ == "__main__":
    main()
