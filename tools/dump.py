#!/usr/bin/env python3
import argparse
import json
import subprocess
from pathlib import Path


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--pyc", required=True, help="Path to .pyc")
    p.add_argument("--pez", default="zig-out/bin/pez", help="Path to pez binary")
    p.add_argument("--out-dir", required=True, help="Output directory")
    p.add_argument("--sections", default="all", help="Sections: all or comma list")
    p.add_argument("--split", action="store_true", help="Split per-section JSON")
    return p.parse_args()


def run(cmd):
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        raise SystemExit(proc.stderr.strip() or proc.stdout)
    return proc.stdout


def main():
    args = parse_args()
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    dump_path = out_dir / "dump.json"
    cmd = [args.pez, f"--dump={args.sections}", f"--dump-json={dump_path}", args.pyc]
    _ = run(cmd)
    if not args.split:
        return
    data = json.loads(dump_path.read_text())
    (out_dir / "meta.json").write_text(json.dumps(data.get("meta"), indent=2))
    code = data.get("code", {})
    for key in ("bytecode", "cfg", "dom", "patterns", "passes", "children"):
        if key in code:
            (out_dir / f"{key}.json").write_text(json.dumps(code.get(key), indent=2))


if __name__ == "__main__":
    main()
