"""Pass portable batch artifacts between a producer and an isolated SDK consumer."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

from toolchain import ROOT, activate
from verify_batch import gate_batch, prepare_batches, sha
from verify_earthquakes import compare_order
from verify_layouts import read_json, write_json


EXE = "orderkey.exe" if os.name == "nt" else "orderkey"
CONSUMER = "approved-consumer.exe" if os.name == "nt" else "approved-consumer"


def copy_candidate(source, destination):
    (destination / "db").mkdir(parents=True)
    manifest = read_json(source / "manifest.json")
    for name in ("manifest.json", "report.json", *manifest["files"]):
        target = destination / name
        target.parent.mkdir(exist_ok=True, parents=True)
        shutil.copyfile(source / name, target)


def produce(handoff):
    handoff.mkdir()
    with tempfile.TemporaryDirectory(prefix="orderkey-producer-", dir=ROOT / "_build") as temp:
        base = Path(temp)
        exe = ROOT / "_build/bin" / EXE
        case, records, selection, late, near = prepare_batches(exe, base)
        expected = compare_order(exe, case / "late", records["late"], late)
        assert compare_order(exe, case / "near", records["near"], near) == expected
        assert sha(late / "manifest.json") != sha(near / "manifest.json")
        receipt = base / "approval/batch-receipt.json"
        gate_batch(exe, selection, case / "late.json", "late", late, "segmented", receipt.parent, 0)
        shutil.copyfile(receipt, handoff / receipt.name)
        write_json(handoff / "approval.json", {"receipt_sha256": sha(receipt), "sqlite_sha256": expected})
        copy_candidate(late, handoff / "late")
        copy_candidate(near, handoff / "near")


def compile_consumer(directory):
    version = re.search(r'version = "([^"]+)"', (ROOT / "moon.mod").read_text()).group(1)
    for command in (["moon", "package", "--list"], [sys.executable, "scripts/package_snapshot.py"]):
        subprocess.run(command, cwd=ROOT, check=True, timeout=180)
    app = directory / "app"
    shutil.copytree(ROOT / "snapshot/examples/approved", app)
    (app / "moon.mod").write_text(
        'name = "orderkey-tests/approved_consumer"\nversion = "0.0.1"\n'
        f'import {{ "WeiR-h/orderkey@{version}", "WeiR-h/orderkey_snapshot@{version}", "moonbitlang/async@0.22.9" }}\n',
        encoding="utf-8",
    )
    archives = {}
    for name, member in [("orderkey", "core"), ("orderkey_snapshot", "sdk")]:
        package = ROOT / "_build/publish" / f"WeiR-h-{name}-{version}.zip"
        with zipfile.ZipFile(package) as archive:
            archive.extractall(directory / member)
        archives[name] = sha(package)
    (directory / "moon.work").write_text('members = ["core", "sdk", "app"]\n', encoding="utf-8")
    subprocess.run(["moon", "build", "--target", "native", "."], cwd=app, check=True, timeout=240)
    name = "approved_consumer"
    candidates = list((directory / "_build/native/debug/build/orderkey-tests" / name).glob(name + "*"))
    binary, = [p for p in candidates if p.name in (name, name + ".exe")]
    return binary, archives


def consume(binary, handoff, directory):
    approval = read_json(handoff / "approval.json")
    receipt = handoff / "batch-receipt.json"
    common = [str(receipt), approval["receipt_sha256"]]
    result = directory / "consumer-output.json"
    with result.open("w", encoding="utf-8") as output:
        subprocess.run([str(binary), str(handoff / "late"), *common], cwd=directory,
                       stdout=output, check=True, timeout=30)
    accepted = read_json(result)
    assert accepted["ready"] and accepted["scanned"] == 33
    assert accepted["pages"] == [7, 7, 7, 7, 5]
    digest = hashlib.sha256("\n".join(accepted["values"]).encode()).hexdigest()
    assert digest == approval["sqlite_sha256"]
    denied = subprocess.run([str(binary), str(handoff / "near"), *common], cwd=directory,
                            capture_output=True, text=True, encoding="utf-8", timeout=30)
    assert denied.returncode == 1 and "snapshot manifest differs from batch receipt" in denied.stderr, denied
    assert sorted(p.name for p in handoff.iterdir()) == ["approval.json", "batch-receipt.json", "late", "near"]
    return {"ready": True, "boundary": "isolated producer process and packaged SDK consumer",
            "retained_outputs": sorted(p.name for p in handoff.iterdir()),
            "receipt_sha256": approval["receipt_sha256"], "ordered_payload_sha256": digest,
            "scanned": 33, "page_rows": accepted["pages"], "wrong_snapshot_rejected": True,
            "same_sqlite_result": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--produce", type=Path)
    mode.add_argument("--report", type=Path)
    args = parser.parse_args()
    if args.produce:
        produce(args.produce)
        return
    activate()
    write_json(args.report, {"ready": False})
    with tempfile.TemporaryDirectory(prefix="orderkey-approved-consumer-") as temp:
        directory = Path(temp)
        handoff = directory / "handoff"
        subprocess.run([sys.executable, __file__, "--produce", str(handoff)],
                       cwd=directory, check=True, timeout=180)
        binary, packages = compile_consumer(directory)
        report = consume(binary, handoff, directory)
        packaged = ROOT / "_build/bin" / CONSUMER
        shutil.copy2(binary, packaged)
        report["consumer_binary_sha256"] = sha(packaged)
        report["package_sha256"] = packages
    write_json(args.report, report)
    print("Isolated SDK consumer read 33 approved rows and rejected the same-result snapshot")


if __name__ == "__main__":
    main()
