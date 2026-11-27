"""Measure eight candidate rebuilds versus cross-batch selection on three exports."""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import random
import tempfile

from benchmark_layouts import CANDIDATE_ORDERS, measure
from verify_batch import sha
from verify_batch_selection import write_batches
from verify_cli import ROOT, contract, write_case
from verify_layouts import read_json, write_json


SEED = 20261127
QUERIES = [
    {"id": "fleet", "eq": {"device": {"bytes_hex": b"d0001".hex()}},
     "page_size": 23, "max_target_scanned": 200, "max_target_windows": 4},
    {"id": "fleet-window", "eq": {"device": {"bytes_hex": b"d0017".hex()}},
     "range": {"field": "time", "lower": {"int64": "-50000"}, "upper": {"int64": "0"}},
     "page_size": 11, "max_target_scanned": 100, "max_target_windows": 4},
]


def bench_rows(batch):
    offset = random.Random(SEED + batch).randrange(1000)
    for ordinal in range(100000):
        tenant, slot = divmod(ordinal, 1000)
        device = (slot + offset) % 1000
        if device == 2 and tenant < batch * 25:
            device = 1
        timestamp = ordinal - 50000 + batch * 137
        value = hashlib.sha256(f"{SEED}/{batch}/{ordinal}".encode()).digest()[:16]
        yield f"t{tenant:03d}".encode(), f"d{device:04d}".encode(), timestamp, ordinal % 3, value


def summarize(metrics, builds):
    return {"builds": builds, "seconds": sum(item[0] for item in metrics),
            "peak_rss_bytes": max(item[1] for item in metrics),
            "sampled_peak_output_bytes": max(item[2] for item in metrics)}


def benchmark(exe, base):
    case, selected, all_builds = (base / name for name in ("case", "chosen-builds", "all-builds"))
    for directory in (case, selected, all_builds):
        directory.mkdir()
    workload = case / "workload.json"
    write_json(workload, {"schema_version": 1, "queries": QUERIES})
    batches, inputs, expected = [], [], []
    for batch in range(3):
        name = f"batch-{batch}"
        rows = list(bench_rows(batch))
        input_args = write_case(case / name, rows)
        inputs.append(input_args[:-4])
        batches.append({"id": name, "input": f"{name}/input.jsonl", "source_contract": f"{name}/source.json",
                        "queries": "workload.json"})
        expected.append([sum(r[1] == b"d0001" for r in rows),
                         sum(r[1] == b"d0017" and -50000 <= r[2] < 0 for r in rows)])
    manifest = case / "batches.json"
    write_batches(manifest, batches)
    targets = []
    fields = contract(1)["fields"]
    for position, order in enumerate(CANDIDATE_ORDERS):
        target = contract(2)
        target["fields"] = [fields[index] for index in order]
        path = case / f"layout-{position}.json"
        write_json(path, target)
        targets.append(path)

    plan = selected / "plan"
    flags = [flag for path in targets for flag in ("--candidate", path)]
    compared = measure([exe, "compare-batches", "--batches", manifest, "--anchor", batches[0]["id"],
                        *flags, "--out", plan], [selected])
    report = read_json(plan / "comparison-batches.json")
    assert report["status"] == "selected" and len(report["layouts"]) == 9
    assert {p.name for p in plan.iterdir()} == {
        "comparison-batches.json", "selection.json", "target.contract", "assessment.json"}
    assert not list(selected.rglob("db"))
    chosen, = [item for item in report["layouts"] if item["contract_sha256"] == report["selected_contract_sha256"]]

    build = selected / batches[0]["id"]
    timings = [compared, measure(
        [exe, "build-selected", *inputs[0], "--queries", workload, "--selection", plan,
         "--assessment-batches", manifest, "--assessment-sha256", sha(plan / "assessment.json"),
         "--out", build], [selected])]
    measured = [read_json(build / "selection-report.json")["workload"]]
    for batch in range(1, 3):
        output = selected / batches[batch]["id"]
        proof = selected / f"batch-{batch}-queries.json"
        timings.append(measure([exe, "build", *inputs[batch], "--target-contract", plan / "target.contract",
                                "--out", output], [selected]))
        timings.append(measure([exe, "check-queries", "--out", output, "--queries", workload,
                                "--scan-mode", "bounded", "--report", proof], [selected]))
        measured.append(read_json(proof))
    assert len(list(selected.glob("*/db"))) == 3
    verified = []
    for plan_batch, actual, counts in zip(chosen["batches"], measured, expected, strict=True):
        assert actual["cutover_ready"]
        checked_queries = []
        for predicted, readback, count in zip(plan_batch["queries"], actual["queries"], counts, strict=True):
            assert predicted["id"] == readback["id"]
            assert predicted["scanned"] == readback["target_scanned"] == readback["fst_scanned"] == count
            assert predicted["matched"] == readback["matched"] == count
            assert readback["pagination_match"] and readback["results_match"]
            checked_queries.append({"id": predicted["id"], "scanned_in_both_engines": count})
        verified.append({"id": plan_batch["id"], "queries": checked_queries})

    reference = []
    for batch, args in enumerate(inputs):
        for ordinal, target in enumerate(targets):
            print(f"Cross-batch benchmark rebuild {batch * len(targets) + ordinal + 1}/24", flush=True)
            reference.append(measure([exe, "build", *args, "--target-contract", target, "--out",
                                      all_builds / f"{batch}-{ordinal}"], [all_builds]))
    assert len(list(all_builds.glob("*/db"))) == 24
    return {"ready": True, "seed": SEED, "batches": 3, "records_per_batch": 100000, "candidates": 8,
            "platform": platform.platform(),
            "metric_notes": "Wall times aggregate runs. Selected runs include query verification. "
                            "Disk samples retain each run's outputs and include temporary verification copies.",
            "rebuild_all": summarize(reference, 24),
            "compare_then_build": {**summarize(timings, 3), "comparison_builds": 0,
                                   "comparison_seconds": compared[0], "comparison_peak_rss_bytes": compared[1],
                                   "comparison_output_bytes": compared[2]},
            "verified_queries": verified}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--exe", type=Path, default=ROOT / "_build/bin" /
                        ("orderkey.exe" if os.name == "nt" else "orderkey"))
    args = parser.parse_args()
    write_json(args.report, {"ready": False})
    with tempfile.TemporaryDirectory(prefix="batch-benchmark-", dir=ROOT / "_build") as temp:
        result = benchmark(args.exe.resolve(), Path(temp))
    write_json(args.report, result)
    print(f"Cross-batch benchmark completed {result['rebuild_all']['builds']} versus "
          f"{result['compare_then_build']['builds']} measured builds", flush=True)


if __name__ == "__main__":
    main()
