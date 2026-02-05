#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--pez", required=True, help="Path to pez binary")
    p.add_argument("--orig-dir", required=True, help="Root directory containing .pyc files")
    p.add_argument("--out-dir", required=True, help="Root directory for decompiled .py output")
    p.add_argument("--timeout", type=int, default=60, help="Timeout seconds per file")
    p.add_argument("--limit", type=int, default=0, help="Max files to process (0 = all)")
    p.add_argument("--keep-stderr", action="store_true", help="Include stderr in report")
    p.add_argument("--out", default="", help="Write summary JSON to this path")
    return p.parse_args()


def run_pez(pez: Path, pyc: Path, timeout: int) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            [str(pez), str(pyc)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired:
        return 124, "", f"timeout after {timeout}s"


def main() -> None:
    args = parse_args()
    pez = Path(args.pez)
    orig_root = Path(args.orig_dir)
    out_root = Path(args.out_dir)

    if not pez.exists():
        raise SystemExit(f"missing: {pez}")
    if not orig_root.exists():
        raise SystemExit(f"missing: {orig_root}")

    out_root.mkdir(parents=True, exist_ok=True)

    results = []
    counts = {"total": 0, "ok": 0, "error": 0}

    processed = 0
    for pyc in sorted(orig_root.rglob("*.pyc")):
        rel = pyc.relative_to(orig_root)
        out_path = out_root / rel
        out_path = out_path.with_suffix(".py")
        out_path.parent.mkdir(parents=True, exist_ok=True)

        rc, out, err = run_pez(pez, pyc, args.timeout)
        counts["total"] += 1
        if rc == 0:
            counts["ok"] += 1
            out_path.write_text(out)
            results.append({"file": str(rel), "status": "ok"})
        else:
            counts["error"] += 1
            entry = {"file": str(rel), "status": "error", "rc": rc}
            if args.keep_stderr:
                entry["stderr"] = (err or "")[:4000]
            results.append(entry)

        processed += 1
        if args.limit and processed >= args.limit:
            break

    report = {"counts": counts, "results": results}
    out_json = json.dumps(report, indent=2)
    if args.out:
        Path(args.out).write_text(out_json)
    else:
        print(out_json)


if __name__ == "__main__":
    main()
