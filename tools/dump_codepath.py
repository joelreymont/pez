#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--pyc", required=True, help="Path to .pyc")
    p.add_argument("--code-path", default="", help="Dot path to nested code object")
    p.add_argument("--code-index", type=int, default=-1, help="Path index if duplicates exist")
    p.add_argument("--pez", default="", help="Path to pez binary")
    p.add_argument("--sections", default="bytecode,cfg,patterns", help="Comma-separated sections")
    p.add_argument("--out", default="", help="Write JSON to this path")
    p.add_argument("--timeout", type=int, default=120, help="Timeout seconds per section")
    return p.parse_args()


def run_dump_view(pyc: Path, section: str, code_path: str, code_index: int, pez: str, timeout: int):
    args = [
        sys.executable,
        str(Path(__file__).resolve().parent / "dump_view.py"),
        "--pyc",
        str(pyc),
        "--section",
        section,
    ]
    if code_path:
        args += ["--code-path", code_path]
    if code_index >= 0:
        args += ["--code-index", str(code_index)]
    if pez:
        args += ["--pez", pez]
    proc = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        raise SystemExit(proc.returncode)
    return json.loads(proc.stdout)


def main() -> None:
    args = parse_args()
    pyc = Path(args.pyc)
    if not pyc.exists():
        raise SystemExit(f"missing: {pyc}")

    sections = [s.strip() for s in args.sections.split(",") if s.strip()]
    if not sections:
        raise SystemExit("no sections")

    out = {
        "pyc": str(pyc),
        "code_path": args.code_path,
        "code_index": args.code_index if args.code_index >= 0 else None,
        "sections": {},
    }
    for section in sections:
        out["sections"][section] = run_dump_view(
            pyc,
            section,
            args.code_path,
            args.code_index,
            args.pez,
            args.timeout,
        )

    payload = json.dumps(out, indent=2)
    if args.out:
        Path(args.out).write_text(payload)
    else:
        print(payload)


if __name__ == "__main__":
    main()
