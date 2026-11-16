"""Build the native OrderKey CLI with an embedded source commit."""
from pathlib import Path
import os
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def main():
    version = re.search(r'version = "([^"]+)"', (ROOT / "tools/cli/moon.mod").read_text()).group(1)
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    (ROOT / "tools/cli/build_id.mbt").write_text(
        f'let tool_version = "{version}"\nlet build_commit = "{commit}"\n', encoding="utf-8"
    )
    subprocess.run(["moon", "build", "--release", "--target", "native", "tools/cli"],
                   cwd=ROOT, check=True)
    name = "orderkey_cli.exe"
    artifact = ROOT / "_build/native/release/build/WeiR-h/orderkey_cli" / name
    if not artifact.exists():
        candidates = [p for p in artifact.parent.iterdir() if p.name == "orderkey_cli"]
        if len(candidates) != 1:
            raise RuntimeError("native executable was not produced")
        artifact = candidates[0]
    out = ROOT / "_build/bin"
    out.mkdir(parents=True, exist_ok=True)
    target = out / ("orderkey.exe" if os.name == "nt" else "orderkey")
    shutil.copy2(artifact, target)
    print(target)

if __name__ == "__main__":
    main()
