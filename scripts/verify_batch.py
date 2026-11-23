"""Gate an exact later-batch delivery against its locked workload."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

from verify_cli import ROOT
from verify_earthquakes import cases, compare_order
from verify_layouts import compare, read_json, write_json
from verify_segmented import rebuild


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def gate_batch(exe, selection, batches, batch_id, delivery, mode, out, expected):
    completed = subprocess.run([
        str(exe), "gate-batch", "--selection", str(selection),
        "--selection-sha256", sha(selection / "selection.json"),
        "--batches", str(batches), "--batch-id", batch_id,
        "--delivery", str(delivery), "--scan-mode", mode, "--out", str(out),
    ], capture_output=True, text=True, encoding="utf-8", timeout=180)
    assert completed.returncode == expected, (completed.stdout, completed.stderr)
    receipt = read_json(out / "batch-receipt.json")
    assert receipt == json.loads(completed.stdout)
    assert receipt["kind"] == "batch-delivery" and receipt["schema_version"] == 1
    assert receipt["ready"] == (expected == 0)
    assert receipt["status"] == {0: "passed", 1: "regression", 2: "invalid"}[expected]
    return receipt


def prepare_batches(exe, base):
    case = base / "earthquakes"
    records = cases(case)
    training = case / "training"
    selection = base / "selection"
    compare(exe, training, selection, ["--candidate", str(training / "target.json")])
    late, near = base / "late-index", base / "near-index"
    rebuild(exe, case / "late", late)
    rebuild(exe, case / "near", near)
    return case, records, selection, late, near


def verify(exe, base):
    case, records, selection, late, near = prepare_batches(exe, base)
    oracle = compare_order(exe, case / "late", records["late"], late)
    assert compare_order(exe, case / "near", records["near"], near) == oracle
    (late / "plan.json").unlink()
    batch_file = case / "late.json"
    input_path = case / "late/input.jsonl"
    original_hash = sha(input_path)
    single = gate_batch(exe, selection, batch_file, "late", late, "single", base / "single", 1)
    segmented = gate_batch(exe, selection, batch_file, "late", late, "segmented", base / "segmented", 0)
    for receipt, count in [(single, 71), (segmented, 33)]:
        query, = receipt["queries"]
        assert receipt["snapshot_rows"] == 1516, receipt
        assert receipt["manifest_sha256"] == sha(late / "manifest.json")
        assert receipt["digests"]["input_sha256"] == original_hash
        assert query["id"] == "ak-week"
        assert query["predicted_scanned"] == query["target_scanned"] == query["fst_scanned"] == count
        assert (query["matched"], query["max_target_scanned"], query["page_size"]) == (33, 50, 7)
        assert query["results_match"] and query["pagination_match"]
    assert single["queries"][0]["ordered_result_sha256"] == segmented["queries"][0]["ordered_result_sha256"]
    wrong = gate_batch(exe, selection, batch_file, "late", near, "segmented", base / "wrong", 2)
    assert "another frozen export" in wrong["error"]
    workload = case / "late/layout-workload.json"
    updated = read_json(workload)
    updated["queries"][0]["max_target_scanned"] = 100
    write_json(workload, updated)
    changed = gate_batch(exe, selection, batch_file, "late", late, "segmented", base / "changed", 2)
    assert "locked audit" in changed["error"]
    assert sha(input_path) == original_hash
    return {"ready": True, "single": single, "segmented": segmented,
            "wrong_delivery": wrong, "changed_budget": changed, "sqlite_payload_sha256": oracle}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    exe = ROOT / "_build/bin" / ("orderkey.exe" if os.name == "nt" else "orderkey")
    write_json(args.report, {"ready": False})
    with tempfile.TemporaryDirectory(prefix="batch-gate-", dir=ROOT / "_build") as tmp:
        result = verify(exe, Path(tmp))
    write_json(args.report, result)
    print("Exact late-batch delivery: single 71/50 rejected, segmented 33/50 passed")


if __name__ == "__main__":
    main()
