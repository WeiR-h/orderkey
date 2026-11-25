"""Rebuild the frozen ComCat export and check the bounded range planner."""
import argparse
from itertools import combinations
import json
import os
from pathlib import Path
import sqlite3
import tempfile

from verify_cli import ROOT, key, run
from verify_earthquakes import HIGH, LOW, frozen_events, write_lf_json
from verify_layouts import write_json
from verify_segmented import rebuild


def write_export(directory, rows, source, target):
    directory.mkdir()
    write_lf_json(directory / "source.json", source)
    write_lf_json(directory / "target.json", target)
    with (directory / "input.jsonl").open("w", encoding="ascii", newline="\n") as stream:
        for values, payload in rows:
            stream.write(json.dumps({
                "key_hex": key(values, source["fields"]).hex(), "value_hex": payload.hex(),
            }) + "\n")


def comcat_case(base):
    base.mkdir()
    rows = frozen_events()
    event_type, network, time, event_id = [
        {"id": name, "kind": kind, "direction": direction}
        for name, kind, direction in [
            ("event_type", "bytes", "asc"), ("network", "bytes", "asc"),
            ("time", "int64", "desc"), ("event_id", "bytes", "asc"),
        ]
    ]
    source = {"index_id": "comcat-bounded", "generation": "1",
              "fields": [network, event_type, time, event_id]}
    target = {**source, "generation": "2", "fields": [event_type, network, time, event_id]}
    for name in ("training", "late"):
        data = [((net, kind, ms, id_), id_) for kind, net, ms, id_ in rows
                if name == "late" or LOW <= ms < HIGH]
        write_export(base / name, data, source, target)
    query = {"id": "global-week", "eq": {"event_type": {"bytes_hex": b"earthquake".hex()}},
             "range": {"field": "time", "lower": {"int64": str(LOW)},
                       "upper": {"int64": str(HIGH)}}}
    write_lf_json(base / "where.json", query)
    return rows


def sqlite_oracle(rows):
    with sqlite3.connect(":memory:") as db:
        db.execute("CREATE TABLE events(kind BLOB, network BLOB, ms INTEGER, id BLOB)")
        db.executemany("INSERT INTO events VALUES (?,?,?,?)", rows)
        expected = db.execute(
            "SELECT kind, network, ms, id FROM events WHERE kind=? AND ms>=? AND ms<? "
            "ORDER BY kind, network, ms DESC, id", (b"earthquake", LOW, HIGH),
        ).fetchall()
        positions = db.execute(
            "SELECT rank FROM (SELECT ms, ROW_NUMBER() OVER "
            "(ORDER BY kind, network, ms DESC, id)-1 AS rank FROM events WHERE kind=?) "
            "WHERE ms>=? AND ms<? ORDER BY rank", (b"earthquake", LOW, HIGH),
        ).fetchall()
    return expected, [pos for pos, in positions]


def exhaustive_minimum(positions, limit):
    if not positions:
        return 0
    cuts = [b - a - 1 for a, b in zip(positions, positions[1:]) if b > a + 1]
    return positions[-1] + 1 - positions[0] - max(
        sum(removed) for removed in combinations(cuts, min(limit - 1, len(cuts)))
    )


def preview(exe, candidate, where, limit):
    return json.loads(run(exe, "plan-ranges", [
        "--out", str(candidate), "--where", str(where), "--max-windows", str(limit),
    ]))


def verify_high_cardinality(exe, base):
    fields = [{"id": "group", "kind": "bytes", "direction": "asc"},
              {"id": "time", "kind": "int64", "direction": "desc"}]
    source = {"index_id": "high-cardinality", "generation": "1", "fields": fields}
    data = [((bytes((i, 0, 255)), t), bytes((i, t))) for i in range(64) for t in range(4)]
    write_export(base, data, source, {**source, "generation": "2"})
    where = base / "where.json"
    write_lf_json(where, {"id": "time-one", "range": {
        "field": "time", "lower": {"int64": "1"}, "upper": {"int64": "2"},
    }})
    candidate = base / "snapshot"
    rebuild(exe, base, candidate)
    original = json.loads(run(exe, "query", ["--out", str(candidate), "--where", str(where),
                                            "--limit", "100", "--scan-mode", "segmented"]))
    assert original["segmented_scan"]["fallback"] == "group_limit"
    assert original["scanned"] == 256 and len(original["rows"]) == 64
    result = preview(exe, candidate, where, 16)
    assert (result["planned_scanned"], result["matched"], len(result["rank_windows"])) == (208, 64, 16)
    empty_where = base / "empty.json"
    write_lf_json(empty_where, {"id": "none", "range": {
        "field": "time", "lower": {"int64": "10"}, "upper": {"int64": "11"},
    }})
    empty = preview(exe, candidate, empty_where, 16)
    assert empty["planned_scanned"] == empty["matched"] == 0 and empty["rank_windows"] == []
    return {"legacy_scanned": original["scanned"], "bounded": result}


def verify(exe, base):
    case = base / "comcat"
    rows = comcat_case(case)
    candidate = base / "index"
    where = case / "where.json"
    rebuild(exe, case / "late", candidate)
    expected, positions = sqlite_oracle(rows)
    assert len(expected) == len(positions) == 593
    results = {}
    for limit, count in ((3, 673), (4, 646)):
        plan = preview(exe, candidate, where, limit)
        assert plan["single_scanned"] == plan["keys_examined"] == 1501
        assert plan["planned_scanned"] == exhaustive_minimum(positions, limit) == count
        assert plan["matched"] == 593 and len(plan["rank_windows"]) == limit
        assert all(any(a <= i < b for a, b in plan["rank_windows"]) for i in positions)
        assert sum(b - a for a, b in plan["rank_windows"]) == count
        results[str(limit)] = plan
    run(exe, "plan-ranges", ["--out", str(candidate), "--where", str(where),
                             "--max-windows", "17"], success=False)
    return {"ready": True, "snapshot_rows": len(rows), "comcat_plans": results,
            "high_cardinality": verify_high_cardinality(exe, base / "groups")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    exe = ROOT / "_build/bin" / ("orderkey.exe" if os.name == "nt" else "orderkey")
    write_json(args.report, {"ready": False})
    with tempfile.TemporaryDirectory(prefix="bounded-", dir=ROOT / "_build") as temp:
        report = verify(exe, Path(temp))
    write_json(args.report, report)
    print("Bounded plan: 3 intervals require 673 rows, 4 require 646, high cardinality 256 -> 208")


if __name__ == "__main__":
    main()
