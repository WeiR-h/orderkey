"""Reproducible award demo: valid data, broken query budget, accepted redesign."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
from verify_cli import ROOT,dataset,write_case,run
from verify_queries import queries

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path,required=True)
    args=p.parse_args();args.out.mkdir(parents=True,exist_ok=False)
    exe=ROOT/'_build/bin/orderkey.exe'
    if not exe.exists():exe=ROOT/'_build/bin/orderkey'
    base=args.out.resolve()/'telemetry';command=write_case(base,dataset(False))
    before=hashlib.sha256((base/'input.jsonl').read_bytes()).hexdigest()
    spec=queries();work=base/'workload.json';work.write_text(json.dumps(spec,indent=2))
    where=base/'where.json';where.write_text(json.dumps(spec['queries'][0]))
    explanation=json.loads(run(exe,'explain',['--source-contract',str(base/'source.json'),'--target-contract',str(base/'target.json'),'--where',str(where)]))
    run(exe,'build',command)
    run(exe,'check-queries',['--out',str(base/'candidate'),'--queries',str(work),'--report',str(base/'rejected.json')],success=False)
    rejected=json.loads((base/'rejected.json').read_text())
    old_page=json.loads(run(exe,'query',['--out',str(base/'candidate'),'--where',str(where),'--limit','5']))
    # Tenant-leading redesign: same logical fields, newer generation.
    target=json.loads((base/'source.json').read_text());target['generation']='3'
    redesign=base/'redesign.json';redesign.write_text(json.dumps(target))
    run(exe,'build',['--input',str(base/'input.jsonl'),'--source-contract',str(base/'source.json'),'--target-contract',str(redesign),'--out',str(base/'redesigned')])
    run(exe,'query',['--out',str(base/'redesigned'),'--where',str(where),'--cursor',old_page['cursor']],success=False)
    run(exe,'check-queries',['--out',str(base/'redesigned'),'--queries',str(work),'--report',str(base/'accepted.json')])
    accepted=json.loads((base/'accepted.json').read_text())
    assert accepted['cutover_ready'] and not rejected['cutover_ready']
    after=hashlib.sha256((base/'input.jsonl').read_bytes()).hexdigest();assert before==after
    result={'ready':True,'explanation':explanation,'rejected':rejected,'accepted':accepted,'old_cursor_rejected':True,'source_before_sha256':before,'source_after_sha256':after}
    (args.out/'demo-report.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'ready':True,'before_target_scanned':rejected['queries'][1]['target_scanned'],'after_target_scanned':accepted['queries'][1]['target_scanned'],'old_cursor_rejected':True}))

if __name__=='__main__':main()
