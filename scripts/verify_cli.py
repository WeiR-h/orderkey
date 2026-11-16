"""Independent cross-process acceptance tests for the native CLI."""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import random
import sqlite3
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]

def encode_bytes(value, desc=False):
    raw = value.replace(b"\0", b"\0\xff") + b"\0\0"
    return bytes(b ^ 255 for b in raw) if desc else raw

def key(values, fields):
    result = b""
    for value, field in zip(values, fields, strict=True):
        desc = field["direction"] == "desc"
        if field["kind"] == "bytes":
            result += encode_bytes(value, desc)
        else:
            raw = struct.pack(">Q", (value & ((1 << 64) - 1)) ^ (1 << 63))
            result += bytes(b ^ 255 for b in raw) if desc else raw
    return result

def contract(generation, weather=False):
    fields = [
        {"id":"tenant","kind":"bytes","direction":"asc"},
        {"id":"device","kind":"bytes","direction":"asc"},
        {"id":"time","kind":"int64","direction":"desc"},
        {"id":"seq","kind":"int64","direction":"asc"},
    ]
    if generation == 2:
        if weather:
            fields[2]["direction"] = "asc"
        else:
            fields[0], fields[1] = fields[1], fields[0]
    return {"index_id":"weather" if weather else "telemetry",
            "generation":str(generation),"fields":fields}

def dataset(weather):
    if weather:
        p = ROOT / "examples/moonlsm/fixtures/noaa-ghcnd-2024-q1.csv"
        assert hashlib.sha256(p.read_bytes()).hexdigest() == "8b95d0fc273a6af5b13593f9c5b51259304f1d212abe2cb3150c3d3f58094308"
        with p.open(encoding="ascii", newline="") as stream:
            return [(b"ghcnd", r["STATION"].encode(), int(r["DATE"].replace("-","")),0,
                     f"{r['TMAX']},{r['TMIN']}".encode()) for r in csv.DictReader(stream)]
    return [(f"t{n}".encode(),dev,t,seq,b"reading")
            for n in range(10) for dev in (b"pump",b"pump\0A",b"pump\0B",b"pump\xff",b"meter",b"valve",b"fan",b"edge")
            for t in range(-20,21) for seq in range(3)]

def write_case(base, rows, weather=False):
    base.mkdir()
    source, target = contract(1,weather), contract(2,weather)
    (base/"source.json").write_text(json.dumps(source),encoding="utf-8")
    (base/"target.json").write_text(json.dumps(target),encoding="utf-8")
    raw = [{"key_hex":key(row[:4],source["fields"]).hex(),"value_hex":row[4].hex()} for row in rows]
    random.Random(20261116).shuffle(raw)
    (base/"input.jsonl").write_text("".join(json.dumps(row)+"\n" for row in raw),encoding="utf-8")
    return ["--input",str(base/"input.jsonl"),"--source-contract",str(base/"source.json"),
            "--target-contract",str(base/"target.json"),"--out",str(base/"candidate")]

def run(exe, command, args, success=True):
    r = subprocess.run([str(exe),command,*args],capture_output=True,text=True,encoding="utf-8",timeout=180)
    if (r.returncode==0) != success:
        raise AssertionError(f"{command}: exit {r.returncode}\n{r.stdout}\n{r.stderr}")
    return r.stdout.strip()

def verify(exe, base, weather=False):
    rows = dataset(weather)
    args = write_case(base,rows,weather)
    run(exe,"plan",args)
    started=time.perf_counter()
    run(exe,"build",args)
    elapsed=time.perf_counter()-started
    out=base/"candidate"
    run(exe,"verify",["--out",str(out)])
    target=contract(2,weather)
    order = "tenant,device,time,seq" if weather else "device,tenant,time DESC,seq"
    with sqlite3.connect(":memory:") as db:
        db.execute("CREATE TABLE records(tenant BLOB,device BLOB,time INTEGER,seq INTEGER,value BLOB)")
        db.executemany("INSERT INTO records VALUES(?,?,?,?,?)",rows)
        expected=db.execute("SELECT * FROM records ORDER BY "+order).fetchall()
        query=(b"ghcnd",b"USW00094846",20240201,20240301) if weather else (b"t3",b"pump\0A",-2,4)
        selected=db.execute("SELECT * FROM records WHERE tenant=? AND device=? AND time>=? AND time<? ORDER BY "+order,query).fetchall()
    def transformed(row):
        values = row[:4] if weather else (row[1],row[0],row[2],row[3])
        return {"key_hex":key(values,target["fields"]).hex(),"value_hex":row[4].hex()}
    actual=[json.loads(line) for line in (out/"records.jsonl").read_text().splitlines()]
    assert actual == [transformed(row) for row in expected]
    prefix=encode_bytes(query[0])+encode_bytes(query[1]) if weather else encode_bytes(query[1])+encode_bytes(query[0])
    time_spec=[target["fields"][2]]
    low=key([query[2] if weather else query[3]-1],time_spec)
    high=key([query[3] if weather else query[2]-1],time_spec)
    q=["--out",str(out),"--start-hex",(prefix+low).hex(),"--end-hex",(prefix+high).hex(),"--limit","5"]
    pages=[]
    cursor=None
    while True:
        result=json.loads(run(exe,"query",q+(["--cursor",cursor] if cursor else [])))
        pages.extend(result["rows"])
        if len(result["rows"])<5:break
        cursor=result["cursor"]
    assert pages == [transformed(row) for row in selected]
    assert len(pages)==(29 if weather else 18)
    manifest=json.loads((out/"manifest.json").read_text())
    for name,digest in manifest["files"].items():
        assert hashlib.sha256((out/name).read_bytes()).hexdigest()==digest
    return {"case":"NOAA" if weather else "synthetic","rows":len(rows),"matches":len(pages),
            "elapsed_seconds":elapsed,"disk_bytes":sum(p.stat().st_size for p in out.rglob("*") if p.is_file()),
            "fst_bytes":(out/"target.fst").stat().st_size}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe",type=Path,default=ROOT/"_build/bin"/("orderkey.exe" if os.name=="nt" else "orderkey"))
    args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="orderkey-cli-", dir=ROOT / "_build") as temp:
        root=Path(temp)
        result=[verify(args.exe.resolve(),root/"synthetic"),verify(args.exe.resolve(),root/"weather",True)]
        print(json.dumps({"ready":True,"cases":result},indent=2))
if __name__=="__main__":
    main()
