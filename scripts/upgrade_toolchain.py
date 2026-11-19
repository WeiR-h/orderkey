"""Resolve official stable, verify the archive, and install a project toolchain.

Never overwrites an existing installation or changes the user's global PATH.
Writes toolchain.json only after all standard-library bundles succeed.
"""
from pathlib import Path
import hashlib
import json
import os
import platform
import re
import subprocess
import tarfile
import tempfile
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]

def download(url, path):
    with urllib.request.urlopen(url, timeout=45) as response, path.open('wb') as out:
        while block := response.read(1024 * 1024):
            out.write(block)
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    target = 'windows' if os.name == 'nt' else 'linux'
    if platform.machine().lower() not in ('amd64', 'x86_64'):
        raise RuntimeError('Only Windows/Linux x64 are supported')
    base = ROOT / '.tools'
    base.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='stable-', dir=base) as tmp:
        stage = Path(tmp)
        suffix = '.zip' if os.name == 'nt' else '.tar.gz'
        url = f'https://cli.moonbitlang.com/binaries/latest/moonbit-{target}-x86_64{suffix}'
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
        core_url = 'https://cli.moonbitlang.com/cores/core-' + urllib.parse.quote(pin, safe='') + '.zip'
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
        runtime.rename(destination)
        report = dict(schema_version=1, channel='stable', version=pin, upgrade_status='installed-awaiting-acceptance',
                      binary_url=url, binary_sha256=actual, core_url=core_url,
                      core_sha256=core_sha, version_all=version)
        temporary = ROOT / 'toolchain.json.tmp'
        temporary.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        temporary.replace(ROOT / 'toolchain.json')
        print(destination)

if __name__ == '__main__':
    main()
