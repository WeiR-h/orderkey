"""Refuse release until stable upgrade and clean-source acceptance are proved."""
from pathlib import Path
import hashlib
import json
import os
import subprocess

ROOT=Path(__file__).resolve().parents[1]

def main():
    from toolchain import activate
    activate()
    pin=json.loads((ROOT/'toolchain.json').read_text())
    if pin['channel']!='stable':raise RuntimeError('Latest stable upgrade is unverified; candidate packages only')
    actual=subprocess.check_output(['moonc','-v'],text=True)
    if 'v'+pin['version']+' ' not in actual:raise RuntimeError('Compiler differs from pinned toolchain')
    acceptance=json.loads((ROOT/'_build/acceptance/acceptance.json').read_text())
    if not acceptance['ready']:raise RuntimeError('Acceptance failed')
    if acceptance['build']['compiler'] != actual.strip():raise RuntimeError('Acceptance was built with a different compiler')
    current=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    if subprocess.check_output(['git','status','--porcelain'],cwd=ROOT):raise RuntimeError('Source tree is dirty')
    if acceptance['build']['build_commit']!=current or acceptance['build']['dirty']:raise RuntimeError('Acceptance does not match clean source')
    exe=ROOT/'_build/bin'/('orderkey.exe' if os.name=='nt' else 'orderkey')
    if hashlib.sha256(exe.read_bytes()).hexdigest()!=acceptance['binary_sha256']:raise RuntimeError('Executable changed after acceptance')
    print('Local release gate passed. Verify other-platform CI and public downloads separately.')

if __name__=='__main__':main()
