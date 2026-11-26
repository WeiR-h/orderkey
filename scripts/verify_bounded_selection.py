"""Compare exact dual-budget layout predictions with an independent SQLite oracle."""
import argparse
import json
import os
from pathlib import Path
import sqlite3
import tempfile

from verify_batch import sha
from verify_bounded import comcat_case, exhaustive_minimum
from verify_cli import ROOT, run
from verify_earthquakes import HIGH, LOW
from verify_layouts import read_json, write_json


def workload_args(part, cap):
    return ["--input", str(part / "input.jsonl"), "--source-contract", str(part / "source.json"),
            "--queries", str(part / f"workload-{cap}.json")]


def compare(exe, part, cap, out, *, bounded=True, extra=()):
    args = [*workload_args(part, cap), "--candidate", str(part / "target.json"), "--out", str(out)]
    if bounded:
        args.extend(["--scan-mode", "bounded"])
    report = json.loads(run(exe, "compare-layouts", [*args, *extra]))
    assert report == read_json(out / "comparison.json")
    expected_files = {"comparison.json"}
    if report["status"] == "selected":
        expected_files.update(("selection.json", "target.contract"))
    assert {file.name for file in out.iterdir()} == expected_files
    return report


def sqlite_costs(rows):
    stop = LOW + 2 * (HIGH - LOW)
    result = {}
    with sqlite3.connect(":memory:") as db:
        db.execute("CREATE TABLE events(kind BLOB, network BLOB, ms INTEGER, id BLOB)")
        db.executemany("INSERT INTO events VALUES (?,?,?,?)", rows)
        for name, end in (("training", stop), ("late", LOW + 3 * (HIGH - LOW))):
            costs = {3: [], 4: []}
            for ordering in ("network, kind, ms DESC, id", "kind, network, ms DESC, id"):
                ordered = db.execute(f"SELECT kind, ms FROM events WHERE ms<? ORDER BY {ordering}", (end,))
                positions = [i for i, (kind, ms) in enumerate(ordered)
                             if kind == b"earthquake" and LOW <= ms < HIGH]
                assert len(positions) == 593
                for cap, values in costs.items():
                    values.append(exhaustive_minimum(positions, cap))
            result[name] = costs
    assert result == {"training": {3: [634, 624], 4: [623, 613]},
                      "late": {3: [688, 673], 4: [661, 646]}}
    return result


def verify_selection(exe, base, case, rows):
    costs = sqlite_costs(rows)
    training = case / "training"
    legacy = compare(exe, training, 4, base / "legacy", bounded=False)
    assert legacy["schema_version"] == 1 and legacy["status"] == "no_feasible_candidate"
    assert [item["queries"][0]["scanned"] for item in legacy["layouts"]] == [1021, 1011]
    selections = {}
    for cap, expected in costs["training"].items():
        out = base / f"selection-{cap}"
        report = compare(exe, training, cap, out)
        assert report["status"] == "selected" and report["rows"] == 1021
        assert report["schema_version"] == 2 and report["scan_mode"] == "bounded"
        assert [item["queries"][0]["scanned"] for item in report["layouts"]] == expected
        assert all(layout["eligible"] for layout in report["layouts"])
        plan = read_json(out / "selection.json")
        assert plan["schema_version"] == 2 and plan["scan_mode"] == "bounded"
        assert plan["digests"]["workload_sha256"] == sha(training / f"workload-{cap}.json")
        assert plan["target_contract_sha256"] == sha(out / "target.contract")
        chosen, = plan["predictions"]
        scan = chosen["bounded_scan"]
        assert chosen["max_target_scanned"] == 650 and chosen["matched"] == 593
        assert chosen["scanned"] == scan["planned_scanned"] == expected[1]
        assert scan["max_target_windows"] == len(scan["rank_windows"]) == cap
        assert sum(b - a for a, b in scan["rank_windows"]) == expected[1]
        selections[f"cap_{cap}"] = {"selection_sha256": sha(out / "selection.json"),
                                     "source_scanned": expected[0], "target_scanned": expected[1]}
    tie = base / "tie-fixture"
    comcat_case(tie)
    tied = compare(exe, tie / "training", 4, base / "tie")
    assert tied["status"] == "keep_source"
    assert [item["queries"][0]["scanned"] for item in tied["layouts"]] == [593, 593]
    policy = base / "fixed.json"
    write_json(policy, {"fixed_prefix": ["network"]})
    fixed = compare(exe, training, 4, base / "fixed", extra=["--policy", str(policy)])
    assert fixed["status"] == "keep_source" and "fixed_prefix" in fixed["layouts"][1]["queries"][0]["failures"]
    bad_budget = read_json(training / "workload-4.json")
    bad_budget["queries"][0]["max_target_scanned"] = 592
    budget_path = base / "unreachable.json"
    write_json(budget_path, bad_budget)
    args = [*workload_args(training, 4)[:4], "--queries", str(budget_path),
            "--candidate", str(training / "target.json"), "--scan-mode", "bounded"]
    result = json.loads(run(exe, "compare-layouts", [*args, "--out", str(base / "over-budget")]))
    assert result["status"] == "no_feasible_candidate"
    assert all("scan_budget" in layout["queries"][0]["failures"] for layout in result["layouts"])
    bad_budget["queries"][0].pop("max_target_windows")
    write_json(budget_path, bad_budget)
    run(exe, "compare-layouts", [*args, "--out", str(base / "missing-cap")], success=False)
    return {"ready": True, "training_rows": 1021, "legacy_status": legacy["status"],
            "legacy_scanned": [1021, 1011], "selections": selections, "sqlite_costs": costs}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    exe = ROOT / "_build/bin" / ("orderkey.exe" if os.name == "nt" else "orderkey")
    write_json(args.report, {"ready": False})
    with tempfile.TemporaryDirectory(prefix="bounded-selection-", dir=ROOT / "_build") as temp:
        base = Path(temp)
        case = base / "comcat"
        rows = comcat_case(case, training_weeks=2)
        proof = verify_selection(exe, base, case, rows)
    write_json(args.report, proof)
    print("Dual-budget advisor selected 624 and 613 candidates where the single scan rejected the layout")


if __name__ == "__main__":
    main()
