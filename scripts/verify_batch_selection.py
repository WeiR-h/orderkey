"""Check cross-batch selection against independently ordered ComCat records."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile

from verify_approved_consumer import copy_candidate
from verify_bounded import comcat_case, read_global_week, sqlite_oracle, write_export
from verify_batch import approved_args, gate_batch, sha
from verify_bounded_selection import check_training_delivery, compare, sqlite_costs
from verify_cli import ROOT, run
from verify_delivery import interrupt_selected_workload
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
        expected = {"comparison-batches.json"}
        if result["status"] == "selected":
            expected.update(("target.contract", "selection.json", "assessment.json"))
            evidence = read_json(out / "assessment.json")
            anchor_entry, = [batch for batch in result["batches"] if batch["id"] == anchor]
            selected = read_json(out / "selection.json")
            assert evidence["schema_version"] == 1 and evidence["anchor"] == anchor
            assert evidence["batches_sha256"] == sha(case / manifest)
            assert evidence["batches"] == result["batches"]
            assert evidence["selection_sha256"] == sha(out / "selection.json")
            assert evidence["target_contract_sha256"] == sha(out / "target.contract")
            assert selected["schema_version"] == 2 and selected["digests"] == anchor_entry["digests"]
        assert {f.name for f in out.iterdir()} == expected
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
    holdout, withheld = case / "late/input.jsonl", root / "withheld.jsonl"
    holdout.rename(withheld)
    try:
        for cap in (3, 4):
            comparisons[f"cap_{cap}"] = compare_batches(exe, case, f"assessment-{cap}.json", root / f"assessment-{cap}")
    finally:
        withheld.rename(holdout)
    for cap in (3, 4):
        report = comparisons[f"cap_{cap}"]
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
            "holdout_unavailable_during_selection": True,
            "blocked_before_build": blocked, "lower_total_loses_on_worst_batch": True,
            "reordered_key_set_rejected": True, "changed_workload_rejected": True}


def assessed_build_args(case, selection, cap):
    return ["--input", str(case / "middle/input.jsonl"),
            "--source-contract", str(case / "training/source.json"),
            "--queries", str(case / f"training/workload-{cap}.json"),
            "--selection", str(selection), "--assessment-batches", str(case / f"assessment-{cap}.json"),
            "--assessment-sha256", sha(selection / "assessment.json")]


def verify_assessed_recovery(exe, root, case):
    selection = root / "assessment-4"
    resumed = root / "anchor-restored"
    clean = root / "anchor-clean"
    args = assessed_build_args(case, selection, 4)
    command = [*args, "--out", str(resumed)]
    skipped = run(exe, "build-selected", [*args[:-4], "--out", str(root / "missing-approval")], success=False)
    assert "assessed build requires" in skipped and not (root / "missing-approval").exists()
    interrupt_selected_workload(exe, command)
    receipt = resumed / "selection-report.json"
    old = receipt.read_bytes()
    assert not read_json(receipt)["ready"]
    denied = run(exe, "verify-delivery", ["--out", str(resumed)], success=False)
    assert json.loads(denied)["error"] == "selected workload is not ready for delivery"

    assessed_input = case / "training/input.jsonl"
    manifest = case / "assessment-4.json"
    evidence = selection / "assessment.json"
    copied = resumed / "assessment.json"
    mutations = [
        (assessed_input, b"".join(reversed(assessed_input.read_bytes().splitlines(keepends=True))),
         "assessed batch changed: training"),
        (manifest, manifest.read_bytes() + b"\n", "batch manifest differs"),
        (evidence, evidence.read_bytes() + b"\n", "assessment differs from approved"),
        (copied, copied.read_bytes() + b"\n", "delivered assessment differs"),
    ]
    for path, mutated, message in mutations:
        raw = path.read_bytes()
        try:
            path.write_bytes(mutated)
            report = run(exe, "build-selected", [*command, "--resume"], success=False)
            assert message in json.loads(report)["error"], report
            assert receipt.read_bytes() == old
        finally:
            path.write_bytes(raw)
    other = assessed_build_args(case, root / "assessment-3", 3)
    error = run(exe, "build-selected", [*other, "--out", str(resumed), "--resume"], success=False)
    assert json.loads(error)["error"] == "selected job identity differs" and receipt.read_bytes() == old

    run(exe, "build-selected", [*command, "--resume"])
    run(exe, "build-selected", [*args, "--out", str(clean)])
    accepted = check_training_delivery(exe, resumed, selection, 613)
    fresh = check_training_delivery(exe, clean, selection, 613)
    assert accepted["ordered_result_sha256"] == fresh["ordered_result_sha256"]
    assert (resumed / "records.jsonl").read_bytes() == (clean / "records.jsonl").read_bytes()
    assert copied.read_bytes() == evidence.read_bytes()
    assert read_json(receipt)["job"]["assessment_sha256"] == sha(evidence)

    raw = copied.read_bytes()
    try:
        copied.write_bytes(raw + b"\n")
        result = run(exe, "verify-delivery", ["--out", str(resumed)], success=False)
        assert json.loads(result)["error"] == "assessment differs from delivery receipt"
    finally:
        copied.write_bytes(raw)
    return {"interrupted": True, "incomplete_rejected": True, "matches_clean": True,
            "rejected_resumes": len(mutations) + 1, "corrupt_assessment_rejected": True,
            "assessment_sha256": sha(evidence), "measured": accepted}


def verify_assessed_holdout(exe, root, case, records):
    delivery = root / "late-index"
    options = [
        "--input", str(case / "late/input.jsonl"), "--source-contract", str(case / "training/source.json"),
        "--target-contract", str(root / "assessment-4/target.contract"), "--out", str(delivery),
    ]
    run(exe, "build", options)
    key_digest = key_set_digest(case / "late/input.jsonl")
    receipts = {}

    def gate(name, cap=4, status=0, *, manifest=None, batch="late", extra=None):
        selection = root / f"assessment-{cap}"
        if extra is None:
            extra = ["--assessment-sha256", sha(selection / "assessment.json")]
        return gate_batch(exe, selection, case / (manifest or f"holdout-{cap}.json"), batch,
                          delivery, "bounded", root / name, status, extra=extra)

    for cap, looked_up, status in ((3, 673, 1), (4, 646, 0)):
        receipt = gate(f"holdout-{cap}", cap, status)
        receipts[f"cap_{cap}"] = receipt
        assert receipt["assessment_sha256"] == sha(root / f"assessment-{cap}/assessment.json")
        assert receipt["holdout_keys_sha256"] == key_digest and receipt["snapshot_rows"] == 1516
        assert receipt["manifest_sha256"] == sha(delivery / "manifest.json")
        result, = receipt["queries"]
        assert result["target_scanned"] == result["fst_scanned"] == result["predicted_scanned"] == looked_up
        assert result["matched"] == 593 and result["max_target_windows"] == cap
        assert result["max_target_scanned"] == 650 and result["within_budget"] == (status == 0)
        assert result["results_match"] and result["pagination_match"]
        assert result["rank_windows"] != read_json(root / f"assessment-{cap}/selection.json")[
            "predictions"][0]["bounded_scan"]["rank_windows"]
    assert receipts["cap_3"]["manifest_sha256"] == receipts["cap_4"]["manifest_sha256"]
    assert "assessed gate requires" in gate("missing-assessment", status=2, extra=())["error"]
    assert "differs from approved SHA-256" in gate("bad-approval", status=2, extra=[
        "--assessment-sha256", "0" * 64])["error"]
    assert gate("changed-holdout-budget", 3, 2, manifest="holdout-4.json")["error"] == (
        "locked audit: workload_sha256 differs from selection")
    reused = gate("reused-assessment", status=2, manifest="duplicate.json", batch="alias")
    assert reused["error"] == "holdout reuses assessed key set: training" and reused["stage"] == "batch"
    fst = delivery / "target.fst"
    saved = fst.read_bytes()
    try:
        fst.write_bytes(saved[:-1])
        assert gate("damaged-holdout", status=2)["stage"] == "delivery"
    finally:
        fst.write_bytes(saved)

    # The consumer receives only a snapshot, a receipt, and an independent approved digest.
    saved_approval = root / "portable-approval.json"
    approved = root / "holdout-4/batch-receipt.json"
    shutil.copyfile(approved, saved_approval)
    portable = root / "portable-holdout"
    copy_candidate(delivery, portable)
    where = case / "where.json"
    expected, _ = sqlite_oracle(records)
    approved_query = approved_args(portable, saved_approval, where)
    fields = read_json(case / "training/target.json")["fields"]
    cursor, pages, payload, result = read_global_week(exe, approved_query, expected, fields)
    assert all(r["queries"][0]["ordered_result_sha256"] == result for r in receipts.values())
    wrong = approved_args(portable, root / "holdout-3/batch-receipt.json", where)
    assert "batch receipt is not approved" in run(exe, "query-approved", wrong, success=False)
    other = root / "other-approved/batch-receipt.json"
    gate(other.parent.name)
    assert sha(other) != sha(saved_approval)
    run(exe, "query-approved", [*approved_args(portable, other, where), "--cursor", cursor], success=False)
    return {**receipts, "approved_page_sizes": pages, "sqlite_payload_sha256": payload,
            "reused_key_set_rejected": True, "changed_budget_rejected": True,
            "corrupt_delivery_rejected": True, "unapproved_receipt_rejected": True,
            "cross_receipt_cursor_rejected": True, "portable_receipt_verified": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    write_lf_json(args.report, {"ready": False})
    exe = ROOT / "_build/bin" / ("orderkey.exe" if os.name == "nt" else "orderkey")
    with tempfile.TemporaryDirectory(dir=ROOT / "_build", prefix="batch-selection-") as tmp:
        base = Path(tmp)
        case = base / "comcat"
        records = make_batch_case(case)
        proof = verify_batch_comparison(exe, base, case, records)
        proof["recovery"] = verify_assessed_recovery(exe, base, case)
        proof["holdout"] = verify_assessed_holdout(exe, base, case, records)
    write_lf_json(args.report, proof)
    print("Cross-batch holdout: 673 rejected, 646 approved, 593 portable rows match SQLite")


if __name__ == "__main__":
    main()
