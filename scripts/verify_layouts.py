"""Exercise the native advisor, selected rebuild, and independent SQLite oracle."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile

from verify_cli import ROOT, contract, dataset, key, run, write_case


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def workload(weather=False, conflict=False):
    tenant = b"ghcnd" if weather else b"t3"
    device = b"USW00094846" if weather else b"pump\x00A"
    low, high = ("20240201", "20240301") if weather else ("-2", "4")
    queries = [
        {"id": "fleet", "eq": {"device": {"bytes_hex": device.hex()}},
         "max_target_scanned": 91 if weather else 1500},
        {"id": "history", "eq": {"tenant": {"bytes_hex": tenant.hex()},
                                "device": {"bytes_hex": device.hex()}},
         "range": {"field": "time", "lower": {"int64": low}, "upper": {"int64": high}},
         "max_target_scanned": 30 if weather else 18, "page_size": 5},
    ]
    if conflict:
        queries.append({"id": "tenant", "eq": {"tenant": {"bytes_hex": tenant.hex()}},
                        "max_target_scanned": 1000})
    return {"schema_version": 1, "queries": queries}


def case_args(case):
    return ["--input", str(case / "input.jsonl"), "--source-contract",
            str(case / "source.json"), "--queries", str(case / "layout-workload.json")]


def build_args(case, comparison, target):
    return [*case_args(case), "--selection", str(comparison), "--out", str(target)]


def compare(exe, case, path, extra):
    out = json.loads(run(exe, "compare-layouts", [*case_args(case), *extra, "--out", str(path)]))
    assert read_json(path / "comparison.json") == out
    expected = {"comparison.json"}
    if out["status"] == "selected":
        expected.update(("selection.json", "target.contract"))
    assert {file.name for file in path.iterdir()} == expected
    return out


def assert_measured(comparison, receipt):
    assert receipt["ready"] and receipt["cutover_ready"]
    selected = next(layout for layout in comparison["layouts"]
                    if layout["contract_sha256"] == comparison["selected_contract_sha256"])
    expected = [(q["id"], q["scanned"], q["matched"]) for q in selected["queries"]]
    measured = [(q["id"], q["target_scanned"], q["matched"])
                for q in receipt["workload"]["queries"]]
    assert expected == measured
    for query in receipt["workload"]["queries"]:
        assert query["results_match"] and query["pagination_match"]
        assert query["fst_scanned"] == query["target_scanned"]
    return expected


def sqlite_history(rows, weather):
    tenant, device = (b"ghcnd", b"USW00094846") if weather else (b"t3", b"pump\x00A")
    low, high = (20240201, 20240301) if weather else (-2, 4)
    with sqlite3.connect(":memory:") as db:
        db.execute("CREATE TABLE r(tenant BLOB, device BLOB, time INTEGER, seq INTEGER, value BLOB)")
        db.executemany("INSERT INTO r VALUES (?, ?, ?, ?, ?)", rows)
        return db.execute(
            """SELECT device, tenant, time, seq, value FROM r WHERE
               tenant=? AND device=? AND time>=? AND time<? ORDER BY time DESC,seq""",
            (tenant, device, low, high),
        ).fetchall()


def assert_sqlite(exe, case, target, rows, weather):
    where = case / "history.json"
    write_json(where, workload(weather)["queries"][1])
    cursor_args = []
    actual = []
    while True:
        page = json.loads(run(exe, "query", ["--out", str(target), "--where", str(where),
                                            "--limit", "5", *cursor_args]))
        actual.extend(page["rows"])
        if page["cursor"] is None:
            break
        cursor_args = ["--cursor", page["cursor"]]
    expected = [
        {"key_hex": key(row[:4], contract(2)["fields"]).hex(), "value_hex": row[4].hex()}
        for row in sqlite_history(rows, weather)
    ]
    assert actual == expected
    return len(expected)


def verify_layouts(exe, base):
    rows = dataset(False)
    case = base / "telemetry"
    legacy = write_case(case, rows)
    source_hash = hashlib.sha256((case / "input.jsonl").read_bytes()).hexdigest()
    workload_path = case / "layout-workload.json"
    policy = case / "layout-policy.json"
    write_json(workload_path, workload())
    write_json(policy, {"weights": {"fleet": 10}})
    compare_args = ["--auto", "--candidate", str(case / "target.json"), "--policy", str(policy)]
    selection = case / "comparison"
    comparison = compare(exe, case, selection, compare_args)
    assert compare(exe, case, case / "repeat", compare_args) == comparison
    assert len(comparison["layouts"]) == 2
    assert comparison["layouts"][0]["queries"][0]["scanned"] == 9840
    assert comparison["layouts"][1]["queries"][0]["scanned"] == 1230
    assert comparison["layouts"][1]["queries"][1]["matched"] == 18

    target = case / "selected"
    command = build_args(case, selection, target) + ["--policy", str(policy)]
    run(exe, "build-selected", [*command, "--fail-after", "snapshot"], success=False)
    assert read_json(target / "checkpoint.json")["phase"] == "snapshot"
    assert not read_json(target / "selection-report.json")["ready"]
    write_json(policy, {"weights": {"fleet": 11}})
    run(exe, "build-selected", [*command, "--resume"], success=False)
    write_json(policy, {"weights": {"fleet": 10}})
    with (case / "input.jsonl").open("ab") as file:
        file.write(b"\n")
    run(exe, "build-selected", [*command, "--resume"], success=False)
    input_file = case / "input.jsonl"
    input_file.write_bytes(input_file.read_bytes()[:-1])
    receipt = json.loads(run(exe, "build-selected", [*command, "--resume"]))
    expected = assert_measured(comparison, receipt)
    assert not list(target.glob("abandoned-db-*"))
    assert assert_sqlite(exe, case, target, rows, False) == 18

    # A cursor from the original field order cannot open the selected snapshot.
    source_clone = contract(3)
    clone_path = case / "source-layout.json"
    write_json(clone_path, source_clone)
    run(exe, "build", [*legacy[:-4], "--target-contract", str(clone_path), "--out", str(case / "candidate")])
    where = case / "history.json"
    old = json.loads(run(exe, "query", ["--out", str(case / "candidate"), "--where", str(where),
                                       "--limit", "5"]))["cursor"]
    run(exe, "query", ["--out", str(target), "--where", str(where), "--cursor", old], success=False)
    # Corrupt checked data, then demand a fresh verification.
    (target / "target.fst").write_bytes(b"truncated")
    run(exe, "build-selected", [*command, "--resume"], success=False)
    assert not read_json(target / "selection-report.json")["ready"]

    write_json(workload_path, workload(conflict=True))
    conflict = compare(exe, case, case / "conflict", ["--auto"])
    assert conflict["status"] == "no_feasible_candidate"
    assert all(not layout["eligible"] for layout in conflict["layouts"])
    assert all(any("scan_budget" in q["failures"] for q in layout["queries"])
               for layout in conflict["layouts"])
    write_json(workload_path, workload())
    changed = contract(2)
    changed["fields"][-1]["direction"] = "desc"
    changed_path = case / "changed-order.json"
    write_json(changed_path, changed)
    denied = compare(exe, case, case / "order-denied", ["--candidate", str(changed_path)])
    assert denied["status"] == "no_feasible_candidate"
    assert "order_changed" in denied["layouts"][1]["queries"][0]["failures"]
    write_json(policy, {"allow_order_change": ["fleet", "history"]})
    accepted = compare(exe, case, case / "order-allowed",
                       ["--candidate", str(changed_path), "--policy", str(policy)])
    assert accepted["status"] == "selected"
    write_json(policy, {"fixed_prefix": ["tenant"]})
    locked = compare(exe, case, case / "fixed-prefix",
                     ["--candidate", str(case / "target.json"), "--policy", str(policy)])
    assert "fixed_prefix" in locked["layouts"][1]["queries"][0]["failures"]
    tampered = case / "tampered"
    shutil.copytree(selection, tampered)
    plan = read_json(tampered / "selection.json")
    plan["predictions"][0]["scanned"] += 1
    write_json(tampered / "selection.json", plan)
    write_json(policy, {"weights": {"fleet": 10}})
    bad_output = case / "rejected"
    run(exe, "build-selected", [*build_args(case, tampered, bad_output),
                                "--policy", str(policy)], success=False)
    assert not bad_output.exists()
    assert hashlib.sha256(input_file.read_bytes()).hexdigest() == source_hash

    weather = base / "weather"
    weather_rows = dataset(True)
    write_case(weather, weather_rows, True)
    write_json(weather / "layout-workload.json", workload(True))
    weather_comparison = compare(exe, weather, weather / "comparison", ["--auto"])
    result = json.loads(run(exe, "build-selected",
                            build_args(weather, weather / "comparison", weather / "selected")))
    assert_measured(weather_comparison, result)
    assert assert_sqlite(exe, weather, weather / "selected", weather_rows, True) == 29
    return {
        "ready": True, "recipe": "rebuild only one selected layout",
        "telemetry": dict(expected=[list(item) for item in expected], source_scanned=9840),
        "conflict": conflict, "weather_history": 29,
        "checks": ["deterministic-deduplicated-selection", "fresh-input-digests",
                   "selected-checkpoint-resume", "cross-layout-cursor-refused",
                   "corrupted-snapshot-refused", "conflicting-budgets-explained",
                   "order-preservation-and-explicit-override", "fixed-prefix-enforced",
                   "tampered-prediction-refused", "sqlite-history-and-paging"],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--exe", type=Path, default=ROOT / "_build/bin/orderkey.exe")
    args = parser.parse_args()
    exe = args.exe
    if not exe.exists() and exe.name == "orderkey.exe":
        exe = exe.with_suffix("")
    write_json(args.report, {"ready": False})
    with tempfile.TemporaryDirectory(prefix="layout-verification-", dir=ROOT / "_build") as temp:
        result = verify_layouts(exe.resolve(), Path(temp))
    write_json(args.report, result)
    print("Layout acceptance passed. Telemetry 9840 -> 1230, weather 29, conflict correctly refused.")


if __name__ == "__main__":
    main()
