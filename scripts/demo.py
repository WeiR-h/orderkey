"""Record a real interrupted build, recovery and fresh-process query."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import subprocess
from verify_cli import ROOT, dataset, write_case, run

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe",type=Path,default=ROOT/"_build/bin"/("orderkey.exe" if os.name=="nt" else "orderkey"))
    parser.add_argument("--out",type=Path,required=True)
    args=parser.parse_args()
    args.out.mkdir(parents=True,exist_ok=False)
    case=args.out/"telemetry"
    command=write_case(case,dataset(False))
    before=hashlib.sha256((case/"input.jsonl").read_bytes()).hexdigest()
    exe=args.exe.resolve()
    process=subprocess.Popen([str(exe),"build",*command,"--pause-after","writing"],
                             stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding="utf-8")
    try:
        with concurrent.futures.ThreadPoolExecutor(1) as pool:
            first=pool.submit(process.stdout.readline).result(timeout=30).strip()
        if first!="paused writing": raise RuntimeError(first)
        process.kill()
        stdout,stderr=process.communicate(timeout=10)
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()
    recovery=run(exe,"resume",["--out",str(case/"candidate")])
    verified=run(exe,"verify",["--out",str(case/"candidate")])
    query=json.loads(run(exe,"query",["--out",str(case/"candidate"),"--limit","5"]))
    after=hashlib.sha256((case/"input.jsonl").read_bytes()).hexdigest()
    if before!=after or len(query["rows"])!=5: raise AssertionError("demo mismatch")
    result={"ready":True,"pause_observed":first,"terminated_process":process.pid,
            "terminated_exit_code":process.returncode,"recovery":recovery,"verification":verified,
            "source_before_sha256":before,"source_after_sha256":after,"query":query}
    (args.out/"interruption-demo.json").write_text(json.dumps(result,indent=2)+"\n",encoding="utf-8")
    print(json.dumps(result,indent=2))
if __name__=="__main__": main()
