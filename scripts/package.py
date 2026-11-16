"""Package the built executable, examples, acceptance reports and licenses."""
from pathlib import Path
import hashlib
import json
import os
import platform
import tempfile
import zipfile
from verify_cli import ROOT, dataset, write_case

def main():
    exe=ROOT/"_build/bin"/("orderkey.exe" if os.name=="nt" else "orderkey")
    if not exe.is_file(): raise RuntimeError("build the native CLI first")
    destination=ROOT/"_build/distribution"
    destination.mkdir(exist_ok=True)
    name="orderkey-0.0.12-"+("windows" if os.name=="nt" else "linux")+"-x64.zip"
    toolchain=Path(os.environ.get("MOON_HOME",Path.home()/".moon"))
    files={exe.name:exe,"LICENSE":ROOT/"LICENSE","THIRD_PARTY.md":ROOT/"THIRD_PARTY.md",
           "README.md":ROOT/"docs/CLI.md"}
    for module in ("PingGuoMiaoMiao/moonlsm","starAndHonor/fst","moonbitlang/async","gmlewis/sha256","gmlewis/base64"):
        path=ROOT/".mooncakes"/module/"LICENSE"
        if not path.is_file(): raise RuntimeError("dependency license missing: "+module)
        files["third-party-licenses/"+module.replace("/","-")+".txt"]=path
    for license_name in ("LICENSE","NOTICE"):
        path=toolchain/"lib/core"/license_name
        if not path.is_file(): raise RuntimeError("core notice missing: "+license_name)
        files["third-party-licenses/moonbit-core-"+license_name+".txt"]=path
    for report in ("reindex-report.json","cli-report.json","benchmark.json"):
        if (ROOT/report).is_file():
            value=json.loads((ROOT/report).read_text())
            if not value["ready"]: raise RuntimeError("acceptance report failed: "+report)
            files["verification/"+report]=ROOT/report
    with tempfile.TemporaryDirectory(prefix="orderkey-package-",dir=ROOT/"_build") as tmp:
        temp=Path(tmp)
        for fixture,weather in (("telemetry",False),("weather",True)):
            base=temp/fixture
            write_case(base,dataset(weather),weather)
            for leaf in ("source.json","target.json","input.jsonl"):
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
