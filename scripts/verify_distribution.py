"""Check the checksums and exercise a native ZIP from a clean directory."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import zipfile

from verify_audit import run_audit
from verify_capture import weather_flow
from verify_cli import run
from verify_layouts import assert_measured, build_args, case_args, compare, read_json, write_json


def verify_gate_replay(root):
    started = time.perf_counter()
    args = ["cmd", "/d", "/c", "replay-gate.cmd"] if os.name == "nt" else ["sh", "replay-gate.sh"]
    subprocess.run([*args, "gate replay"], cwd=root, check=True, timeout=300,
                   encoding="utf-8", capture_output=True)
    out = root / "gate replay"
    approval = (root / "examples/earthquakes/approved.sha256").read_text(encoding="ascii").strip()
    passed = read_json(out / "near/gate-report.json")
    denied = read_json(out / "late/gate-report.json")
    assert passed["ready"] and not denied["ready"]
    assert passed["selection_sha256"] == denied["selection_sha256"] == approval
    assert passed["status"] == "passed" and denied["status"] == "regression"
    assert passed["training_measured_queries"][0]["scanned"] == 33
    assert read_json(out / "selection/comparison.json")["layouts"][0]["queries"][0]["scanned"] == 599
    for report, count in ((passed, 45), (denied, 71)):
        query, = report["batches"][0]["queries"]
        assert (query["predicted_scanned"], query["matched"], query["budget"]) == (count, 33, 50)
    assert read_json(out / "delivery-open.json")["ready"]
    return {"ready": True, "seconds": time.perf_counter() - started,
            "approved_selection_sha256": approval, "passed_scanned": 45,
            "rejected_scanned": 71, "matched": 33, "budget": 50}


def verify_current_cases(root, exe):
    weather = root / "examples/weather"
    app = root / ("weather_capture.exe" if os.name == "nt" else "weather_capture")
    if os.name != "nt":
        app.chmod(0o755)
    observations, batches = weather_flow(exe, app, weather / "noaa-ghcnd-2024-q1.csv", root)
    months = root / "months.json"
    write_json(months, {"schema_version": 1, "batches": [
        {k: v for k, v in entry.items() if k != "selection"} for entry in batches[:2]
    ]})
    audit = run_audit(exe, batches[-1]["selection"], months, root / "month-audit", True)
    assert [q["target"]["queries"][0]["matched"] for q in audit["batches"]] == [31, 29]

    # Strict read verifies a copied delivery after removing access to the inputs.
    shutil.copytree(root / "snapshot-all", root / "portable")
    (root / "export-all").rename(root / "export-removed")
    (root / "selection-all").rename(root / "selection-removed")
    assert json.loads(run(exe, "verify-delivery", ["--out", str(root / "portable")]))["ready"]

    regression = root / "examples/regression"
    training = regression / "training"
    selection = root / "fleet-selection"
    comparison = compare(exe, training, selection, ["--candidate", str(training / "target.json")])
    prediction = comparison["layouts"][1]["queries"][0]
    assert (prediction["scanned"], prediction["matched"]) == (1230, 180)
    holdout = run_audit(exe, selection, regression / "batches.json", root / "fleet-audit", False)
    query = holdout["batches"][0]["target"]["queries"][0]
    assert holdout["status"] == "regression"
    assert (query["scanned"], query["matched"], query["budget"]) == (1590, 180, 1500)
    return {"capture": observations, "month_audit": [31, 29], "portable_delivery": True,
            "holdout": {"training_scanned": 1230, "holdout_scanned": 1590,
                        "unchanged_matches": 180, "budget": 1500}}


def verify_segmented_replay(root):
    started = time.perf_counter()
    args = (["cmd", "/d", "/c", "replay-segmented.cmd"] if os.name == "nt" else
            ["sh", "replay-segmented.sh"])
    subprocess.run([*args, "segmented replay"], cwd=root, check=True, timeout=300,
                   encoding="utf-8", capture_output=True)
    out = root / "segmented replay"
    rejected = read_json(out / "baseline/late/gate-report.json")
    repaired = read_json(out / "repaired/gate-report.json")
    old, = rejected["batches"][0]["queries"]
    new, = repaired["batches"][0]["queries"]
    assert rejected["status"] == "regression" and repaired["ready"]
    assert rejected["selection_sha256"] == repaired["selection_sha256"]
    assert rejected["batches"][0]["digests"] == repaired["batches"][0]["digests"]
    assert (old["predicted_scanned"], new["predicted_scanned"]) == (71, 33)
    assert old["budget"] == new["budget"] == 50
    explanation = read_json(out / "diagnosis.json")["target"]
    assert explanation["blocking_field_id_hex"] == b"event_type".hex()
    receipt = read_json(out / "measured.json")
    measured, = receipt["queries"]
    read = read_json(out / "read.json")
    assert receipt["workload_passed"] and measured["pagination_match"]
    assert measured["target_scanned"] == measured["fst_scanned"] == read["scanned"] == 33
    order = hashlib.sha256("\n".join(row["value_hex"] for row in read["rows"]).encode()).hexdigest()
    expected = read_json(root / "verification/segmented-report.json")["sqlite_ordered_result_sha256"]
    assert len(read["rows"]) == 33 and order == expected and not read["cursor"]
    return {"ready": True, "seconds": time.perf_counter() - started, "single_scanned": 71,
            "segmented_scanned": 33, "budget": 50, "matched": 33, "result_sha256": order}


def verify_approved_replay(root, exe):
    started = time.perf_counter()
    windows = os.name == "nt"
    binary = root / ("approved-consumer.exe" if windows else "approved-consumer")
    consumer_report = read_json(root / "verification/approved-consumer-report.json")
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == consumer_report["consumer_binary_sha256"]
    if not windows:
        binary.chmod(0o755)
    args = ["cmd", "/d", "/c", "replay-approved.cmd"] if windows else ["sh", "replay-approved.sh"]
    run_result = subprocess.run([*args, "approval replay"], cwd=root, timeout=300,
                                encoding="utf-8", capture_output=True)
    assert run_result.returncode == 0, (run_result.stdout, run_result.stderr)
    out = root / "approval replay"
    single = read_json(out / "single/batch-receipt.json")
    approved_path = out / "segmented/batch-receipt.json"
    approved = read_json(approved_path)
    assert single["status"] == "regression" and approved["ready"]
    assert approved["status"] == "passed" and single["scan_mode"] == "single"
    assert approved["scan_mode"] == "segmented" and single["digests"] == approved["digests"]
    assert single["snapshot_rows"] == approved["snapshot_rows"] == 1516
    assert single["selection_sha256"] == approved["selection_sha256"]
    assert single["manifest_sha256"] == approved["manifest_sha256"]
    for receipt, count in [(single, 71), (approved, 33)]:
        query, = receipt["queries"]
        assert query["target_scanned"] == query["fst_scanned"] == query["predicted_scanned"] == count
        assert (query["max_target_scanned"], query["matched"]) == (50, 33)
    trusted = (out / "receipt.sha256").read_text(encoding="ascii").strip()
    assert hashlib.sha256(approved_path.read_bytes()).hexdigest() == trusted
    consumed = read_json(out / "consumer.json")
    actual = hashlib.sha256("\n".join(consumed["values"]).encode()).hexdigest()
    assert consumed["ready"] and consumed["pages"] == [7, 7, 7, 7, 5] and consumed["scanned"] == 33
    assert actual == consumer_report["ordered_payload_sha256"]
    near = json.loads(run(exe, "query", ["--out", str(out / "near-index"),
                                       "--where", str(root / "examples/earthquakes/near/where.json")]))
    assert consumed["values"] == [row["value_hex"] for row in near["rows"]]
    assert "snapshot manifest differs from batch receipt" in (out / "wrong.stderr").read_text(encoding="utf-8")
    return {"ready": True, "seconds": time.perf_counter() - started, "snapshot_rows": 1516,
            "single_scanned": 71, "segmented_scanned": 33, "budget": 50, "matched": 33,
            "page_rows": consumed["pages"], "wrong_snapshot_rejected": True,
            "receipt_sha256": trusted, "result_sha256": actual}


def check_bounded_receipts(out, expected):
    denied, passed = (read_json(out / f"cap-{limit}/batch-receipt.json") for limit in (3, 4))
    assert denied["status"] == "regression" and not denied["ready"]
    assert passed["status"] == "passed" and passed["ready"]
    assert denied["manifest_sha256"] == passed["manifest_sha256"]
    assert passed["manifest_sha256"] == hashlib.sha256((out / "late-index/manifest.json").read_bytes()).hexdigest()
    for limit, count, receipt in ((3, 673, denied), (4, 646, passed)):
        query, = receipt["queries"]
        measured, = expected[f"cap_{limit}"]["queries"]
        assert receipt["schema_version"] == 2 and receipt["scan_mode"] == "bounded"
        assert receipt["snapshot_rows"] == 1516 and receipt["selection_sha256"] == expected[f"cap_{limit}"]["selection_sha256"]
        assert query["predicted_scanned"] == query["target_scanned"] == query["fst_scanned"] == count
        assert (query["max_target_scanned"], query["max_target_windows"], query["matched"]) == (650, limit, 593)
        assert query["ordered_result_sha256"] == measured["ordered_result_sha256"]
        assert query["rank_windows"] == measured["rank_windows"]
    assert denied["queries"][0]["ordered_result_sha256"] == passed["queries"][0]["ordered_result_sha256"]
    approved = out / "cap-4/batch-receipt.json"
    other = out / "other-approval/batch-receipt.json"
    assert read_json(other)["ready"]
    trusted = (out / "receipt.sha256").read_text(encoding="ascii").strip()
    assert trusted == hashlib.sha256(approved.read_bytes()).hexdigest()
    assert trusted != hashlib.sha256(other.read_bytes()).hexdigest()
    consumer = read_json(out / "consumer.json")
    assert consumer["ready"] and consumer["scanned"] == 646
    assert consumer["pages"] == [31] * 19 + [4] and len(consumer["values"]) == 593
    assert consumer["cross_receipt_cursor_rejected"]
    digest = hashlib.sha256("\n".join(consumer["values"]).encode()).hexdigest()
    assert digest == expected["sqlite_payload_sha256"]
    return {"ready": True, "snapshot_rows": 1516,
            "cap_3_scanned": 673, "cap_4_scanned": 646, "budget": 650, "matched": 593,
            "receipts": {"rejected": denied, "approved": passed},
            "cross_receipt_cursor_rejected": True, "result_sha256": digest}


def verify_bounded_replay(root):
    started = time.perf_counter()
    args = ["cmd", "/d", "/c", "replay-bounded.cmd"] if os.name == "nt" else ["sh", "replay-bounded.sh"]
    replay = subprocess.run([*args, "bounded replay"], cwd=root, timeout=300,
                            encoding="utf-8", capture_output=True)
    assert replay.returncode == 0, (replay.stdout, replay.stderr)
    out = root / "bounded replay"
    expected = read_json(root / "verification/bounded-report.json")["approval"]
    return {**check_bounded_receipts(out, expected), "seconds": time.perf_counter() - started}


def verify_bounded_selection_replay(root):
    started = time.perf_counter()
    args = (["cmd", "/d", "/c", "replay-bounded-selection.cmd"] if os.name == "nt"
            else ["sh", "replay-bounded-selection.sh"])
    replay = subprocess.run([*args, "bounded selection replay"], cwd=root, timeout=300,
                            encoding="utf-8", capture_output=True)
    assert replay.returncode == 0, (replay.stdout, replay.stderr)
    out = root / "bounded selection replay"
    expected = read_json(root / "verification/bounded-selection-report.json")
    prior = read_json(out / "legacy/comparison.json")
    assert prior["status"] == "no_feasible_candidate"
    assert [item["queries"][0]["scanned"] for item in prior["layouts"]] == [1021, 1011]
    for cap, cost in ((3, [634, 624]), (4, [623, 613])):
        directory = out / f"selection-{cap}"
        picked = read_json(directory / "comparison.json")
        assert picked["status"] == "selected" and picked["scan_mode"] == "bounded"
        assert [item["queries"][0]["scanned"] for item in picked["layouts"]] == cost
        assert hashlib.sha256((directory / "selection.json").read_bytes()).hexdigest() == (
            expected["selections"][f"cap_{cap}"]["selection_sha256"])
    assert (out / "interruption.stdout").read_text(encoding="utf-8").strip() == "paused selected-workload"
    rejected = read_json(out / "incomplete.stdout")
    assert rejected == {"ready": False, "error": "selected workload is not ready for delivery"}, rejected
    strict = read_json(out / "training-ready.json")
    assert strict["ready"] and strict["cutover_ready"] and strict["rows"] == 1021
    training = out / "training-index"
    assert (training / "selection.json").read_bytes() == (out / "selection-4/selection.json").read_bytes()
    resumed = read_json(training / "selection-report.json")
    assert resumed["ready"] and resumed["cutover_ready"] and resumed["schema_version"] == 2
    assert resumed["job"]["scan_mode"] == "bounded"
    measured, = resumed["workload"]["queries"]
    reference = expected["recovery"]["cap_4"]
    for name in ("target_scanned", "fst_scanned", "matched", "bounded_scan", "ordered_result_sha256"):
        assert measured[name] == reference[name]
    return {**check_bounded_receipts(out, expected["late"]),
            "seconds": time.perf_counter() - started,
            "legacy_status": prior["status"], "training_rows": 1021, "training_scanned": measured["target_scanned"],
            "interrupted_and_resumed": True, "incomplete_delivery_rejected": True}


def verify_batch_selection_replay(root):
    started = time.perf_counter()
    command = (["cmd", "/d", "/c", "replay-batch-selection.cmd"] if os.name == "nt"
               else ["sh", "replay-batch-selection.sh"])
    replay = subprocess.run([*command, "batch selection replay"], cwd=root, timeout=300,
                            encoding="utf-8", capture_output=True)
    assert replay.returncode == 0, (replay.stdout, replay.stderr)
    out = root / "batch selection replay"
    expected = read_json(root / "verification/batch-selection-report.json")
    first = read_json(out / "first-week/comparison.json")
    assert first["status"] == expected["single_batch_status"] == "keep_source"
    assert (out / "interruption.stdout").read_text(encoding="utf-8").strip() == "paused selected-workload"
    assert read_json(out / "incomplete.stdout") == {
        "ready": False, "error": "selected workload is not ready for delivery"}
    for cap in (3, 4):
        selected = out / f"selection-{cap}"
        report = read_json(selected / "comparison-batches.json")
        assert report == expected["comparisons"][f"cap_{cap}"]
        assert {b["rows"] for b in report["batches"]} == {599, 1021}
        for artifact in ("selection", "assessment"):
            digest = hashlib.sha256((selected / f"{artifact}.json").read_bytes()).hexdigest()
            assert digest == expected["approvals"][f"cap_{cap}"][f"{artifact}_sha256"]
        receipt = read_json(out / f"cap-{cap}/batch-receipt.json")
        ref = expected["holdout"][f"cap_{cap}"]
        assert receipt["assessment_sha256"] == ref["assessment_sha256"]
        assert receipt["holdout_keys_sha256"] == ref["holdout_keys_sha256"]
        assessment = read_json(selected / "assessment.json")
        assert all(batch["keys_sha256"] != receipt["holdout_keys_sha256"] for batch in assessment["batches"])
    strict = read_json(out / "anchor-ready.json")
    assert strict["ready"] and strict["cutover_ready"] and strict["rows"] == 1021
    anchor = out / "anchor-index"
    assert (anchor / "assessment.json").read_bytes() == (out / "selection-4/assessment.json").read_bytes()
    resumed = read_json(anchor / "selection-report.json")
    assert resumed["ready"] and resumed["job"]["assessment_sha256"] == expected["recovery"]["assessment_sha256"]
    measured, = resumed["workload"]["queries"]
    for name in ("target_scanned", "fst_scanned", "matched", "bounded_scan", "ordered_result_sha256"):
        assert measured[name] == expected["recovery"]["measured"][name]
    return {**check_bounded_receipts(out, expected["holdout"]),
            "seconds": time.perf_counter() - started, "first_week_status": first["status"],
            "assessed_rows": [599, 1021], "anchor_scanned": measured["target_scanned"],
            "interrupted_and_resumed": True, "incomplete_delivery_rejected": True}


def verify_archive(path, parent):
    with tempfile.TemporaryDirectory(prefix="distribution-", dir=parent) as temp:
        root = Path(temp)
        with zipfile.ZipFile(path) as archive:
            archive.extractall(root)
        sums = dict(line.split("  ", 1)[::-1]
                    for line in (root / "SHA256SUMS.txt").read_text(encoding="utf-8").splitlines())
        assert set(sums) == {p.relative_to(root).as_posix() for p in root.rglob("*")
                             if p.is_file() and p.name != "SHA256SUMS.txt"}
        for name, expected in sums.items():
            assert hashlib.sha256((root / name).read_bytes()).hexdigest() == expected
        exe = root / ("orderkey.exe" if os.name == "nt" else "orderkey")
        if os.name != "nt":
            exe.chmod(0o755)
        version = json.loads(run(exe, "version", ["--json"]))
        acceptance = read_json(root / "verification/acceptance.json")
        assert acceptance["ready"] and acceptance["build"] == version and not version["dirty"]
        assert hashlib.sha256(exe.read_bytes()).hexdigest() == acceptance["binary_sha256"]
        gate_replay = verify_gate_replay(root)
        segmented_replay = verify_segmented_replay(root)
        approved_replay = verify_approved_replay(root, exe)
        bounded_replay = verify_bounded_replay(root)
        selected_proof = {}
        if tuple(map(int, version["version"].split("."))) >= (0, 1, 22):
            selected_proof["bounded_selection_replay"] = verify_bounded_selection_replay(root)
        if tuple(map(int, version["version"].split("."))) >= (0, 2, 0):
            selected_proof["batch_selection_replay"] = verify_batch_selection_replay(root)
        current = verify_current_cases(root, exe)
        cases = []
        for name, matches in (("telemetry", 18), ("weather", 29)):
            case = root / "examples" / name
            target = root / f"{name}-selected"
            if (case / "layout-workload.json").is_file():
                selection = root / f"{name}-plan"
                comparison = compare(exe, case, selection, ["--auto"])
                receipt = json.loads(run(exe, "build-selected", build_args(case, selection, target)))
                assert_measured(comparison, receipt)
                if name == "telemetry":
                    # Every attempt gets a fresh output directory.
                    (case / "layout-workload.json").write_bytes(
                        (case / "conflict-workload.json").read_bytes()
                    )
                    conflict = compare(exe, case, root / "conflict", ["--auto"])
                    assert conflict["status"] == "no_feasible_candidate"
            else:
                run(exe, "build", ["--input", str(case / "input.jsonl"),
                                   "--source-contract", str(case / "source.json"),
                                   "--target-contract", str(case / "target.json"),
                                   "--out", str(target)])
                run(exe, "verify", ["--out", str(target)])
            rows = json.loads(run(exe, "query", ["--out", str(target), "--where",
                                                 str(case / "where.json")]))["rows"]
            assert len(rows) == matches
            cases.append({"case": name, "rows": matches})
    return {"ready": True, "build": version, "cases": cases, "adoption": current, "gate_replay": gate_replay,
            "segmented_replay": segmented_replay, "approved_replay": approved_replay,
            "bounded_replay": bounded_replay, **selected_proof,
            "archive_sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    write_json(args.report, {"ready": False})
    result = verify_archive(args.archive.resolve(), args.report.resolve().parent)
    write_json(args.report, result)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
