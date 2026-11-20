"""Check the checksums and exercise a native ZIP from a clean directory."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import zipfile

from verify_audit import run_audit
from verify_capture import weather_flow
from verify_cli import run
from verify_layouts import assert_measured, build_args, case_args, compare, read_json, write_json


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
    return {"ready": True, "build": version, "cases": cases, "adoption": current,
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
