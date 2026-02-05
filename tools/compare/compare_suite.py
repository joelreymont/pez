#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Optional


ROOT = Path(__file__).resolve().parents[2]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--orig-dir", required=True, help="Root directory containing .pyc files")
    p.add_argument("--py", default="python3.9", help="Python interpreter to compile source")
    p.add_argument("--xdis-python", default="", help="Python interpreter with xdis installed")
    p.add_argument("--pez", default=str(ROOT / "zig-out" / "bin" / "pez"), help="Path to pez binary")
    p.add_argument("--decompyle3", default="", help="Path to decompyle3 executable (default: auto)")
    p.add_argument("--timeout-decompile", type=int, default=60, help="Timeout seconds per file (decompile)")
    p.add_argument("--timeout-compare", type=int, default=120, help="Timeout seconds per file (compare)")
    p.add_argument("--limit", type=int, default=0, help="Max files to process (0 = all)")
    p.add_argument("--out-root", default="", help="Write all artifacts under this directory (default: temp)")
    p.add_argument("--out", default="", help="Write summary JSON to this path (default: stdout)")
    p.add_argument("--keep", action="store_true", help="Keep temp out-root when not provided")
    return p.parse_args()


def die(msg: str) -> None:
    sys.stderr.write(msg + "\n")
    raise SystemExit(2)


def run(cmd: list[str], timeout: int) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        die(f"timeout after {timeout}s: {' '.join(cmd)}")


def resolve_decompyle3(arg: str) -> str:
    if arg:
        return arg
    env = os.environ.get("PEZ_DECOMPYLE3")
    if env:
        return env
    candidates = [
        "/tmp/decompyle3-venv-312/bin/decompyle3",
        "/tmp/decompyle3-venv-311/bin/decompyle3",
        "decompyle3",
        "/tmp/decompyle3-local",
    ]
    for c in candidates:
        p = Path(c)
        if p.is_absolute():
            if p.exists():
                return str(p)
        else:
            if path_which(c):
                return c
    return "decompyle3"


def path_which(name: str) -> Optional[str]:
    for d in os.environ.get("PATH", "").split(os.pathsep):
        p = Path(d) / name
        if p.exists() and os.access(p, os.X_OK):
            return str(p)
    return None


def read_json(path: Path) -> dict:
    return json.loads(path.read_text())


def first_decompile_err(report: dict) -> str:
    for r in report.get("results", []):
        if r.get("status") == "error":
            file = r.get("file", "?")
            rc = r.get("rc", "?")
            stderr = (r.get("stderr") or "").strip()
            if stderr:
                return f"{file} rc={rc}: {stderr}"
            return f"{file} rc={rc}"
    return "unknown"


def first_compare_err(report: dict) -> str:
    for r in report.get("results", []):
        if r.get("verdict") == "error":
            file = r.get("file", "?")
            err = (r.get("summary") or {}).get("error", "")
            if err:
                return f"{file}: {err}"
            return f"{file}"
    return "unknown"


def first_missing_src(report: dict) -> str:
    for r in report.get("results", []):
        if r.get("verdict") == "missing_src":
            return r.get("file", "?")
    return "unknown"


