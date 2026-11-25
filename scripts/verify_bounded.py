"""Replay two bounded approvals over the same frozen ComCat snapshot."""
import argparse
import hashlib
from itertools import combinations
import json
import os
from pathlib import Path
import sqlite3
import tempfile

from verify_cli import ROOT, key, run
from verify_batch import approved_args, gate_batch, sha
from verify_earthquakes import HIGH, LOW, frozen_events, write_lf_json
from verify_layouts import read_json, write_json
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
    for limit in (3, 4):
        name = f"workload-{limit}.json"
        workload = {"schema_version": 1, "queries": [
            {**query, "max_target_windows": limit, "max_target_scanned": 650, "page_size": 31},
        ]}
        for batch in ("training", "late"):
            write_lf_json(base / batch / name, workload)
        write_lf_json(base / f"batches-{limit}.json", {"schema_version": 1, "batches": [{
            "id": "late", "input": "late/input.jsonl", "source_contract": "late/source.json",
            "queries": "late/" + name,
        }]})
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
    workload = base / "workload.json"
    write_lf_json(workload, {"schema_version": 1, "queries": [{
        **read_json(where), "max_target_windows": 16, "max_target_scanned": 210, "page_size": 7,
    }]})
    report = base / "workload-report.json"
    run(exe, "check-queries", ["--out", str(candidate), "--queries", str(workload),
                              "--scan-mode", "bounded", "--report", str(report)])
    measured, = read_json(report)["queries"]
    assert measured["target_scanned"] == measured["fst_scanned"] == 208
    assert measured["results_match"] and measured["pagination_match"]
    empty_where = base / "empty.json"
    write_lf_json(empty_where, {"id": "none", "range": {
        "field": "time", "lower": {"int64": "10"}, "upper": {"int64": "11"},
    }})
    empty = preview(exe, candidate, empty_where, 16)
    assert empty["planned_scanned"] == empty["matched"] == 0 and empty["rank_windows"] == []
    return {"legacy_scanned": original["scanned"], "bounded": result,
            "moonlsm_scanned": measured["target_scanned"], "moonfst_scanned": measured["fst_scanned"]}


def verify_receipts(exe, base, case, candidate, expected, plans):
    selections = {}
    receipts = {}
    rows = []
    for limit, exit_code in ((3, 1), (4, 0)):
        train = case / "training"
        selection = base / f"selection-{limit}"
        run(exe, "compare-layouts", [
            "--input", str(train / "input.jsonl"), "--source-contract", str(train / "source.json"),
            "--queries", str(train / f"workload-{limit}.json"), "--candidate", str(train / "target.json"),
            "--out", str(selection),
        ])
        selections[limit] = selection
        out = base / f"gate-{limit}"
        receipts[limit] = gate_batch(exe, selection, case / f"batches-{limit}.json",
                                     "late", candidate, "bounded", out, exit_code)
        measured, = receipts[limit]["queries"]
        plan = plans[str(limit)]
        assert measured["max_target_windows"] == limit and measured["max_target_scanned"] == 650
        assert measured["rank_windows"] == plan["rank_windows"]
        assert measured["predicted_scanned"] == measured["target_scanned"] == measured["fst_scanned"]
        assert measured["target_scanned"] == plan["planned_scanned"] and measured["matched"] == 593
        assert measured["within_budget"] == (exit_code == 0)
        assert measured["results_match"] and measured["pagination_match"]
    assert receipts[3]["manifest_sha256"] == receipts[4]["manifest_sha256"] == sha(candidate / "manifest.json")
    assert receipts[3]["queries"][0]["ordered_result_sha256"] == receipts[4]["queries"][0]["ordered_result_sha256"]
    rejected = gate_batch(exe, selections[3], case / "batches-4.json", "late",
                          candidate, "bounded", base / "changed-window-budget", 2)
    assert "workload_sha256" in rejected["error"]
    gate_batch(exe, selections[4], case / "batches-4.json", "late",
               candidate, "single", base / "wrong-mode", 2)
    where = case / "where.json"
    receipt = base / "gate-4/batch-receipt.json"
    args = approved_args(candidate, receipt, where)
    first = json.loads(run(exe, "query-approved", args))
    page = first
    sizes, scanned = [], 0
    for _ in range(21):
        sizes.append(len(page["rows"]))
        rows.extend(page["rows"])
        scanned += page["scanned"]
        if not page["cursor"]:
            break
        page = json.loads(run(exe, "query-approved", args + ["--cursor", page["cursor"]]))
    assert sizes == [31] * 19 + [4] and scanned == 646
    fields = read_json(case / "late/target.json")["fields"]
    assert rows == [{"key_hex": key(row, fields).hex(), "value_hex": row[-1].hex()} for row in expected]
    payload_sha = hashlib.sha256("\n".join(row["value_hex"] for row in rows).encode()).hexdigest()
    result_sha = hashlib.sha256()
    for row in rows:
        for name in ("key_hex", "value_hex"):
            data = bytes.fromhex(row[name])
            result_sha.update(len(data).to_bytes(4, "big"))
            result_sha.update(data)
    assert result_sha.hexdigest() == receipts[4]["queries"][0]["ordered_result_sha256"]

    gate_batch(exe, selections[4], case / "batches-4.json", "late",
               candidate, "bounded", base / "other-approved", 0)
    other = base / "other-approved/batch-receipt.json"
    assert sha(receipt) != sha(other)
    other_args = approved_args(candidate, other, where)
    assert len(json.loads(run(exe, "query-approved", other_args))["rows"]) == 31
    run(exe, "query-approved", other_args + ["--cursor", first["cursor"]], success=False)
    run(exe, "query-approved", approved_args(candidate, base / "gate-3/batch-receipt.json", where),
        success=False)

    query, = receipts[4]["queries"]
    windows = query["rank_windows"]
    for index, changes in enumerate((
        {"rank_windows": [windows[0], *windows]},
        {"rank_windows": [[0, 1517]]},
        {"rank_windows": [*reversed(windows)]},
        {"rank_windows": [[windows[0][0], windows[0][1] - 1], *windows[1:]]},
        {"max_target_windows": 3},
    )):
        changed = base / f"bad-ranks-{index}.json"
        write_json(changed, {**receipts[4], "queries": [{**query, **changes}]})
        run(exe, "query-approved", approved_args(candidate, changed, where), success=False)
    return {
        "cap_3": receipts[3], "cap_4": receipts[4], "changed_budget_rejected": True,
        "cross_receipt_cursor_rejected": True, "sqlite_payload_sha256": payload_sha,
        "approved_page_sizes": sizes, "invalid_rank_receipts_rejected": 5,
    }


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
            "approval": verify_receipts(exe, base, case, candidate, expected, results),
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
    print("Dual-engine budgets: 673/650 rejected, 646/650 approved; 593 ordered results")


if __name__ == "__main__":
    main()
