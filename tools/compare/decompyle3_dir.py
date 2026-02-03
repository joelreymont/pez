#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--decompyle3", default="decompyle3", help="Path to decompyle3 executable")
    p.add_argument("--orig-dir", required=True, help="Root directory containing .pyc files")
    p.add_argument("--out-dir", required=True, help="Root directory for decompiled .py output")
    p.add_argument("--timeout", type=int, default=60, help="Timeout seconds per file")
    p.add_argument("--limit", type=int, default=0, help="Max files to process (0 = all)")
    p.add_argument("--keep-stderr", action="store_true", help="Include stderr in report")
    p.add_argument("--out", default="", help="Write summary JSON to this path")
    return p.parse_args()


def run_decompyle3(decompyle3: Path, pyc: Path, out_dir: Path, timeout: int) -> tuple[int, str, str]:
    proc = subprocess.run(
        [str(decompyle3), "-o", str(out_dir), str(pyc)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout,
    )
    return proc.returncode, proc.stdout, proc.stderr


def pick_output_file(tmpdir: Path, pyc: Path) -> Path:
    # decompyle3 flattens output to the basename, so we isolate each run in a temp dir.
    expected = tmpdir / (pyc.stem + ".py")
    if expected.exists():
        return expected
    candidates = sorted([p for p in tmpdir.iterdir() if p.is_file()])
    if len(candidates) == 1:
        return candidates[0]
    raise FileNotFoundError("decompyle3 produced no unique output file")


def main() -> None:
    args = parse_args()
    decompyle3 = Path(args.decompyle3)
    orig_root = Path(args.orig_dir)
    out_root = Path(args.out_dir)

    if not orig_root.exists():
        raise SystemExit(f"missing: {orig_root}")
    if not decompyle3.exists() and args.decompyle3 != "decompyle3":
        raise SystemExit(f"missing: {decompyle3}")

    out_root.mkdir(parents=True, exist_ok=True)

    results = []
    counts = {"total": 0, "ok": 0, "error": 0}

    processed = 0
    for pyc in sorted(orig_root.rglob("*.pyc")):
        rel = pyc.relative_to(orig_root)
        out_path = out_root / rel
        out_path = out_path.with_suffix(".py")
        out_path.parent.mkdir(parents=True, exist_ok=True)

        counts["total"] += 1

        try:
            with tempfile.TemporaryDirectory(prefix="pez-decompyle3-") as tmp:
                tmpdir = Path(tmp)
                rc, _, err = run_decompyle3(decompyle3, pyc, tmpdir, args.timeout)
                if rc == 0:
                    src_path = pick_output_file(tmpdir, pyc)
                    out_path.write_text(src_path.read_text())
                    counts["ok"] += 1
                    results.append({"file": str(rel), "status": "ok"})
                else:
                    counts["error"] += 1
                    entry = {"file": str(rel), "status": "error", "rc": rc}
                    if args.keep_stderr:
                        entry["stderr"] = (err or "")[:4000]
                    results.append(entry)
        except subprocess.TimeoutExpired:
            counts["error"] += 1
            entry = {"file": str(rel), "status": "error", "rc": 124, "stderr": "timeout"}
            results.append(entry)
        except Exception as e:
            counts["error"] += 1
            entry = {"file": str(rel), "status": "error", "rc": 1, "stderr": str(e)}
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

