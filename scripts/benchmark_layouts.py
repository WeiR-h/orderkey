"""Compare eight database rebuilds with one selected rebuild on 100,000 rows."""
import argparse
import hashlib
from itertools import permutations
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import time

from benchmark import peak_memory
from verify_cli import ROOT, contract, write_case
from verify_layouts import assert_measured, build_args, case_args, read_json, write_json


CANDIDATE_ORDERS = [
    (1, 0, 2, 3), (1, 2, 0, 3), (1, 2, 3, 0), (2, 0, 1, 3),
    (2, 1, 0, 3), (3, 0, 1, 2), (0, 2, 1, 3), (0, 3, 1, 2),
]


def directory_bytes(directory):
    total = 0
    for root, _, files in os.walk(directory):
        for name in files:
            try:
                total += (Path(root) / name).stat().st_size
            except FileNotFoundError:
                continue  # Engine metadata can be renamed during a sample.
    return total


def measure_child(argv, outputs):
    """Measure one child in a fresh process so RUSAGE_CHILDREN starts at zero."""
    with tempfile.TemporaryFile() as log:
        start = time.perf_counter()
        proc = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT)
        high_water = 0
        try:
            while proc.poll() is None:
                high_water = max(high_water, sum(directory_bytes(path) for path in outputs))
                if time.perf_counter() - start > 180:
                    raise TimeoutError("layout benchmark operation exceeded 180 seconds")
                time.sleep(0.025)
            elapsed = time.perf_counter() - start
            peak = peak_memory(proc)
            high_water = max(high_water, sum(directory_bytes(path) for path in outputs))
            if proc.returncode:
                log.seek(0)
                raise RuntimeError(log.read().decode("utf-8", errors="replace"))
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
    return elapsed, peak, high_water


def measure(argv, outputs):
    result = subprocess.check_output(
        [sys.executable, __file__, "--measure", json.dumps(list(map(str, argv))),
         json.dumps(list(map(str, outputs)))], text=True, timeout=200
    )
    return json.loads(result)


def fixture_rows():
    return [
        (f"t{n % 100}".encode(), f"d{n % 1000}".encode(), n - 50000, n % 3,
         hashlib.sha256(str(n).encode()).digest()[:16])
        for n in range(100000)
    ]


def fixture_queries():
    queries = []
    expected = {}
    for device in range(37, 47):
        query = {"id": f"device-{device}", "eq": {"device": {"bytes_hex": f"d{device}".encode().hex()}},
                 "max_target_scanned": 100, "page_size": 11}
        queries.append(query)
        expected[query["id"]] = (100, 100)
        if device < 42:
            window = {"field": "time", "lower": {"int64": "-50000"}, "upper": {"int64": "-45000"}}
            tenant = {"bytes_hex": f"t{device}".encode().hex()}
            exact = {**query, "id": f"history-{device}", "range": window,
                     "eq": {**query["eq"], "tenant": tenant}, "max_target_scanned": 5}
            residual = {**query, "id": f"fleet-window-{device}", "range": window}
            queries.extend((exact, residual))
            expected[exact["id"]] = (5, 5)
            expected[residual["id"]] = (100, 5)
    return queries, expected


def benchmark(exe, base):
    case = base / "input"
    args = write_case(case, fixture_rows())
    fields = contract(1)["fields"]
    assert set(CANDIDATE_ORDERS).issubset(permutations(range(4)))
    paths = []
    for ordinal, order in enumerate(CANDIDATE_ORDERS):
        candidate = contract(2)
        candidate["fields"] = [fields[i] for i in order]
        path = case / f"layout-{ordinal}.json"
        write_json(path, candidate)
        paths.append(path)
    queries, expected = fixture_queries()
    write_json(case / "layout-workload.json", {"schema_version": 1, "queries": queries})
    reference = base / "all-builds"
    reference.mkdir()
    baseline = []
    for i, path in enumerate(paths):
        print(f"Benchmark rebuild {i + 1}/{len(paths)}", flush=True)
        baseline.append(measure(
            [exe, "build", *args[:-4], "--target-contract", path, "--out", reference / str(i)],
            [reference],
        ))
    comparison = base / "comparison"
    selected = base / "selected"
    flags = [flag for path in paths for flag in ("--candidate", str(path))]
    compared = measure([exe, "compare-layouts", *case_args(case), *flags, "--out", comparison],
                       [comparison])
    assert {p.name for p in comparison.iterdir()} == {
        "comparison.json", "selection.json", "target.contract"
    }
    rebuilt = measure([exe, "build-selected", *build_args(case, comparison, selected)],
                      [comparison, selected])
    stats = read_json(comparison / "comparison.json")
    assert len(stats["layouts"]) == 9 and stats["rows"] == 100000
    source_scans = {q["id"]: q["scanned"] for q in stats["layouts"][0]["queries"]}
    assert source_scans["device-37"] == 100000
    receipt = read_json(selected / "selection-report.json")
    checked = assert_measured(stats, receipt)
    assert len(checked) == len(expected) == 20
    assert {key: (scanned, matches) for key, scanned, matches in checked} == expected
    run_queries = {q["id"]: q for q in receipt["workload"]["queries"]}
    assert len(list(reference.glob("*/db"))) == 8 and (selected / "db").is_dir()
    return {
        "ready": True, "rows": 100000, "target_layouts": 8, "queries": len(queries),
        "platform": platform.platform(),
        "metric_notes": "RSS is the largest child peak; disk is sampled output directory bytes "
                        "every 25 ms, including kept reference databases and temporary verification copies.",
        "rebuild_all": {
            "builds": 8, "seconds": sum(item[0] for item in baseline),
            "peak_rss_bytes": max(item[1] for item in baseline),
            "sampled_peak_output_bytes": max(item[2] for item in baseline),
        },
        "compare_then_build": {
            "builds": 1, "comparison_builds": 0, "seconds": compared[0] + rebuilt[0],
            "comparison_seconds": compared[0], "selected_build_and_workload_seconds": rebuilt[0],
            "peak_rss_bytes": max(compared[1], rebuilt[1]),
            "sampled_peak_output_bytes": max(compared[2], rebuilt[2]),
        },
        "workload": [
            {"id": key, "source_scanned": source_scans[key], "predicted": scanned,
             "moonlsm_scanned": run_queries[key]["target_scanned"],
             "moonfst_scanned": run_queries[key]["fst_scanned"], "matches": matches,
             "pagination_match": run_queries[key]["pagination_match"]}
            for key, scanned, matches in checked
        ],
    }


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "--measure":
        metrics = measure_child(json.loads(sys.argv[2]), list(map(Path, json.loads(sys.argv[3]))))
        print(json.dumps(metrics))
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--exe", type=Path,
                        default=ROOT / "_build/bin" / ("orderkey.exe" if os.name == "nt" else "orderkey"))
    args = parser.parse_args()
    write_json(args.report, {"ready": False})
    with tempfile.TemporaryDirectory(prefix="layout-benchmark-", dir=ROOT / "_build") as temp:
        report = benchmark(args.exe.resolve(), Path(temp))
    write_json(args.report, report)
    print(json.dumps(report, indent=2), flush=True)


if __name__ == "__main__":
    main()
