"""Resolve official stable, verify the archive, and install a project toolchain.

Never overwrites an existing installation or changes the user's global PATH.
Writes toolchain.json only after all standard-library bundles succeed.
"""
from pathlib import Path
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]

def download(url, path):
    print('Downloading ' + url, flush=True)
    if url.endswith(('.zip', '.tar.gz')):
        with urllib.request.urlopen(urllib.request.Request(url, method='HEAD'), timeout=30) as response:
            size = int(response.headers.get('Content-Length', '0'))
            ranged = response.headers.get('Accept-Ranges') == 'bytes'
            etag = response.headers.get('ETag')
        if ranged and size > 4 * 1024 * 1024:
            block = 2 * 1024 * 1024
            def fetch_part(start):
                end = min(start + block, size) - 1
                headers = {'Range': f'bytes={start}-{end}'}
                if etag:
                    headers['If-Match'] = etag
                for attempt in range(3):
                    try:
                        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as response:
                            expected_range = f'bytes {start}-{end}/{size}'
                            if response.status != 206 or response.headers.get('Content-Range') != expected_range:
                                raise RuntimeError('Server returned an unexpected byte range')
                            data = response.read(end - start + 2)
                            if len(data) != end - start + 1:
                                raise RuntimeError('Incomplete byte range')
                            return start, data
                    except Exception:
                        if attempt == 2:
                            raise
            with path.open('wb') as out, ThreadPoolExecutor(max_workers=4) as pool:
                pending = {pool.submit(fetch_part, start) for start in range(0, size, block)}
                complete = 0
                for future in as_completed(pending):
                    start, data = future.result()
                    out.seek(start)
                    out.write(data)
                    complete += len(data)
                    pending.remove(future)
                    print(f'Downloaded {complete}/{size} bytes', flush=True)
            return hashlib.sha256(path.read_bytes()).hexdigest()
    with urllib.request.urlopen(url, timeout=45) as response, path.open('wb') as out:
        while block := response.read(1024 * 1024):
            out.write(block)
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mirror', choices=('com', 'cn'), default='com',
                        help='Official download domain; cn is the official mirror')
    options = parser.parse_args()
    server = 'https://cli.moonbitlang.' + options.mirror
    target = 'windows' if os.name == 'nt' else 'linux'
    if platform.machine().lower() not in ('amd64', 'x86_64'):
        raise RuntimeError('Only Windows/Linux x64 are supported')
    base = ROOT / '.tools'
    base.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='stable-', dir=base) as tmp:
        stage = Path(tmp)
        suffix = '.zip' if os.name == 'nt' else '.tar.gz'
        url = f'{server}/binaries/latest/moonbit-{target}-x86_64{suffix}'
        checksum = stage / 'archive.sha256'
        download(url + '.sha256', checksum)
        expected = re.search(r'[0-9a-fA-F]{64}', checksum.read_text()).group().lower()
        archive = stage / ('moon' + suffix)
        actual = download(url, archive)
        if actual != expected:
            raise RuntimeError('Official archive checksum mismatch')
        runtime = stage / 'runtime'
        if os.name == 'nt':
            with zipfile.ZipFile(archive) as z:
                z.extractall(runtime)
        else:
            with tarfile.open(archive) as z:
                z.extractall(runtime, filter='data')
        env = dict(os.environ, MOON_HOME=str(runtime))
        env['PATH'] = str(runtime / 'bin') + os.pathsep + env.get('PATH', '')
        moon = runtime / 'bin' / ('moon.exe' if os.name == 'nt' else 'moon')
        version = subprocess.check_output([str(moon), 'version', '--all'], env=env, text=True)
        pin = re.search(r'moonc v([^\s]+)', version).group(1)
        print(version, flush=True)
        core_url = server + '/cores/core-' + urllib.parse.quote(pin, safe='') + '.zip'
        core = stage / 'core.zip'
        core_sha = download(core_url, core)
        with zipfile.ZipFile(core) as z:
            z.extractall(runtime / 'lib')
        for args in (['--all'], ['--target', 'wasm-gc']):
            subprocess.run([str(moon), 'bundle', '--warn-list', '-a', *args],
                           cwd=runtime / 'lib/core', env=env, check=True)
        destination = base / pin
        if destination.exists():
            raise RuntimeError('Version already installed; existing directory preserved')
        # Copy into the final parent so Windows inherits project permissions,
        # rather than the restrictive ACL of TemporaryDirectory.
        shutil.copytree(runtime, destination)
        env['MOON_HOME'] = str(destination)
        env['PATH'] = str(destination / 'bin') + os.pathsep + os.environ.get('PATH', '')
        version = subprocess.check_output([str(destination / 'bin' / moon.name), 'version', '--all'], env=env, text=True)
        report = dict(schema_version=1, channel='stable', version=pin, upgrade_status='installed-awaiting-acceptance',
                      binary_url=url, binary_sha256=actual, core_url=core_url,
                      core_sha256=core_sha, version_all=version)
        temporary = ROOT / 'toolchain.json.tmp'
        temporary.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        temporary.replace(ROOT / 'toolchain.json')
        print(destination)

if __name__ == '__main__':
    main()
