"""Exercise strict delivery across a real termination and a portable copy."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from verify_cli import ROOT, dataset, run, write_case
from verify_layouts import build_args, case_args, read_json, workload, write_json


def verify(exe, producer, directory):
    case = directory / "weather"
    write_case(case, dataset(True), True)
    write_json(case / "layout-workload.json", workload(True))
    selection, candidate = case / "plan", case / "candidate"
    run(producer, "compare-layouts", [*case_args(case), "--auto", "--out", str(selection)])
    args = build_args(case, selection, candidate)
    with subprocess.Popen(
        [str(producer), "build-selected", *args, "--pause-after", "selected-workload"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8",
    ) as proc:
        with ThreadPoolExecutor(max_workers=1) as pool:
            try:
                line = pool.submit(proc.stdout.readline).result(timeout=25)
                assert line.strip() == "paused selected-workload", line
            finally:
                proc.kill()
        proc.communicate(timeout=10)
    assert read_json(candidate / "report.json")["ready"]
    assert not read_json(candidate / "selection-report.json")["ready"]
    run(exe, "verify-delivery", ["--out", str(candidate)], success=False)
    run(producer, "build-selected", [*args, "--resume"])
    portable = directory / "portable"
    portable.mkdir()
    for name in ("report.json", "manifest.json", "selection-job.json", "selection-report.json"):
        shutil.copyfile(candidate / name, portable / name)
    manifest = read_json(candidate / "manifest.json")
    for name in manifest["files"]:
        path = portable / name
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(candidate / name, path)
    expected = hashlib.sha256((selection / "selection.json").read_bytes()).hexdigest()
    command = ["--out", str(portable), "--selection-sha256", expected]
    assert json.loads(run(exe, "verify-delivery", command))["rows"] == 273
    run(exe, "verify-delivery", [*command[:-1], "0" * 64], success=False)
    receipt = portable / "selection-report.json"
    original = receipt.read_bytes()
    receipt.unlink()
    run(exe, "verify-delivery", command, success=False)
    for change in ("results", "manifest", "generation"):
        receipt.write_bytes(original)
        data = read_json(receipt)
        if change == "results":
            data["workload"]["queries"][0]["results_match"] = False
        elif change == "manifest":
            data["workload"]["manifest_sha256"] = "0" * 64
        else:
            data["job"]["target_contract_sha256"] = "f" * 64
            write_json(portable / "selection-job.json", data["job"])
        write_json(receipt, data)
        run(exe, "verify-delivery", command, success=False)
    receipt.write_bytes(original)
    shutil.copyfile(candidate / "selection-job.json", portable / "selection-job.json")
    (portable / "target.fst").write_bytes(b"damaged")
    run(exe, "verify-delivery", command, success=False)
    return {"ready": True, "producer": json.loads(run(producer, "version", ["--json"])),
            "checks": ["terminated-before-workload", "resumed", "portable-copy",
                       "expected-selection", "missing-receipt", "failed-query",
                       "wrong-manifest", "wrong-target", "damaged-snapshot"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--producer", type=Path, help="Use a prior release to produce the snapshot")
    options = parser.parse_args()
    exe = ROOT / "_build/bin" / ("orderkey.exe" if os.name == "nt" else "orderkey")
    write_json(options.report, {"ready": False})
    with tempfile.TemporaryDirectory(prefix="delivery-", dir=ROOT / "_build") as tmp:
        report = verify(exe, options.producer or exe, Path(tmp))
    write_json(options.report, report)
    print("Delivery verified after resume; incomplete and mismatched copies rejected")


if __name__ == "__main__":
    main()
