"""Run the NOAA application, collect its queries, and use the selected snapshot."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

from verify_cli import ROOT, run
from verify_layouts import read_json, write_json


def weather_app():
    subprocess.run(["moon", "build", "--release", "--target", "native",
                    "snapshot/examples/weather_capture"], cwd=ROOT, check=True, timeout=180)
    binary = "weather_capture.exe" if os.name == "nt" else "weather_capture"
    return ROOT / "_build/native/release/build/WeiR-h/orderkey_snapshot/examples/weather_capture" / binary


def call(app, *args):
    result = subprocess.check_output([str(app), *map(str, args)], text=True,
                                     encoding="utf-8", timeout=120)
    return json.loads(result.strip().splitlines()[-1])


def weather_flow(exe, app, csv, base):
    station = "USW00094846"
    paths = []
    cases = []
    for month, count, rows in (("202401", 31, 93), ("202402", 29, 87), ("all", 91, 273)):
        exported = base / ("export-" + month)
        trace = base / ("trace-" + month + ".jsonl")
        collected = base / ("queries-" + month)
        selection = base / ("selection-" + month)
        candidate = base / ("snapshot-" + month)
        dates = ("20240201", "20240301") if month == "all" else ()
        assert call(app, "export", csv, month, exported)["exported"] == rows
        assert len(call(app, "query", csv, month, station, trace)) == count
        expected = call(app, "query", csv, month, station, trace, *dates)
        assert len(expected) == (29 if dates else count)
        summary = json.loads(run(exe, "collect-queries",
            ["--trace", str(trace), "--source-contract", str(exported / "source.contract"),
             "--out", str(collected)]))
        query_count = 2 if dates else 1
        assert summary["events"] == 2 and summary["queries"] == query_count
        weights = read_json(collected / "policy.json")["weights"]
        assert sorted(weights.values()) == ([1, 1] if dates else [2])
        inputs = ["--input", str(exported / "input.jsonl"),
                  "--source-contract", str(exported / "source.contract"),
                  "--queries", str(collected / "workload.json"),
                  "--policy", str(collected / "policy.json")]
        compare = json.loads(run(exe, "compare-layouts", [*inputs, "--auto", "--out", str(selection)]))
        assert compare["status"] == "selected"
        run(exe, "build-selected", [*inputs, "--selection", str(selection), "--out", str(candidate)])
        run(exe, "verify-delivery", ["--out", str(candidate)])
        assert call(app, "query-selected", candidate, station, *dates) == expected
        cases.append({"month": month, "input_rows": rows, "query_rows": len(expected),
                      "captured_events": 2, "workload_queries": query_count})
        paths.append({"id": month, "input": str(exported / "input.jsonl"),
                      "source_contract": str(exported / "source.contract"),
                      "queries": str(collected / "workload.json"),
                      "policy": str(collected / "policy.json"), "selection": str(selection)})
    return cases, paths


def verify_capture(exe, app, base):
    csv = ROOT / "examples/moonlsm/fixtures/noaa-ghcnd-2024-q1.csv"
    cases, paths = weather_flow(exe, app, csv, base)
    source = paths[0]["source_contract"]
    trace = base / "canonical.jsonl"
    original = {"eq": {"device": {"bytes_hex": "AB"}, "tenant": {"bytes_hex": "CD"}},
                "page_size": 5, "max_target_scanned": 20}
    duplicate = {"eq": {"tenant": {"bytes_hex": "cd"}, "device": {"bytes_hex": "ab"}},
                 "page_size": 5, "max_target_scanned": 10}
    events = [original, duplicate, {**original, "page_size": 11}]
    def collect(name, entries, success=True):
        trace.write_text("".join(json.dumps(x) + "\n" for x in entries), encoding="utf-8")
        output = base / name
        run(exe, "collect-queries", ["--trace", str(trace), "--source-contract", source,
                                      "--out", str(output)], success=success)
        return output
    first = collect("canonical-one", events)
    second = collect("canonical-two", reversed(events))
    assert (first / "workload.json").read_bytes() == (second / "workload.json").read_bytes()
    queries = read_json(first / "workload.json")["queries"]
    assert sorted((q["page_size"], q["max_target_scanned"]) for q in queries) == [(5, 10), (11, 20)]
    assert sorted(read_json(first / "policy.json")["weights"].values()) == [1, 2]
    assert not collect("bad-field", [{"eq": {"time": {"bytes_hex": "ab"}}}], False).exists()
    too_many = [{"eq": {"seq": {"int64": str(i)}}} for i in range(101)]
    assert not collect("too-many", too_many, False).exists()
    return {"ready": True, "weather": cases, "checks": [
        "capture-from-query-call", "canonical-merge", "strictest-budget-and-frequency",
        "distinct-page-sizes", "reject-wrong-field-type", "reject-over-100-distinct",
        "selected-sdk-result-matches-original",
    ]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    write_json(args.report, {"ready": False})
    exe = ROOT / "_build/bin" / ("orderkey.exe" if os.name == "nt" else "orderkey")
    with tempfile.TemporaryDirectory(prefix="capture-", dir=ROOT / "_build") as tmp:
        result = verify_capture(exe, weather_app(), Path(tmp))
    write_json(args.report, result)
    print("Application captures reused as workload; January, February and 29-row history passed")


if __name__ == "__main__":
    main()
