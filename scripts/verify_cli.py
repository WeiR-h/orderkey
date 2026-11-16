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

def failure_checks(exe, root):
    rows = dataset(False)[:2050]
    cases = []
    for phase in ("writing","database","snapshot","verified","complete"):
        base=root/("fail-"+phase)
        args=write_case(base, rows)
        run(exe,"build",args+["--fail-after",phase],success=False)
        out=base/"candidate"
        assert json.loads((out/"report.json").read_text())["ready"] is False
        run(exe,"query",["--out",str(out)],success=False)
        run(exe,"resume",["--out",str(out)])
        run(exe,"verify",["--out",str(out)])
        cases.append(phase)
    for mode in ("write","sync"):
        base=root/("io-"+mode)
        args=write_case(base,rows)
        run(exe,"build",args+["--fail-io",mode],success=False)
        assert json.loads((base/"candidate/report.json").read_text())["ready"] is False
        run(exe,"resume",["--out",str(base/"candidate")])
        cases.append("io-"+mode)
    # Kill the actual process while it owns the lock and has partially written
    # the database. Restarting must rebuild this whole stage.
    base=root/"kill"
    args=write_case(base,rows)
    process=subprocess.Popen([str(exe),"build",*args,"--pause-after","writing"],
                             stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding="utf-8")
    try:
        import concurrent.futures
        with concurrent.futures.ThreadPoolExecutor(1) as pool:
            line=pool.submit(process.stdout.readline).result(timeout=30)
        assert line.strip()=="paused writing",line
        run(exe,"resume",["--out",str(base/"candidate")],success=False)
        process.kill()
        process.communicate(timeout=10)
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()
    run(exe,"resume",["--out",str(base/"candidate")])
    run(exe,"verify",["--out",str(base/"candidate")])
    fresh=root/"fresh"
    run(exe,"build",write_case(fresh,rows))
    for filename in ("records.jsonl","target.fst","source.contract","target.contract"):
        assert (base/"candidate"/filename).read_bytes()==(fresh/"candidate"/filename).read_bytes()
    cases.append("process-kill-and-exclusive-lock")
    (base/"input.jsonl").write_text("",encoding="utf-8")
    run(exe,"resume",["--out",str(base/"candidate")],success=False)
    assert json.loads((base/"candidate/report.json").read_text())["ready"] is False
    cases.append("changed-input")
    snapshot=fresh/"candidate/target.fst"
    snapshot.write_bytes(snapshot.read_bytes()[:10])
    run(exe,"verify",["--out",str(fresh/"candidate")],success=False)
    assert json.loads((fresh/"candidate/report.json").read_text())["ready"] is False
    run(exe,"resume",["--out",str(fresh/"candidate")],success=False)
    cases.append("truncated-snapshot")
    empty=root/"empty"
    run(exe,"build",write_case(empty,[]))
    run(exe,"verify",["--out",str(empty/"candidate")])
    assert json.loads(run(exe,"query",["--out",str(empty/"candidate")]))["rows"]==[]
    cases.append("empty-input")
    duplicate=root/"duplicate"
    args=write_case(duplicate,[rows[0],rows[0]])
    run(exe,"build",args,success=False)
    assert json.loads((duplicate/"candidate/report.json").read_text())["ready"] is False
    cases.append("duplicate-input")
    malformed=root/"malformed"
    args=write_case(malformed,rows[:1])
    (malformed/"input.jsonl").write_text('{"key_hex":"ff","value_hex":""}\n',encoding="utf-8")
    run(exe,"build",args,success=False)
    cases.append("malformed-key")
    binary=root/"binary-contract"
    args=write_case(binary,rows[:2])
    def contract_bytes(c):
        part=lambda b:struct.pack(">I",len(b))+b
        tags={("bytes","asc"):16,("bytes","desc"):17,("int64","asc"):32,("int64","desc"):33}
        layout=b"OK\x01"+bytes(tags[(f["kind"],f["direction"])] for f in c["fields"])
        return b"OKC\x01"+struct.pack(">Q",int(c["generation"]))+part(c["index_id"].encode())+part(layout)+b"".join(part(f["id"].encode()) for f in c["fields"])
    for name,generation in (("source",1),("target",2)):
        (binary/(name+".json")).write_bytes(contract_bytes(contract(generation)))
    run(exe,"build",args)
    run(exe,"verify",["--out",str(binary/"candidate")])
    # Every first byte is represented, including empty strings and escaped 00.
    edge=root/"edge"
    edge_rows=[(bytes([n]), b"\0\xff", -(1<<63) if n%2 else (1<<63)-1, n, bytes([n])) for n in range(256)]
    edge_args=write_case(edge,edge_rows)
    run(exe,"build",edge_args)
    run(exe,"verify",["--out",str(edge/"candidate")])
    assert len(json.loads(run(exe,"query",["--out",str(edge/"candidate"),"--limit","1000"]))["rows"])==256
    assert json.loads(run(exe,"query",["--out",str(edge/"candidate"),"--end-hex",""]))["rows"]==[]
    # An existing output must not be touched by a second build.
    previous=(edge/"candidate/report.json").read_bytes()
    run(exe,"build",edge_args,success=False)
    assert previous==(edge/"candidate/report.json").read_bytes()
    limit=root/"line-limit"
    limit_args=write_case(limit,[])
    (limit/"input.jsonl").write_bytes(b"x"*1048577)
    run(exe,"build",limit_args,success=False)
    cases.extend(("binary-contract","full-byte-keyspace","empty-range","existing-output","line-limit"))
    return cases


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe",type=Path,default=ROOT/"_build/bin"/("orderkey.exe" if os.name=="nt" else "orderkey"))
    parser.add_argument("--report",type=Path)
    args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="orderkey-中文-",dir=ROOT/"_build") as temp:
        root=Path(temp)
        report={"ready":False,"cases":[],"recovery_checks":[]}
        if args.report:
            args.report.write_text(json.dumps(report),encoding="utf-8")
        report["cases"]=[verify(args.exe.resolve(),root/"synthetic"),verify(args.exe.resolve(),root/"weather",True)]
        report["recovery_checks"]=failure_checks(args.exe.resolve(),root)
        report["ready"]=True
        if args.report:
            args.report.write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
        print(json.dumps(report,indent=2))
if __name__=="__main__":
    main()