def main() -> None:
    args = parse_args()
    orig_root = Path(args.orig_dir)
    if not orig_root.exists():
        die(f"missing: {orig_root}")

    pez = Path(args.pez)
    if not pez.exists():
        die(f"missing: {pez}")

    decompyle3 = Path(resolve_decompyle3(args.decompyle3))
    if not decompyle3.exists() and str(decompyle3) != "decompyle3":
        die(f"missing: {decompyle3}")

    pyc_total = sum(1 for _ in orig_root.rglob("*.pyc"))
    if pyc_total == 0:
        die(f"no .pyc found under: {orig_root}")
    n = pyc_total if args.limit <= 0 else min(args.limit, pyc_total)
    decomp_timeout = n * max(1, args.timeout_decompile) + 30
    cmp_timeout = n * max(1, args.timeout_compare) + 30

    if args.out_root:
        out_root = Path(args.out_root)
        out_root.mkdir(parents=True, exist_ok=True)
        owns_root = False
    else:
        out_root = Path(tempfile.mkdtemp(prefix="pez-compare-suite-"))
        owns_root = not args.keep

    ok = False
    try:
        pez_src = out_root / "pez_src"
        decomp_src = out_root / "decompyle3_src"
        pez_src.mkdir(parents=True, exist_ok=True)
        decomp_src.mkdir(parents=True, exist_ok=True)

        decompile_dir = Path(__file__).with_name("decompile_dir.py")
        decompyle3_dir = Path(__file__).with_name("decompyle3_dir.py")
        compare_dir = Path(__file__).with_name("compare_dir.py")

        pez_decomp_json = out_root / "pez_decompile.json"
        pez_cmp_json = out_root / "pez_compare.json"
        decomp_decomp_json = out_root / "decompyle3_decompile.json"
        decomp_cmp_json = out_root / "decompyle3_compare.json"

        # pez: decompile + compare
        proc = run(
            [
                sys.executable,
                str(decompile_dir),
                "--pez",
                str(pez),
                "--orig-dir",
                str(orig_root),
                "--out-dir",
                str(pez_src),
                "--timeout",
                str(args.timeout_decompile),
                "--limit",
                str(args.limit),
                "--keep-stderr",
                "--out",
                str(pez_decomp_json),
            ],
            timeout=decomp_timeout,
        )
        if proc.returncode != 0:
            die(proc.stderr.strip() or proc.stdout.strip() or f"pez decompile_dir failed (out_root={out_root})")

        proc = run(
            [
                sys.executable,
                str(compare_dir),
                "--orig-dir",
                str(orig_root),
                "--src-dir",
                str(pez_src),
                "--py",
                args.py,
                "--timeout",
                str(args.timeout_compare),
                "--limit",
                str(args.limit),
                "--out",
                str(pez_cmp_json),
            ]
            + (["--xdis-python", args.xdis_python] if args.xdis_python else []),
            timeout=cmp_timeout,
        )
        if proc.returncode != 0:
            die(proc.stderr.strip() or proc.stdout.strip() or f"pez compare_dir failed (out_root={out_root})")

        # decompyle3: decompile + compare
        proc = run(
            [
                sys.executable,
                str(decompyle3_dir),
                "--decompyle3",
                str(decompyle3),
                "--orig-dir",
                str(orig_root),
                "--out-dir",
                str(decomp_src),
                "--timeout",
                str(args.timeout_decompile),
                "--limit",
                str(args.limit),
                "--keep-stderr",
                "--out",
                str(decomp_decomp_json),
            ],
            timeout=decomp_timeout,
        )
        if proc.returncode != 0:
            die(proc.stderr.strip() or proc.stdout.strip() or f"decompyle3_dir failed (out_root={out_root})")

        proc = run(
            [
                sys.executable,
                str(compare_dir),
                "--orig-dir",
                str(orig_root),
                "--src-dir",
                str(decomp_src),
                "--py",
                args.py,
                "--timeout",
                str(args.timeout_compare),
                "--limit",
                str(args.limit),
                "--out",
                str(decomp_cmp_json),
            ]
            + (["--xdis-python", args.xdis_python] if args.xdis_python else []),
            timeout=cmp_timeout,
        )
        if proc.returncode != 0:
            die(proc.stderr.strip() or proc.stdout.strip() or f"decompyle3 compare_dir failed (out_root={out_root})")

        pez_decomp = read_json(pez_decomp_json)
        pez_cmp = read_json(pez_cmp_json)
        decomp_decomp = read_json(decomp_decomp_json)
        decomp_cmp = read_json(decomp_cmp_json)

        if pez_decomp.get("counts", {}).get("error", 0) != 0:
            die(f"pez decompile error: {first_decompile_err(pez_decomp)} (report={pez_decomp_json})")
        if decomp_decomp.get("counts", {}).get("error", 0) != 0:
            die(f"decompyle3 decompile error: {first_decompile_err(decomp_decomp)} (report={decomp_decomp_json})")

        pez_cmp_counts = (pez_cmp.get("summary") or {}).get("counts") or {}
        if pez_cmp_counts.get("error", 0) != 0:
            die(f"pez compare error: {first_compare_err(pez_cmp)} (report={pez_cmp_json})")
        if pez_cmp_counts.get("missing_src", 0) != 0:
            die(f"pez compare missing_src: {first_missing_src(pez_cmp)} (report={pez_cmp_json})")

        decomp_cmp_counts = (decomp_cmp.get("summary") or {}).get("counts") or {}
        if decomp_cmp_counts.get("error", 0) != 0:
            die(f"decompyle3 compare error: {first_compare_err(decomp_cmp)} (report={decomp_cmp_json})")
        if decomp_cmp_counts.get("missing_src", 0) != 0:
            die(f"decompyle3 compare missing_src: {first_missing_src(decomp_cmp)} (report={decomp_cmp_json})")

        out = {
            "orig_dir": str(orig_root),
            "out_root": str(out_root),
            "pez": {
                "decompile_counts": pez_decomp.get("counts", {}),
                "compare_counts": pez_cmp.get("summary", {}).get("counts", {}),
                "decompile_report": str(pez_decomp_json),
                "compare_report": str(pez_cmp_json),
            },
            "decompyle3": {
                "decompile_counts": decomp_decomp.get("counts", {}),
                "compare_counts": decomp_cmp.get("summary", {}).get("counts", {}),
                "decompile_report": str(decomp_decomp_json),
                "compare_report": str(decomp_cmp_json),
            },
        }

        payload = json.dumps(out, indent=2)
        if args.out:
            out_path = Path(args.out)
            out_path.parent.mkdir(parents=True, exist_ok=True)
            out_path.write_text(payload)
        else:
            print(payload)
        ok = True
    finally:
        if owns_root and ok:
            shutil.rmtree(out_root)


if __name__ == "__main__":
    main()
