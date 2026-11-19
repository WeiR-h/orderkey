"""Package SDK from an isolated stage, outside parent module ignore rules."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import tempfile
import zipfile
from toolchain import ROOT,activate

def main():
    activate()
    with tempfile.TemporaryDirectory(prefix='orderkey-sdk-package-') as tmp:
        stage=Path(tmp);sdk=stage/'snapshot'
        shutil.copytree(ROOT/'snapshot',sdk,ignore=shutil.ignore_patterns('_build','.mooncakes','.git'))
        (stage/'moon.work').write_text('members = '+json.dumps([ROOT.as_posix(),'snapshot'])+'\n')
        subprocess.run(['moon','-C',str(sdk),'package','--list'],cwd=stage,check=True,timeout=180)
        archives=list(stage.rglob('WeiR-h-orderkey_snapshot-*.zip'))
        if len(archives)!=1:raise RuntimeError('SDK archive was not produced')
        with zipfile.ZipFile(archives[0]) as z:
            required={'moon.mod','moon.pkg','reader.mbt','README.md','LICENSE','pkg.generated.mbti'}
            if not required.issubset(z.namelist()):raise RuntimeError('SDK source archive is incomplete')
        destination=ROOT/'_build/publish'/archives[0].name
        destination.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(archives[0],destination)
        print(destination,hashlib.sha256(destination.read_bytes()).hexdigest())

if __name__=='__main__':main()
