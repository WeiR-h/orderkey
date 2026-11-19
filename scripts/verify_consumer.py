"""Compile the SDK's public API from a fresh local-source consumer module."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
from verify_cli import ROOT,dataset,write_case,run

def main():
    from toolchain import activate
    activate()
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--report',type=Path,required=True)
    args=p.parse_args();args.report.write_text('{"ready":false}')
    subprocess.run(['python',str(ROOT/'scripts/package_snapshot.py')],cwd=ROOT,check=True,timeout=180)
    exe=ROOT/'_build/bin'/('orderkey.exe' if os.name=='nt' else 'orderkey')
    with tempfile.TemporaryDirectory(prefix='fresh-consumer-',dir=ROOT/'_build') as tmp:
        directory=Path(tmp);consumer=directory/'app';consumer.mkdir()
        import zipfile
        sdk=directory/'sdk'
        with zipfile.ZipFile(ROOT/'_build/publish/WeiR-h-orderkey_snapshot-0.0.18.zip') as z:z.extractall(sdk)
        (directory/'moon.work').write_text('members = '+json.dumps([ROOT.as_posix(),'sdk','app'])+'\n')
        (consumer/'moon.mod').write_text('name = "orderkey-tests/consumer"\nversion = "0.0.1"\nimport { "WeiR-h/orderkey@0.0.18", "WeiR-h/orderkey_snapshot@0.0.18", "moonbitlang/async@0.22.9" }\n')
        (consumer/'moon.pkg').write_text('import { "WeiR-h/orderkey", "WeiR-h/orderkey_snapshot" @snapshot, "moonbitlang/async", "moonbitlang/core/env" }\npkgtype(kind: "executable")\n')
        (consumer/'main.mbt').write_text('async fn main {\nlet r = @snapshot.Reader::open(@env.args()[1])\nlet q = @orderkey.QuerySpec::new([], None)\nlet page = r.query(q, limit=3)\nif page.rows.length() != 3 || page.scanned != 3 { abort("consumer mismatch") }\nprintln("consumer passed")\n}\n')
        args_case=write_case(directory/'case',dataset(False));run(exe,'build',args_case)
        subprocess.run(['moon','run','--target','native','app','--',str(directory/'case/candidate')],cwd=directory,check=True,timeout=180)
    args.report.write_text(json.dumps({'ready':True,'dependency_source':'fresh module with explicit local workspace members','public_registry_install':'not attempted; network DNS blocked'})+'\n')

if __name__=='__main__':main()
