"""Measure one native build on a deterministic 100,000-record export."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import subprocess
import tempfile
import time
from verify_cli import ROOT, write_case, contract, key, run

def peak_memory(process):
    if os.name != "nt":
        import resource
        return resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss * (1 if platform.system()=="Darwin" else 1024)
    from ctypes import wintypes
    class Counters(ctypes.Structure):
        _fields_=[("cb",wintypes.DWORD),("PageFaultCount",wintypes.DWORD)]+[
            (name,ctypes.c_size_t) for name in (
                "PeakWorkingSetSize","WorkingSetSize","QuotaPeakPagedPoolUsage","QuotaPagedPoolUsage",
                "QuotaPeakNonPagedPoolUsage","QuotaNonPagedPoolUsage","PagefileUsage","PeakPagefileUsage")]
    counters=Counters()
    counters.cb=ctypes.sizeof(counters)
    call=ctypes.windll.psapi.GetProcessMemoryInfo
    call.argtypes=[wintypes.HANDLE,ctypes.POINTER(Counters),wintypes.DWORD]
    call.restype=wintypes.BOOL
    if not call(wintypes.HANDLE(int(process._handle)),ctypes.byref(counters),counters.cb):
        raise ctypes.WinError()
    return counters.PeakWorkingSetSize

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--exe",type=Path,default=ROOT/"_build/bin"/("orderkey.exe" if os.name=="nt" else "orderkey"))
    p.add_argument("--report",type=Path,required=True)
    args=p.parse_args()
    args.report.write_text('{"ready":false}\n',encoding="utf-8")
    # This process launches exactly one child before reading RUSAGE_CHILDREN.
    rows=[(f"t{n%100}".encode(),f"d{n%1000}".encode(),n-50000,n%3,
           hashlib.sha256(str(n).encode()).digest()[:16]) for n in range(100000)]
    with tempfile.TemporaryDirectory(prefix="orderkey-benchmark-",dir=ROOT/"_build") as temp:
        base=Path(temp)/"case"
        command=write_case(base,rows)
        start=time.perf_counter()
        proc=subprocess.Popen([str(args.exe.resolve()),"build",*command],
                              stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding="utf-8")
        stdout,stderr=proc.communicate(timeout=300)
        elapsed=time.perf_counter()-start
        if proc.returncode: raise RuntimeError(stdout+stderr)
        peak=peak_memory(proc)
        out=base/"candidate"
        run(args.exe.resolve(),"verify",["--out",str(out)])
        fields=contract(2)["fields"]
        expected=sorted((key((r[1],r[0],r[2],r[3]),fields).hex(),r[4].hex()) for r in rows)
        actual=[(j["key_hex"],j["value_hex"]) for j in map(json.loads,(out/"records.jsonl").read_text().splitlines())]
        if actual!=expected: raise AssertionError("100000-record independent encoding differs")
        result={"ready":True,"records":len(rows),"seed":20261116,"elapsed_seconds":elapsed,
                "peak_rss_bytes":peak,"input_bytes":(base/"input.jsonl").stat().st_size,
                "disk_bytes":sum(f.stat().st_size for f in out.rglob("*") if f.is_file()),
                "fst_bytes":(out/"target.fst").stat().st_size,
                "platform":platform.platform(),"python":platform.python_version(),
                "processor":platform.processor(),"manifest":json.loads((out/"manifest.json").read_text())}
        consumer=ROOT/'_build/native/release/build/WeiR-h/orderkey_snapshot/examples/device'/('device.exe' if os.name=='nt' else 'device')
        if consumer.exists():
            output=subprocess.check_output([str(consumer),str(out),'--benchmark'],text=True,encoding='utf-8')
            result['snapshot_reader']=json.loads(output.strip().splitlines()[-1])
            if not result['snapshot_reader']['ready']:raise AssertionError('snapshot reader benchmark failed')
        args.report.write_text(json.dumps(result,indent=2)+"\n",encoding="utf-8")
        print(json.dumps({k:v for k,v in result.items() if k!="manifest"},indent=2))
if __name__=="__main__": main()
