"""Compare exact dual-budget layout predictions with an independent SQLite oracle."""
import argparse
import json
import os
from pathlib import Path
import shutil
import sqlite3
import tempfile

from verify_approved_consumer import copy_candidate
from verify_batch import approved_args, gate_batch, sha
from verify_bounded import comcat_case, exhaustive_minimum, read_global_week, sqlite_oracle
from verify_cli import ROOT, run
from verify_delivery import interrupt_selected_workload
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


def check_training_delivery(exe, path, selection, expected):
    digest = sha(selection / "selection.json")
    assert json.loads(run(exe, "verify-delivery", [
        "--out", str(path), "--selection-sha256", digest,
    ]))["rows"] == 1021
    receipt = read_json(path / "selection-report.json")
    assert receipt["ready"] and receipt["cutover_ready"] and receipt["schema_version"] == 2
    assert receipt["job"]["scan_mode"] == "bounded" and receipt["job"]["selection_sha256"] == digest
    assert (path / "selection.json").read_bytes() == (selection / "selection.json").read_bytes()
    assert receipt["predictions"] == read_json(selection / "selection.json")["predictions"]
    measured, = receipt["workload"]["queries"]
    assert measured["target_scanned"] == measured["fst_scanned"] == expected and measured["matched"] == 593
    assert measured["pagination_match"] and measured["results_match"]
    assert measured["bounded_scan"] == receipt["predictions"][0]["bounded_scan"]
    return measured


def verify_recovery(exe, base, training):
    cap3_selection = base / "selection-3"
    cap4_selection = base / "selection-4"
    cap3 = base / "train-cap-3"
    resumed = base / "train-cap-4"
    clean = base / "train-cap-4-clean"
    arguments = [*workload_args(training, 4), "--selection", str(cap4_selection)]
    build = [*arguments, "--out", str(resumed)]
    interrupt_selected_workload(exe, build)
    assert read_json(resumed / "report.json")["ready"]
    receipt = resumed / "selection-report.json"
    assert not read_json(receipt)["ready"]
    old = receipt.read_bytes()
    run(exe, "verify-delivery", ["--out", str(resumed)], success=False)

    # Each variant differs in just one approved input. No rejected resume may update the receipt.
    plan = cap4_selection / "selection.json"
    workload = training / "workload-4.json"
    target = cap4_selection / "target.contract"
    faulty = read_json(plan)
    faulty["scan_mode"] = "single"
    prediction = read_json(plan)
    prediction["predictions"][0]["scanned"] += 1
    changed_budget = read_json(workload)
    changed_budget["queries"][0]["max_target_windows"] = 3
    for path, data in ((plan, faulty), (plan, prediction), (workload, changed_budget), (target, b"{}")):
        before = path.read_bytes()
        try:
            if isinstance(data, bytes):
                path.write_bytes(data)
            else:
                write_json(path, data)
            run(exe, "build-selected", [*build, "--resume"], success=False)
            assert receipt.read_bytes() == old
        finally:
            path.write_bytes(before)
    run(exe, "build-selected", [*workload_args(training, 3), "--selection", str(cap3_selection),
                                "--out", str(resumed), "--resume"], success=False)
    assert receipt.read_bytes() == old
    run(exe, "build-selected", [*build, "--resume"])
    run(exe, "build-selected", [*arguments, "--out", str(clean)])
    run(exe, "build-selected", [*workload_args(training, 3), "--selection", str(cap3_selection),
                                "--out", str(cap3)])
    accepted = check_training_delivery(exe, resumed, cap4_selection, 613)
    fresh = check_training_delivery(exe, clean, cap4_selection, 613)
    three = check_training_delivery(exe, cap3, cap3_selection, 624)
    assert accepted["ordered_result_sha256"] == fresh["ordered_result_sha256"] == three["ordered_result_sha256"]
    assert (resumed / "records.jsonl").read_bytes() == (clean / "records.jsonl").read_bytes()

    portable = base / "portable-training"
    copy_candidate(resumed, portable)
    for name in ("selection.json", "selection-job.json", "selection-report.json"):
        shutil.copyfile(resumed / name, portable / name)
    check_training_delivery(exe, portable, cap4_selection, 613)
    copied = portable / "selection.json"
    copied.write_bytes(copied.read_bytes() + b"\n")
    run(exe, "verify-delivery", ["--out", str(portable)], success=False)
    shutil.copyfile(resumed / "selection.json", copied)
    measured_report = portable / "selection-report.json"
    corrupted = read_json(measured_report)
    corrupted["workload"]["queries"][0]["bounded_scan"]["rank_windows"] = [[0, 1]]
    write_json(measured_report, corrupted)
    run(exe, "verify-delivery", ["--out", str(portable)], success=False)
    return {"interrupted_and_resumed": True, "incomplete_delivery_rejected": True,
            "recovered_matches_clean": True, "changed_resumes_rejected": 5,
            "portable_delivery_verified": True, "tampered_delivery_rejected": True,
            "cap_3": three, "cap_4": accepted}


