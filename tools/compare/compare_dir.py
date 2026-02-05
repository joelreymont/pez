#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--orig-dir", required=True, help="Root directory containing .pyc files")
    p.add_argument("--src-dir", required=True, help="Root directory containing decompiled .py files")
    p.add_argument("--py", default=sys.executable, help="Python interpreter to compile source")
    p.add_argument(
        "--xdis-python",
        default="",
        help="Python interpreter with xdis installed (default: autodetect)",
    )
    p.add_argument("--timeout", type=int, default=120, help="Timeout seconds per file")
    p.add_argument("--out", default="", help="Write summary JSON to this path")
    p.add_argument("--report-dir", default="", help="Write per-file reports to this directory")
    p.add_argument("--limit", type=int, default=0, help="Max files to process (0 = all)")
    return p.parse_args()


def run_compare(
    script: Path,
    orig: Path,
    src: Path,
    py: str,
    xdis_py: str,
    timeout: int,
) -> dict:
    cmd = [
        sys.executable,
        str(script),
        "--orig",
        str(orig),
        "--src",
        str(src),
        "--py",
        py,
        "--timeout",
        str(timeout),
    ]
    if xdis_py:
        cmd.extend(["--xdis-python", xdis_py])
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return {
            "verdict": "error",
            "summary": {"error": f"timeout after {timeout}s"},
            "rows": [],
        }
    if proc.returncode != 0:
        return {
            "verdict": "error",
            "summary": {"error": proc.stderr.strip() or "compare failed"},
            "rows": [],
        }
    try:
        return json.loads(proc.stdout)
    except Exception:
        return {
            "verdict": "error",
            "summary": {"error": "invalid json"},
            "rows": [],
        }


def main() -> None:
    args = parse_args()
    orig_root = Path(args.orig_dir)
    src_root = Path(args.src_dir)
    script = Path(__file__).with_name("compare.py")

    if not orig_root.exists():
        raise SystemExit(f"missing: {orig_root}")
    if not src_root.exists():
        raise SystemExit(f"missing: {src_root}")
    if not script.exists():
        raise SystemExit(f"missing: {script}")

    report_dir = Path(args.report_dir) if args.report_dir else None
    if report_dir:
        report_dir.mkdir(parents=True, exist_ok=True)

    results = []
    counts = {"exact": 0, "close": 0, "mismatch": 0, "error": 0, "missing_src": 0}
    worst_seq = []
    worst_semantic = []

    processed = 0
    for pyc in sorted(orig_root.rglob("*.pyc")):
        rel = pyc.relative_to(orig_root)
        src = src_root / rel
        src = src.with_suffix(".py")
        processed += 1
        if not src.exists():
            counts["missing_src"] += 1
            results.append(
                {
                    "file": str(rel),
                    "verdict": "missing_src",
                    "summary": {},
                }
            )
            if args.limit and processed >= args.limit:
                break
            continue

        report = run_compare(script, pyc, src, args.py, args.xdis_python, args.timeout)
        verdict = report.get("verdict", "error")
        counts[verdict] = counts.get(verdict, 0) + 1

        summary = report.get("summary", {})
        if verdict != "error":
            worst_seq.append(
                {
                    "file": str(rel),
                    "min_seq_ratio": summary.get("min_seq_ratio", 0.0),
                    "avg_seq_ratio": summary.get("avg_seq_ratio", 0.0),
                    "min_count_jaccard": summary.get("min_count_jaccard", 0.0),
                }
            )
            worst_semantic.append(
                {
                    "file": str(rel),
                    "min_semantic_score": summary.get("min_semantic_score", 0.0),
                    "avg_semantic_score": summary.get("avg_semantic_score", 0.0),
                    "min_block_jaccard": summary.get("min_block_jaccard", 0.0),
                    "min_edge_jaccard": summary.get("min_edge_jaccard", 0.0),
                }
            )

        results.append({"file": str(rel), "verdict": verdict, "summary": summary})

        if report_dir:
            out_path = report_dir / (str(rel).replace(os.sep, "__") + ".json")
            out_path.write_text(json.dumps(report, indent=2))
        if args.limit and processed >= args.limit:
            break

    worst_seq.sort(key=lambda r: (r["min_seq_ratio"], r["min_count_jaccard"]))
    worst_semantic.sort(key=lambda r: (r["min_semantic_score"], r["min_block_jaccard"], r["min_edge_jaccard"]))

    summary = {
        "total": len(results),
        "counts": counts,
        "worst_seq": worst_seq[:25],
        "worst_semantic": worst_semantic[:25],
    }

    out = json.dumps({"summary": summary, "results": results}, indent=2)
    if args.out:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(out)
    else:
        print(out)


if __name__ == "__main__":
    main()
