"""Run independent SDK consumers, including 100 pages in a single session."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from verify_cli import ROOT, dataset, write_case, contract, key, run

def consumer(name):
    base=ROOT/'_build/native/release/build/WeiR-h/orderkey_snapshot/examples'/name
    paths=[base/(name+'.exe'),base/name]
    return next(p for p in paths if p.is_file())

def main():
    from toolchain import activate
    activate()
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--report',type=Path,required=True)
    args=p.parse_args();args.report.write_text('{"ready":false}\n')
    subprocess.run(['moon','build','--release','--target','native','snapshot/examples/device','snapshot/examples/weather'],cwd=ROOT,check=True)
    exe=ROOT/'_build/bin'/('orderkey.exe' if os.name=='nt' else 'orderkey')
    cases=[]
    with tempfile.TemporaryDirectory(prefix='sdk-acceptance-',dir=ROOT/'_build') as tmp:
        for weather in (False,True):
            base=Path(tmp)/('weather' if weather else 'device')
            command=write_case(base,dataset(weather),weather);run(exe,'build',command)
            target=base/'candidate';copied=base/'portable';shutil.copytree(target,copied)
            (base/'input.jsonl').rename(base/'input-hidden.jsonl')
            app=consumer('weather' if weather else 'device')
            def invoke(path,success=True):
                result=subprocess.run([str(app),str(path)],capture_output=True,text=True,encoding='utf-8',timeout=60)
                assert (result.returncode==0)==success, result.stdout+result.stderr
                return json.loads(result.stdout.strip().splitlines()[-1]) if success else None
            result=invoke(copied);assert result['ready']
            records=[json.loads(line) for line in (copied/'records.jsonl').read_text().splitlines()]
            selected=[]
            for row in dataset(weather):
                if weather:
                    match=row[1]==b'USW00094846' and 20240201<=row[2]<20240301
                    values=row[:4]
                else:
                    match=row[0]==b't3' and row[1]==b'pump\0A' and -2<=row[2]<4
                    values=(row[1],row[0],row[2],row[3])
                if match:selected.append(key(values,contract(2,weather)['fields']).hex())
            assert result['keys']==sorted(selected)
            if not weather:assert result['page_rows']==result['page_scanned']==100
            # Modified delivery and revoked receipt both fail in the consumer.
            fst=copied/'target.fst';raw=fst.read_bytes();fst.write_bytes(raw[:-1]);invoke(copied,False);fst.write_bytes(raw)
            receipt=copied/'report.json';raw=receipt.read_bytes();receipt.write_text('{"ready":false}');invoke(copied,False);receipt.write_bytes(raw)
            result['case']='weather' if weather else 'device';result['portable']=True;cases.append(result)
    args.report.write_text(json.dumps({'ready':True,'cases':cases,'checks':['source-independent-consumers','typed-results-independent-python','100-pages-single-open','corrupt-delivery-rejected','revoked-receipt-rejected']},indent=2)+'\n')
    print(json.dumps({'ready':True,'cases':[{'case':c['case'],'rows':len(c['keys'])} for c in cases]}))

if __name__=='__main__':main()
