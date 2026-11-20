"""One-command local acceptance; public CI/organizer status are separate."""
from pathlib import Path
import hashlib
import json
import os
import platform
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'_build/acceptance'

def main():
    from toolchain import activate
    activate()
    OUT.mkdir(parents=True,exist_ok=True)
    report=OUT/'acceptance.json'
    result={'ready':False,'platform':platform.platform(),'checks':[]}
    report.write_text(json.dumps(result))
    steps=[['moon','fmt','--check'], *[['moon','test','--deny-warn','--target',t,'.'] for t in ('wasm','wasm-gc','js','native')],
           [sys.executable,'examples/moonlsm/verify_sqlite.py','--baseline'],
           [sys.executable,'examples/moonlsm/verify_reindex.py','--report',str(OUT/'reindex-report.json')],
           [sys.executable,'scripts/test_reports.py'],
           [sys.executable,'scripts/build.py'],
           ['moon','check','--deny-warn','--target','native','tools/cli','snapshot'],
           [sys.executable,'scripts/verify_cli.py','--report',str(OUT/'cli-report.json')],
           [sys.executable,'scripts/verify_queries.py','--report',str(OUT/'queries-report.json')],
           [sys.executable,'scripts/verify_layouts.py','--report',str(OUT/'layouts-report.json')],
           [sys.executable,'scripts/verify_delivery.py','--report',str(OUT/'delivery-report.json')],
           [sys.executable,'scripts/verify_capture.py','--report',str(OUT/'capture-report.json')],
           [sys.executable,'scripts/verify_audit.py','--report',str(OUT/'audit-report.json')],
           [sys.executable,'scripts/verify_gate.py','--report',str(OUT/'gate-report.json')],
           [sys.executable,'scripts/verify_snapshot.py','--report',str(OUT/'snapshot-report.json')],
           [sys.executable,'scripts/verify_consumer.py','--report',str(OUT/'consumer-report.json')],
           [sys.executable,'scripts/benchmark.py','--report',str(OUT/'benchmark.json')],
           [sys.executable,'scripts/benchmark_layouts.py','--report',str(OUT/'layout-benchmark.json')]]
    try:
        for command in steps:
            print('Checking: '+' '.join(command),flush=True)
            start=time.perf_counter()
            subprocess.run(command,cwd=ROOT,check=True,timeout=600)
            result['checks'].append({'command':command,'seconds':time.perf_counter()-start})
            report.write_text(json.dumps(result,indent=2)+'\n')
        exe=ROOT/'_build/bin'/('orderkey.exe' if os.name=='nt' else 'orderkey')
        result['build']=json.loads(subprocess.check_output([str(exe),'version','--json'],text=True))
        result['binary_sha256']=hashlib.sha256(exe.read_bytes()).hexdigest()
        result['ready']=True
    except Exception as error:
        result['error']=str(error)
        raise
    finally:
        report.write_text(json.dumps(result,indent=2)+'\n')

if __name__=='__main__':main()