def verify_late(exe, base, case, events):
    late_index = base / "late-index"
    selection = base / "selection-4"
    run(exe, "build", ["--input", str(case / "late/input.jsonl"), "--source-contract",
                       str(case / "late/source.json"), "--target-contract",
                       str(selection / "target.contract"), "--out", str(late_index)])
    audits = {}
    for cap, expected, exit_code in ((3, [688, 673], 1), (4, [661, 646], 0)):
        chosen, batches = base / f"selection-{cap}", case / f"batches-{cap}.json"
        audit_dir = base / f"audit-{cap}"
        run(exe, "audit-layout", ["--selection", str(chosen), "--batches", str(batches),
                                 "--locked", "--scan-mode", "bounded", "--out", str(audit_dir)],
            success=(exit_code == 0))
        batch, = read_json(audit_dir / "audit-report.json")["batches"]
        assert [batch[name]["queries"][0]["scanned"] for name in ("source", "target")] == expected
        receipt = gate_batch(exe, chosen, batches, "late", late_index, "bounded",
                             base / f"cap-{cap}", exit_code)
        query, = receipt["queries"]
        assert query["target_scanned"] == query["fst_scanned"] == query["predicted_scanned"] == expected[1]
        assert query["max_target_windows"] == cap and query["max_target_scanned"] == 650
        assert query["matched"] == 593 and query["within_budget"] == (exit_code == 0)
        assert query["results_match"] and query["pagination_match"]
        training_ranks = read_json(chosen / "selection.json")["predictions"][0]["bounded_scan"]["rank_windows"]
        assert query["rank_windows"] != training_ranks
        audits[f"cap_{cap}"] = receipt
    assert audits["cap_3"]["manifest_sha256"] == audits["cap_4"]["manifest_sha256"]
    gate_batch(exe, base / "selection-3", case / "batches-4.json", "late", late_index,
               "bounded", base / "changed-late-budget", 2)
    gate_batch(exe, selection, case / "batches-4.json", "late", late_index, "single", base / "wrong-scan-mode", 2)
    receipt = base / "cap-4/batch-receipt.json"
    where = case / "where.json"
    expected, _ = sqlite_oracle(events)
    fields = read_json(case / "late/target.json")["fields"]
    cursor, sizes, payload_hash, result_hash = read_global_week(
        exe, approved_args(late_index, receipt, where), expected, fields)
    for cap in ("cap_3", "cap_4"):
        assert audits[cap]["queries"][0]["ordered_result_sha256"] == result_hash
    gate_batch(exe, selection, case / "batches-4.json", "late", late_index,
               "bounded", base / "other-approval", 0)
    other = base / "other-approval/batch-receipt.json"
    assert sha(other) != sha(receipt)
    other_args = approved_args(late_index, other, where)
    assert len(json.loads(run(exe, "query-approved", other_args))["rows"]) == 31
    run(exe, "query-approved", [*other_args, "--cursor", cursor], success=False)
    return {**audits, "approved_page_sizes": sizes, "sqlite_payload_sha256": payload_hash,
            "cross_receipt_cursor_rejected": True}


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
        proof["recovery"] = verify_recovery(exe, base, case / "training")
        proof["late"] = verify_late(exe, base, case, rows)
    write_json(args.report, proof)
    print("Bounded selection recovered; 673/650 rejected, 646/650 approved; 593 ordered results")


if __name__ == "__main__":
    main()
