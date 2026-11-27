"""Check cross-batch selection against independently ordered ComCat records."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile

from verify_bounded import comcat_case, sqlite_oracle, write_export
from verify_bounded_selection import compare, sqlite_costs
from verify_cli import ROOT, run
from verify_earthquakes import HIGH, LOW, write_lf_json
from verify_layouts import read_json


def batch_entry(name, cap, *, directory=None):
    directory = directory or name
    return {"id": name, "input": f"{directory}/input.jsonl", "source_contract": "training/source.json",
            "queries": f"training/workload-{cap}.json"}


def write_batches(path, entries):
    write_lf_json(path, {"schema_version": 1, "batches": entries})


def make_batch_case(base):
    rows = comcat_case(base)
    source, target = (read_json(base / "training" / f"{name}.json") for name in ("source", "target"))
    through_two_weeks = LOW + 2 * (HIGH - LOW)
    write_export(base / "middle", [((net, kind, ms, id_), id_) for kind, net, ms, id_ in rows
                                  if LOW <= ms < through_two_weeks], source, target)
    for cap in (3, 4):
        write_batches(base / f"assessment-{cap}.json", [batch_entry(name, cap) for name in ("training", "middle")])
        write_batches(base / f"holdout-{cap}.json", [batch_entry("late", cap)])
    return rows


def compare_batches(exe, case, manifest, out, *, anchor="middle", success=True):
    result = json.loads(run(exe, "compare-batches", [
        "--batches", str(case / manifest), "--anchor", anchor,
        "--candidate", str(case / "training/target.json"), "--out", str(out),
    ], success=success))
    if success:
        assert result == read_json(out / "comparison-batches.json")
        assert {f.name for f in out.iterdir()} == {"comparison-batches.json"}
    else:
        assert not out.exists() and result["ready"] is False
    return result


def key_set_digest(path):
    keys = sorted(bytes.fromhex(json.loads(line)["key_hex"]) for line in path.read_bytes().splitlines())
    digest = hashlib.sha256()
    for key in keys:
        digest.update(len(key).to_bytes(4, "big"))
        digest.update(key)
    return digest.hexdigest()


def verify_batch_comparison(exe, root, case, rows):
    costs = sqlite_costs(rows)
    expected, _ = sqlite_oracle(rows)
    first = compare(exe, case / "training", 4, root / "single")
    assert first["status"] == "keep_source"
    comparisons = {}
    for cap in (3, 4):
        report = compare_batches(exe, case, f"assessment-{cap}.json", root / f"assessment-{cap}")
        assert report["status"] == "selected" and report["anchor"] == "middle"
        assert [(b["id"], b["rows"]) for b in report["batches"]] == [("middle", 1021), ("training", 599)]
        for batch in report["batches"]:
            assert batch["keys_sha256"] == key_set_digest(case / batch["id"] / "input.jsonl")
        for layout, middle_cost in zip(report["layouts"], costs["training"][cap], strict=True):
            middle, training = layout["batches"]
            measured = [b["queries"][0]["scanned"] for b in (middle, training)]
            assert measured == [middle_cost, len(expected)]
            for batch in (middle, training):
                query, = batch["queries"]
                assert query["matched"] == len(expected) and query["budget"] == 650
                assert query["max_target_windows"] == cap and query["window_count"] <= cap
                assert not query["order_changed"] and not query["failures"]
            assert layout["worst_batch"] == "middle" and layout["worst_weighted_scans"] == middle_cost
            assert layout["total_weighted_scans"] == sum(measured)
        comparisons[f"cap_{cap}"] = report

    blocked_manifest = case / "includes-late.json"
    write_batches(blocked_manifest, [batch_entry(name, 3) for name in ("middle", "late")])
    blocked = compare_batches(exe, case, blocked_manifest.name, root / "blocked")
    assert blocked["status"] == "no_feasible_candidate" and blocked["selected_contract_sha256"] is None
    for layout, late_cost in zip(blocked["layouts"], costs["late"][3], strict=True):
        query, = layout["batches"][1]["queries"]
        assert query["scanned"] == late_cost and query["failures"] == ["scan_budget"]

    tied_entries = [batch_entry("training", 4), {**batch_entry("empty", 4), "input": "empty.jsonl"}]
    (case / "empty.jsonl").write_bytes(b"")
    write_batches(case / "tie.json", tied_entries)
    assert compare_batches(exe, case, "tie.json", root / "tie", anchor="training")["status"] == "keep_source"

    # The lower total belongs to the target. Its worst batch still loses.
    workload = read_json(case / "training/workload-3.json")
    global_week, = workload["queries"]
    global_week["max_target_scanned"] = 700
    workload["queries"].append({**global_week, "id": "us-week", "eq": {"network": {"bytes_hex": "7573"}},
                                "max_target_scanned": 600, "max_target_windows": 1})
    write_lf_json(case / "worst-workload.json", workload)
    write_lf_json(case / "worst-policy.json", {"weights": {"us-week": 4}})
    write_batches(case / "worst.json", [{**batch_entry(name, 3), "queries": "worst-workload.json",
                                         "policy": "worst-policy.json"} for name in ("middle", "late")])
    worst = compare_batches(exe, case, "worst.json", root / "worst")
    assert worst["status"] == "keep_source"
    assert [(item["worst_weighted_scans"], item["total_weighted_scans"]) for item in worst["layouts"]] == [
        (2744, 5414), (2745, 5413)]

    # Reordered rows and a different payload still have the same scan key set.
    reordered = [json.loads(row) for row in reversed((case / "training/input.jsonl").read_bytes().splitlines())]
    reordered[0]["value_hex"] = "ab"
    (case / "duplicate.jsonl").write_text("".join(json.dumps(r) + "\n" for r in reordered),
                                         encoding="ascii", newline="\n")
    write_batches(case / "duplicate.json", [batch_entry("training", 4),
                                             {**batch_entry("alias", 4), "input": "duplicate.jsonl"}])
    repeated = compare_batches(exe, case, "duplicate.json", root / "duplicate", anchor="training", success=False)
    assert repeated["error"] == "batch alias reuses an assessed key set"
    write_batches(case / "changed.json", [batch_entry("training", 3), batch_entry("middle", 4)])
    changed = compare_batches(exe, case, "changed.json", root / "changed", success=False)
    assert changed["error"] == "batch training differs in source contract, workload, or policy"
    return {"ready": True, "single_batch_status": first["status"], "comparisons": comparisons,
            "blocked_before_build": blocked, "lower_total_loses_on_worst_batch": True,
            "reordered_key_set_rejected": True, "changed_workload_rejected": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    write_lf_json(args.report, {"ready": False})
    exe = ROOT / "_build/bin" / ("orderkey.exe" if os.name == "nt" else "orderkey")
    with tempfile.TemporaryDirectory(dir=ROOT / "_build", prefix="batch-selection-") as tmp:
        base = Path(tmp)
        case = base / "comcat"
        proof = verify_batch_comparison(exe, base, case, make_batch_case(case))
    write_lf_json(args.report, proof)
    print("Cross-batch selection agrees with SQLite and blocks the known over-budget layout before building")


if __name__ == "__main__":
    main()
