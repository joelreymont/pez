#!/usr/bin/env python3
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Dict, List, Tuple


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--corpus-dirs", required=True, help="Colon-separated corpus roots")
    p.add_argument("--out", required=True, help="Output directory")
    p.add_argument("--pez", required=True, help="Path to pez binary")
    p.add_argument("--pycdc", required=True, help="Path to pycdc binary")
    p.add_argument("--uncompyle6", required=True, help="Path to uncompyle6 executable")
    p.add_argument("--decompyle3", required=True, help="Path to decompyle3 executable")
    p.add_argument("--timeout", type=int, default=30, help="Timeout seconds per tool")
    return p.parse_args()


def die(msg: str) -> None:
    sys.stderr.write(msg + "\n")
    raise SystemExit(2)


def discover_pyc_files(roots: List[Path]) -> List[Path]:
    files: List[Path] = []
    for root in roots:
        if not root.exists():
            die(f"Missing corpus dir: {root}")
        for path in root.rglob("*.pyc"):
            files.append(path)
    files.sort()
    if not files:
        die("No .pyc files found in corpus dirs")
    return files


def parse_version(path: Path) -> str:
    m = re.search(r"\.(\d+\.\d+)\.pyc$", path.name)
    if m:
        return m.group(1)
    for part in path.parts:
        if re.fullmatch(r"\d+\.\d+", part):
            return part
    return "unknown"


def run_cmd(cmd: List[str], timeout: int) -> Tuple[int, str, str]:
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired as e:
        return 124, "", f"timeout after {timeout}s"


def main() -> None:
    args = parse_args()
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    corpus_dirs = [Path(p) for p in args.corpus_dirs.split(":") if p]
    if not corpus_dirs:
        die("No corpus dirs provided")

    pez = Path(args.pez)
    pycdc = Path(args.pycdc)
    uncompyle6_bin = Path(args.uncompyle6)
    decompyle3_bin = Path(args.decompyle3)

    if not pez.exists():
        die(f"Missing pez binary: {pez}")
    if not pycdc.exists():
        die(f"Missing pycdc binary: {pycdc}")
    if not uncompyle6_bin.exists():
        die(f"Missing uncompyle6 executable: {uncompyle6_bin}")
    if not decompyle3_bin.exists():
        die(f"Missing decompyle3 executable: {decompyle3_bin}")

    files = discover_pyc_files(corpus_dirs)

    results: List[Dict[str, object]] = []
    counts = {
        "total": 0,
        "required": 0,
        "pez_ok": 0,
        "pycdc_ok": 0,
        "uncompyle6_ok": 0,
        "decompyle3_ok": 0,
        "mismatch": 0,
    }

    for path in files:
        counts["total"] += 1
        ver = parse_version(path)

        pez_cmd = [str(pez), str(path)]
        pycdc_cmd = [str(pycdc), str(path)]
        with tempfile.TemporaryDirectory() as tmpdir:
            uncomp_cmd = [str(uncompyle6_bin), "-o", tmpdir, str(path)]
            uncomp_rc, uncomp_out, uncomp_err = run_cmd(uncomp_cmd, args.timeout)
        with tempfile.TemporaryDirectory() as tmpdir:
            decompyle3_cmd = [str(decompyle3_bin), "-o", tmpdir, str(path)]
            decompyle3_rc, decompyle3_out, decompyle3_err = run_cmd(
                decompyle3_cmd, args.timeout
            )

        pez_rc, pez_out, pez_err = run_cmd(pez_cmd, args.timeout)
        pycdc_rc, pycdc_out, pycdc_err = run_cmd(pycdc_cmd, args.timeout)
        pez_ok = pez_rc == 0
        pycdc_ok = pycdc_rc == 0
        uncomp_ok = uncomp_rc == 0
        decompyle3_ok = decompyle3_rc == 0
        required = pycdc_ok or uncomp_ok or decompyle3_ok
        mismatch = required and not pez_ok

        if pez_ok:
            counts["pez_ok"] += 1
        if pycdc_ok:
            counts["pycdc_ok"] += 1
        if uncomp_ok:
            counts["uncompyle6_ok"] += 1
        if decompyle3_ok:
            counts["decompyle3_ok"] += 1
        if required:
            counts["required"] += 1
        if mismatch:
            counts["mismatch"] += 1

        results.append(
            {
                "file": str(path),
                "version": ver,
                "required": required,
                "pez": {"ok": pez_ok, "rc": pez_rc},
                "pycdc": {"ok": pycdc_ok, "rc": pycdc_rc},
                "uncompyle6": {"ok": uncomp_ok, "rc": uncomp_rc},
                "decompyle3": {"ok": decompyle3_ok, "rc": decompyle3_rc},
                "mismatch": mismatch,
                "stderr": {
                    "pez": (pez_err or "")[:2000],
                    "pycdc": (pycdc_err or "")[:2000],
                    "uncompyle6": (uncomp_err or "")[:2000],
                    "decompyle3": (decompyle3_err or "")[:2000],
                },
            }
        )

    report = {
        "counts": counts,
        "files": results,
    }

    (out_dir / "report.json").write_text(json.dumps(report, indent=2))

    md_lines = []
    md_lines.append("# Parity Report")
    md_lines.append("")
    md_lines.append(f"Total files: {counts['total']}")
    md_lines.append(f"Required (pycdc or uncompyle6 ok): {counts['required']}")
    md_lines.append(f"pez ok: {counts['pez_ok']}")
    md_lines.append(f"pycdc ok: {counts['pycdc_ok']}")
    md_lines.append(f"uncompyle6 ok: {counts['uncompyle6_ok']}")
    md_lines.append(f"decompyle3 ok: {counts['decompyle3_ok']}")
    md_lines.append(f"mismatch: {counts['mismatch']}")
    md_lines.append("")
    md_lines.append("## Mismatches")
    md_lines.append("")
    md_lines.append("| File | Version | pez | pycdc | uncompyle6 | decompyle3 |")
    md_lines.append("| --- | --- | --- | --- | --- | --- |")

    for r in results:
        if not r["mismatch"]:
            continue
        md_lines.append(
            "| {file} | {version} | {pez} | {pycdc} | {uncompyle6} | {decompyle3} |".format(
                file=r["file"],
                version=r["version"],
                pez="ok" if r["pez"]["ok"] else "fail",
                pycdc="ok" if r["pycdc"]["ok"] else "fail",
                uncompyle6="ok" if r["uncompyle6"]["ok"] else "fail",
                decompyle3="ok" if r["decompyle3"]["ok"] else "fail",
            )
        )

    (out_dir / "report.md").write_text("\n".join(md_lines) + "\n")

    if counts["mismatch"] != 0:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
