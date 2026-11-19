"""SQLite oracle, cross-process semantic pagination and negative workload gates."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import tempfile
from verify_cli import ROOT, dataset, write_case, contract, key, run

def value(b):
    return {'bytes_hex': b.hex()}

def queries(weather=False):
    return {'schema_version': 1, 'queries': [
        {'id': 'device-time', 'eq': {'tenant': value(b'ghcnd' if weather else b't3'),
                                   'device': value(b'USW00094846' if weather else b'pump\0A')},
         'range': {'field':'time', 'lower':{'int64':'20240201' if weather else '-2'},
                   'upper':{'int64':'20240301' if weather else '4'}}, 'page_size':5},
        {'id': 'tenant-scan', 'eq': {'tenant':value(b'ghcnd' if weather else b't3')},
         'max_target_scanned': 273 if weather else 1000, 'page_size':113}]}

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--exe',type=Path,default=ROOT/'_build/bin'/('orderkey.exe' if os.name=='nt' else 'orderkey'))
    p.add_argument('--report',type=Path,required=True)
    args=p.parse_args();exe=args.exe.resolve()
    args.report.write_text('{"ready":false}\n',encoding='utf-8')
    checks=[]; summaries=[]
    with tempfile.TemporaryDirectory(prefix='query-acceptance-',dir=ROOT/'_build') as tmp:
        for weather in (False,True):
            base=Path(tmp)/('weather' if weather else 'telemetry')
            rows=dataset(weather); command=write_case(base,rows,weather)
            run(exe,'build',command)
            candidate=base/'candidate'; before={f.relative_to(candidate).as_posix():hashlib.sha256(f.read_bytes()).hexdigest() for f in candidate.rglob('*') if f.is_file() and f.name!='.lock'}
            workload=queries(weather);work=base/'workload.json';report=base/'queries-report.json'
            work.write_text(json.dumps(workload),encoding='utf-8')
            run(exe,'check-queries',['--out',str(candidate),'--queries',str(work),'--report',str(report)],success=weather)
            receipt=json.loads(report.read_text())
            assert receipt['data_ready'] and receipt['workload_passed']==weather
            first,second=receipt['queries']; assert first['matched']==(29 if weather else 18)
            if not weather:
                assert (second['source_scanned'],second['target_scanned'],second['matched'])==(984,9840,984)
                assert second['results_match'] and not second['within_budget']
            q=workload['queries'][0]; where=base/'where.json';where.write_text(json.dumps(q))
            pages=[];cursor=None
            while True:
                result=json.loads(run(exe,'query',['--out',str(candidate),'--where',str(where),'--limit','5']+(['--cursor',cursor] if cursor else [])))
                pages.extend(result['rows']);cursor=result['cursor']
                if cursor is None:break
            # Independent SQLite operates on original business fields.
            with sqlite3.connect(':memory:') as db:
                db.execute('CREATE TABLE r(tenant BLOB,device BLOB,time INTEGER,seq INTEGER,value BLOB)')
                db.executemany('INSERT INTO r VALUES(?,?,?,?,?)',rows)
                order='tenant,device,time,seq' if weather else 'device,tenant,time DESC,seq'
                expected=db.execute('SELECT * FROM r WHERE tenant=? AND device=? AND time>=? AND time<? ORDER BY '+order,
                    (bytes.fromhex(q['eq']['tenant']['bytes_hex']),bytes.fromhex(q['eq']['device']['bytes_hex']),int(q['range']['lower']['int64']),int(q['range']['upper']['int64']))).fetchall()
            encoded=[{'key_hex':key(r[:4] if weather else (r[1],r[0],r[2],r[3]),contract(2,weather)['fields']).hex(),'value_hex':r[4].hex()} for r in expected]
            assert pages==encoded
            # Residual predicate cursor must not be reusable for another tenant.
            where.write_text(json.dumps(workload['queries'][1]))
            response=json.loads(run(exe,'query',['--out',str(candidate),'--where',str(where),'--limit','1']))
            if response['cursor']:
                changed={'eq':{'tenant':value(b'another')}};where.write_text(json.dumps(changed))
                run(exe,'query',['--out',str(candidate),'--where',str(where),'--cursor',response['cursor']],success=False)
            # Failure replaces the previous successful/failed run, never a stale green.
            old=receipt['run_id'];work.write_text('{broken')
            run(exe,'check-queries',['--out',str(candidate),'--queries',str(work),'--report',str(report)],success=False)
            failed=json.loads(report.read_text());assert not failed['cutover_ready'] and failed['run_id']!=old
            for bad in ({'eq':{'unknown':value(b'x')}},{'eq':{'time':value(b'x')}},{'eq':{'tenant':{'bytes_hex':'zz'}}},{'wat':1},{'range':{'field':'time','lower':{'int64':'9223372036854775808'}}}):
                where.write_text(json.dumps(bad));run(exe,'query',['--out',str(candidate),'--where',str(where)],success=False)
            # Mutations with refreshed digests must still fail semantic/content checks.
            import shutil
            for mutation in ('drop-row','swap-payload','wrong-key','fst-ordinal'):
                mutant=base/('mutant-'+mutation);shutil.copytree(candidate,mutant)
                records=mutant/'records.jsonl'
                lines=[json.loads(line) for line in records.read_text().splitlines()]
                if mutation=='drop-row':lines.pop()
                elif mutation=='swap-payload':lines[0]['value_hex']='deadbeef'
                elif mutation=='wrong-key':lines[0]['key_hex']=lines[1]['key_hex']
                else:
                    fst=mutant/'target.fst';content=bytearray(fst.read_bytes());content[len(content)//2]^=1;fst.write_bytes(content)
                if mutation!='fst-ordinal':records.write_text(''.join(json.dumps(line)+'\n' for line in lines))
                manifest=json.loads((mutant/'manifest.json').read_text())
                for leaf in manifest['files']:manifest['files'][leaf]=hashlib.sha256((mutant/leaf).read_bytes()).hexdigest()
                (mutant/'manifest.json').write_text(json.dumps(manifest))
                saved=json.loads((mutant/'report.json').read_text());saved['manifest_sha256']=hashlib.sha256((mutant/'manifest.json').read_bytes()).hexdigest()
                (mutant/'report.json').write_text(json.dumps(saved))
                work.write_text(json.dumps(queries(weather)))
                run(exe,'check-queries',['--out',str(mutant),'--queries',str(work),'--report',str(report)],success=False)
                assert not json.loads(report.read_text())['cutover_ready']
            # Report destinations cannot overwrite candidate metadata or input files.
            for protected in (candidate/'report.json',base/'input.jsonl',work):
                before_protected=protected.read_bytes()
                run(exe,'check-queries',['--out',str(candidate),'--queries',str(work),'--report',str(protected)],success=False)
                assert protected.read_bytes()==before_protected, str(protected)
            # A copied candidate queries without its original paths.
            import shutil
            copied=base/'portable';shutil.copytree(candidate,copied)
            (base/'input.jsonl').rename(base/'input-hidden.jsonl')
            where.write_text(json.dumps(q));run(exe,'query',['--out',str(copied),'--where',str(where)])
            after={f.relative_to(candidate).as_posix():hashlib.sha256(f.read_bytes()).hexdigest() for f in candidate.rglob('*') if f.is_file() and f.name!='.lock'}
            assert before==after
            summaries.append({'weather':weather,'queries':receipt['queries'],'sqlite_matches':len(pages)})
        checks=['SQLite-independent-business-fields','budget-rejects-correct-but-slower-query','typed-query-pagination','residual-query-cursor-scope','stale-report-replaced','unknown-field','wrong-type','bad-hex','bad-integer','unknown-property','portable-query','candidate-unchanged','rehashed-drop-row','rehashed-payload-change','rehashed-wrong-key','rehashed-fst-corruption','report-overwrite-protection']
    result={'ready':True,'version':json.loads(run(exe,'version',[])),'cases':summaries,'checks':checks}
    args.report.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'ready':True,'checks':checks}))

if __name__=='__main__':main()
