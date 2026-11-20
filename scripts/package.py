"""Package the built executable, examples, acceptance reports and licenses."""
from pathlib import Path
import hashlib
import argparse
import re
import subprocess
import json
import os
import platform
import tempfile
import zipfile
from verify_cli import ROOT, dataset, write_case
from verify_layouts import workload, write_json

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate',action='store_true')
    options=parser.parse_args()
    if not options.candidate:subprocess.run(['python',str(ROOT/'scripts/release_gate.py')],cwd=ROOT,check=True)
    version=re.search(r'version = "([^"]+)"',(ROOT/'moon.mod').read_text()).group(1)
    exe=ROOT/"_build/bin"/("orderkey.exe" if os.name=="nt" else "orderkey")
    if not exe.is_file(): raise RuntimeError("build the native CLI first")
    destination=ROOT/"_build/distribution"
    destination.mkdir(exist_ok=True)
    name="orderkey-"+version+("-candidate-" if options.candidate else "-")+("windows" if os.name=="nt" else "linux")+"-x64.zip"
    toolchain=Path(os.environ.get("MOON_HOME",Path.home()/".moon"))
    files={exe.name:exe,"LICENSE":ROOT/"LICENSE","THIRD_PARTY.md":ROOT/"THIRD_PARTY.md",
           "README.md":ROOT/"docs/CLI.md","DEMO.md":ROOT/"docs/DEMO.md","QUERIES.md":ROOT/"docs/QUERIES.md",
           "LAYOUTS.md":ROOT/"docs/LAYOUTS.md","WORKLOADS.md":ROOT/"docs/WORKLOADS.md","toolchain.json":ROOT/"toolchain.json"}
    weather = "weather_capture.exe" if os.name == "nt" else "weather_capture"
    files[weather]=ROOT/"_build/native/release/build/WeiR-h/orderkey_snapshot/examples/weather_capture"/weather
    files["examples/weather/noaa-ghcnd-2024-q1.csv"]=ROOT/"examples/moonlsm/fixtures/noaa-ghcnd-2024-q1.csv"
    for module in ("PingGuoMiaoMiao/moonlsm","starAndHonor/fst","moonbitlang/async","gmlewis/sha256","gmlewis/base64"):
        path=ROOT/".mooncakes"/module/"LICENSE"
        if not path.is_file(): raise RuntimeError("dependency license missing: "+module)
        files["third-party-licenses/"+module.replace("/","-")+".txt"]=path
    for license_name in ("LICENSE","NOTICE"):
        path=toolchain/"lib/core"/license_name
        if not path.is_file(): raise RuntimeError("core notice missing: "+license_name)
        files["third-party-licenses/moonbit-core-"+license_name+".txt"]=path
    for report in ("reindex-report.json","cli-report.json","benchmark.json","queries-report.json",
                   "snapshot-report.json","consumer-report.json","layouts-report.json","delivery-report.json",
                   "capture-report.json",
                   "layout-benchmark.json","acceptance.json"):
        if not (ROOT/"_build/acceptance"/report).is_file():raise RuntimeError("required acceptance report missing: "+report)
        if (ROOT/"_build/acceptance"/report).is_file():
            value=json.loads((ROOT/"_build/acceptance"/report).read_text())
            if not value["ready"]: raise RuntimeError("acceptance report failed: "+report)
            files["verification/"+report]=ROOT/"_build/acceptance"/report
    with tempfile.TemporaryDirectory(prefix="orderkey-package-",dir=ROOT/"_build") as tmp:
        temp=Path(tmp)
        for fixture,weather in (("telemetry",False),("weather",True)):
            base=temp/fixture
            write_case(base,dataset(weather),weather)
            from verify_queries import queries
            (base/'workload.json').write_text(json.dumps(queries(weather),indent=2)+'\n',encoding='utf-8')
            (base/'where.json').write_text(json.dumps(queries(weather)['queries'][0],indent=2)+'\n',encoding='utf-8')
            write_json(base / 'layout-workload.json', workload(weather))
            if not weather:
                write_json(base / 'conflict-workload.json', workload(conflict=True))
                files["examples/telemetry/conflict-workload.json"] = base / 'conflict-workload.json'
            for leaf in ("source.json","target.json","input.jsonl","workload.json","where.json","layout-workload.json"):
                files["examples/"+fixture+"/"+leaf]=base/leaf
        with zipfile.ZipFile(destination/name,"w",zipfile.ZIP_DEFLATED) as archive:
            for target,path in sorted(files.items()):
                archive.write(path,target)
            lines=[]
            for target,path in sorted(files.items()):
                lines.append(hashlib.sha256(path.read_bytes()).hexdigest()+"  "+target)
            archive.writestr("SHA256SUMS.txt","\n".join(lines)+"\n")
    print(destination/name)
if __name__=="__main__": main()
