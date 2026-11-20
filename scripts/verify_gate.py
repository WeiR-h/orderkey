"""Check the three public gate exit codes against real candidate directories."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

from verify_audit import cases
from verify_cli import ROOT, run
from verify_layouts import build_args, case_args, compare, read_json, write_json


def gate(exe, selection, approved, batches, delivery, out, code):
    result = subprocess.run([str(exe), "gate-selected", "--selection", str(selection),
                             "--selection-sha256", approved, "--batches", str(batches),
                             "--delivery", str(delivery), "--out", str(out)],
                            capture_output=True, text=True, encoding="utf-8", timeout=60)
    assert result.returncode == code, (result.returncode, result.stdout, result.stderr)
    report = read_json(out / "gate-report.json")
    assert report == json.loads(result.stdout) and report["ready"] == (code == 0)
    return report


def verify_gate(exe, base):
    _, holdout = cases(base)
    training = base / "training"
    selection, delivery = base / "selection", base / "delivery"
    compare(exe, training, selection, ["--candidate", str(training / "target.json")])
    approved = hashlib.sha256((selection / "selection.json").read_bytes()).hexdigest()
    batches = base / "batches.json"
    args = build_args(training, selection, delivery)
    with subprocess.Popen([str(exe), "build-selected", *args, "--pause-after", "selected-workload"],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                          encoding="utf-8") as process:
        with ThreadPoolExecutor(max_workers=1) as pool:
            try:
                assert pool.submit(process.stdout.readline).result(timeout=25).strip() == "paused selected-workload"
            finally:
                process.kill()
        process.communicate(timeout=10)
    rejected = gate(exe, selection, approved, batches, delivery, base / "interrupted", 2)
    assert rejected["stage"] == "delivery"
    run(exe, "build-selected", [*args, "--resume"])
    rejected = gate(exe, selection, approved, batches, delivery, base / "over-budget", 1)
    query, = rejected["batches"][0]["queries"]
    assert (query["predicted_scanned"], query["matched"], query["over_budget_by"]) == (1590, 180, 90)
    healthy = {k: v.replace("holdout", "healthy") for k, v in holdout.items()}
    write_json(batches, {"schema_version": 1, "batches": [healthy]})
    passed = gate(exe, selection, approved, batches, delivery, base / "passed", 0)
    assert passed["delivery_manifest_sha256"] == hashlib.sha256(
        (delivery / "manifest.json").read_bytes()).hexdigest()
    assert passed["training_measured_queries"][0]["scanned"] == 1230
    assert gate(exe, selection, "0" * 64, batches, delivery, base / "wrong-sha", 2)["stage"] == "selection"
    other = base / "healthy"
    other_selection, other_delivery = base / "other-selection", base / "other-delivery"
    compare(exe, other, other_selection, ["--candidate", str(other / "target.json")])
    run(exe, "build-selected", build_args(other, other_selection, other_delivery))
    run(exe, "verify-delivery", ["--out", str(other_delivery)])
    assert gate(exe, selection, approved, batches, other_delivery, base / "wrong-delivery", 2)["stage"] == "delivery"
    changed = read_json(base / healthy["queries"])
    changed["queries"][0]["max_target_scanned"] = 2000
    write_json(base / "loose.json", changed)
    write_json(batches, {"schema_version": 1, "batches": [{**holdout, "queries": "loose.json"}]})
    loosened = gate(exe, selection, approved, batches, delivery, base / "loose-budget", 2)
    assert "workload_sha256" in loosened["batches"][0]["error"]
    (delivery / "target.fst").write_bytes(b"corrupt")
    assert gate(exe, selection, approved, batches, delivery, base / "corrupt-artifact", 2)["stage"] == "delivery"
    return {"ready": True, "passed": passed, "regression": rejected, "changed_budget": loosened,
            "checks": ["process-interruption", "resume", "external-approved-hash",
                       "different-valid-delivery", "corrupt-snapshot", "locked-budget"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    write_json(args.report, {"ready": False})
    exe = ROOT / "_build/bin" / ("orderkey.exe" if os.name == "nt" else "orderkey")
    with tempfile.TemporaryDirectory(prefix="gate-", dir=ROOT / "_build") as temp:
        report = verify_gate(exe, Path(temp) / "cases")
    write_json(args.report, report)
    print("Gate exit codes verified: 0 approved, 1 forecast over budget, 2 invalid evidence")


if __name__ == "__main__":
    main()
