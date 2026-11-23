"""Compile the SDK's public API from a fresh local-source consumer module."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import zipfile
from verify_cli import ROOT,dataset,write_case,run
from verify_earthquakes import cases as earthquake_cases
from verify_segmented import rebuild
from verify_layouts import build_args, case_args, workload, write_json

def main():
    from toolchain import activate
    activate()
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--report',type=Path,required=True)
    p.add_argument('--registry', action='store_true', help='Install from a clean public package cache')
    args=p.parse_args();args.report.write_text('{"ready":false}')
    version = re.search(r'version = "([^"]+)"', (ROOT / 'moon.mod').read_text()).group(1)
    if not args.registry:
        subprocess.run(['python',str(ROOT/'scripts/package_snapshot.py')],cwd=ROOT,check=True,timeout=180)
    exe=ROOT/'_build/bin'/('orderkey.exe' if os.name=='nt' else 'orderkey')
    with tempfile.TemporaryDirectory(prefix='fresh-consumer-',dir=ROOT/'_build') as tmp:
        directory=Path(tmp);consumer=directory/'app';consumer.mkdir()
        env = os.environ.copy()
        if args.registry:
            moon_home = Path(env.get('MOON_HOME', Path.home() / '.moon'))
            isolated_home = directory / 'moon-home'
            shutil.copytree(moon_home / 'lib', isolated_home / 'lib')
            env['MOON_HOME'] = str(isolated_home)
        else:
            with zipfile.ZipFile(ROOT / f'_build/publish/WeiR-h-orderkey_snapshot-{version}.zip') as archive:
                archive.extractall(directory / 'sdk')
            (directory/'moon.work').write_text('members = '+json.dumps([ROOT.as_posix(),'sdk','app'])+'\n')
        (consumer/'moon.mod').write_text(
            'name = "orderkey-tests/consumer"\nversion = "0.0.1"\n'
            f'import {{ "WeiR-h/orderkey@{version}", "WeiR-h/orderkey_snapshot@{version}", "moonbitlang/async@0.22.9" }}\n'
        )
        (consumer/'moon.pkg').write_text(
            'import { "WeiR-h/orderkey" @key, "WeiR-h/orderkey_snapshot" @snapshot, '
            '"moonbitlang/async", "moonbitlang/core/env" @env }\npkgtype(kind: "executable")\n'
        )
        (consumer/'main.mbt').write_text(r'''
async fn main {
  let reader = @snapshot.Reader::open_selected(@env.args()[1])
  let query = @key.QuerySpec::new(
    [(b"tenant", Binary(b"ghcnd")), (b"device", Binary(b"USW00094846"))],
    Some((b"time", Some(Signed(20240201L)), Some(Signed(20240301L)))),
  )
  let mut cursor = None
  let mut count = 0
  while true {
    let page = reader.query(query, limit=5, cursor~)
    count += page.rows.length()
    cursor = page.cursor
    if cursor is None { break }
  }
  if count != 29 { abort("weather consumer mismatch") }
  println("consumer passed: 29 weather rows")
}
''', encoding='utf-8')
        case = directory / 'case'
        write_case(case, dataset(True), True)
        write_json(case / 'layout-workload.json', workload(True))
        selection = case / 'selected-layout'
        target = case / 'portable'
        run(exe, 'compare-layouts', [*case_args(case), '--auto', '--out', str(selection)])
        run(exe, 'build-selected', build_args(case, selection, target))
        # Verify that the snapshot reader has no source-export or selection path dependency.
        (case / 'input.jsonl').rename(case / 'original-export.jsonl')
        if args.registry:
            subprocess.run(['moon', 'update'], cwd=consumer, env=env, check=True, timeout=180)
        subprocess.run(['moon', 'run', '--target', 'native', '.', '--', str(target)],
                       cwd=consumer, env=env, check=True, timeout=180)
        earthquakes = directory / 'earthquakes'
        earthquake_cases(earthquakes)
        late, delivery = earthquakes / 'late', earthquakes / 'delivery'
        rebuild(exe, late, delivery)
        (late / 'input.jsonl').rename(late / 'original-export.jsonl')
        for name in ('moon.pkg', 'main.mbt'):
            shutil.copyfile(ROOT / 'snapshot/examples/earthquakes' / name, consumer / name)
        result = subprocess.check_output(['moon', 'run', '--target', 'native', '.', '--',
                                          str(delivery)], cwd=consumer, env=env,
                                         text=True, encoding='utf-8', timeout=180)
        values = json.loads(result.strip().splitlines()[-1])
        assert len(values) == 33
        digest = hashlib.sha256('\n'.join(values).encode()).hexdigest()
        oracle = json.loads((ROOT / '_build/acceptance/earthquakes-report.json').read_bytes())
        assert digest == oracle['batches'][0]['ordered_result_sha256']
    args.report.write_text(json.dumps({
        'ready': True, 'weather_rows': 29,
        'earthquake_rows': 33, 'earthquake_scanned': 33, 'earthquake_result_sha256': digest,
        'dependency_source': 'public Mooncakes' if args.registry else 'fresh module with packaged local SDK',
        'public_registry_install': args.registry,
    }) + '\n', encoding='utf-8')

if __name__=='__main__':main()
