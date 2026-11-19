"""Activate the project pin without changing the caller's global environment."""
from pathlib import Path
import json
import os
import subprocess

ROOT=Path(__file__).resolve().parents[1]

def activate():
    pin=json.loads((ROOT/'toolchain.json').read_text())['version']
    runtime=ROOT/'.tools'/pin
    if runtime.is_dir():
        os.environ['MOON_HOME']=str(runtime)
        os.environ['PATH']=str(runtime/'bin')+os.pathsep+os.environ.get('PATH','')
    actual=subprocess.check_output(['moonc','-v'],text=True).strip()
    if 'v'+pin+' ' not in actual:
        raise RuntimeError('Compiler differs from toolchain.json; run upgrade_toolchain.py')
    return actual
