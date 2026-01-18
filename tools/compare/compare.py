#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from typing import Optional, Tuple
from difflib import SequenceMatcher
from pathlib import Path



def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--orig", required=True, help="Path to original .pyc")
    p.add_argument("--src", required=True, help="Path to decompiled .py source")
    p.add_argument("--py", default=sys.executable, help="Python interpreter to compile source")
    p.add_argument(
        "--xdis-python",
        default="",
        help="Python interpreter with xdis installed (default: autodetect)",
    )
    p.add_argument("--timeout", type=int, default=120, help="Timeout seconds per step")
    p.add_argument("--out", default="", help="Write JSON report to this path")
    p.add_argument("--keep-temp", action="store_true", help="Keep temp files")
    p.add_argument("--min-unit-ratio", type=float, default=0.90, help="Min per-unit seq ratio")
    p.add_argument("--avg-ratio", type=float, default=0.97, help="Min average seq ratio")
    p.add_argument("--min-count-jaccard", type=float, default=0.95, help="Min avg opcode-count Jaccard")
    p.add_argument("--min-block-jaccard", type=float, default=0.95, help="Min avg block-signature Jaccard")
    p.add_argument("--min-edge-jaccard", type=float, default=0.95, help="Min avg edge-signature Jaccard")
    p.add_argument("--min-semantic-score", type=float, default=0.95, help="Min avg semantic score")
    return p.parse_args()


def run_cmd(cmd, timeout: int) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout,
    )


def check_xdis(python: str, timeout: int) -> bool:
    try:
        proc = run_cmd([python, "-c", "import xdis"], timeout)
        return proc.returncode == 0
    except Exception:
        return False


def python_version(py: str, timeout: int) -> Optional[Tuple[int, int]]:
    proc = run_cmd(
        [py, "-c", "import sys;print(f\"{sys.version_info.major}.{sys.version_info.minor}\")"],
        timeout,
    )
    if proc.returncode != 0:
        return None
    text = proc.stdout.strip()
    if not text:
        return None
    parts = text.split(".")
    if len(parts) < 2:
        return None
    try:
        return int(parts[0]), int(parts[1])
    except ValueError:
        return None


def find_uv_python(ver: Tuple[int, int]) -> str:
    major, minor = ver
    root = Path.home() / ".local" / "share" / "uv" / "python"
    if not root.exists():
        return ""
    prefix = f"cpython-{major}.{minor}."
    candidates = sorted([p for p in root.iterdir() if p.name.startswith(prefix)], reverse=True)
    for cand in candidates:
        exe = cand / "bin" / f"python{major}.{minor}"
        if exe.exists():
            return str(exe)
    return ""


def find_python_for_version(ver: Tuple[int, int], timeout: int) -> str:
    major, minor = ver
    for name in (f"python{major}.{minor}",):
        path = shutil.which(name)
        if path:
            return path
    uv = find_uv_python(ver)
    if uv and python_version(uv, timeout) == ver:
        return uv
    return ""


def pick_xdis_python(arg: str, timeout: int) -> str:
    if arg:
        return arg
    candidate = "/private/tmp/xdis-venv39/bin/python"
    if Path(candidate).exists() and check_xdis(candidate, timeout):
        return candidate
    candidate = "/private/tmp/uncompyle6-venv312/bin/python"
    if Path(candidate).exists() and check_xdis(candidate, timeout):
        return candidate
    for name in ("python3.9", "python3.10", "python3.11", "python3.12"):
        path = shutil.which(name)
        if path and check_xdis(path, timeout):
            return path
    if check_xdis(sys.executable, timeout):
        return sys.executable
    return ""


def compile_source(py: str, src: Path, out_pyc: Path, timeout: int) -> None:
    code = (
        "import py_compile, sys\n"
        "src = sys.argv[1]\n"
        "dst = sys.argv[2]\n"
        "py_compile.compile(src, cfile=dst, doraise=True)\n"
    )
    proc = run_cmd([py, "-c", code, str(src), str(out_pyc)], timeout)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        raise SystemExit(proc.returncode)


def disassemble_with_xdis(
    xdis_py: str,
    pyc_path: Path,
    timeout: int,
) -> dict:
    script = Path(__file__).with_name("analyze_xdis.py")
    if not script.exists():
        raise SystemExit(f"missing: {script}")
    proc = run_cmd([xdis_py, str(script), str(pyc_path)], timeout)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        raise SystemExit(proc.returncode)
    return json.loads(proc.stdout)


def seq_ratio(a, b) -> float:
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0
    return SequenceMatcher(a=a, b=b).ratio()


def count_jaccard(a: dict, b: dict) -> float:
    keys = set(a) | set(b)
    if not keys:
        return 1.0
    inter = 0
    union = 0
    for k in keys:
        av = a.get(k, 0)
        bv = b.get(k, 0)
        inter += min(av, bv)
        union += max(av, bv)
    return inter / union if union else 1.0


def multiset_jaccard(a: dict, b: dict) -> float:
    return count_jaccard(a, b)


def semantic_score(block_j: float, edge_j: float) -> float:
    return (0.4 * block_j) + (0.6 * edge_j)


def meta_diff(a: dict, b: dict) -> list:
    diffs = []
    keys = set(a) | set(b)
    for k in sorted(keys):
        if a.get(k) != b.get(k):
            diffs.append(k)
    return diffs


def counter_diff(a: dict, b: dict, limit: int = 5) -> dict:
    missing = []
    extra = []
    for k, v in a.items():
        diff = v - b.get(k, 0)
        if diff > 0:
            missing.append((k, diff))
    for k, v in b.items():
        diff = v - a.get(k, 0)
        if diff > 0:
            extra.append((k, diff))
    missing.sort(key=lambda x: -x[1])
    extra.sort(key=lambda x: -x[1])
    return {"missing": missing[:limit], "extra": extra[:limit]}


def main() -> None:
    args = parse_args()
    orig = Path(args.orig)
    src = Path(args.src)
    if not orig.exists():
        raise SystemExit(f"missing: {orig}")
    if not src.exists():
        raise SystemExit(f"missing: {src}")

    xdis_py = pick_xdis_python(args.xdis_python, args.timeout)
    if not xdis_py:
        raise SystemExit("xdis not found; set --xdis-python or install xdis")

    tmpdir = Path(tempfile.mkdtemp(prefix="pez-compare-"))
    try:
        orig_data = disassemble_with_xdis(xdis_py, orig, args.timeout)
        orig_ver = tuple(orig_data.get("version", [])[:2])

        py = args.py
        if py == sys.executable and orig_ver:
            py_ver = python_version(py, args.timeout)
            if py_ver and py_ver != orig_ver:
                alt = find_python_for_version(orig_ver, args.timeout)
                if alt:
                    py = alt

        compiled_pyc = tmpdir / "compiled.pyc"
        compile_source(py, src, compiled_pyc, args.timeout)
        comp_data = disassemble_with_xdis(xdis_py, compiled_pyc, args.timeout)

        version_mismatch = orig_data["version"] != comp_data["version"]
        if version_mismatch:
            summary = {
                "orig_version": orig_data["version"],
                "compiled_version": comp_data["version"],
                "version_mismatch": True,
                "units_compared": 0,
                "units_missing": [],
                "avg_seq_ratio": 0.0,
                "avg_count_jaccard": 0.0,
                "avg_block_jaccard": 0.0,
                "avg_edge_jaccard": 0.0,
                "avg_semantic_score": 0.0,
                "min_seq_ratio": 0.0,
                "min_count_jaccard": 0.0,
                "min_block_jaccard": 0.0,
                "min_edge_jaccard": 0.0,
                "min_semantic_score": 0.0,
                "exact_units": 0,
                "verdict": "mismatch",
                "thresholds": {
                    "avg_ratio": args.avg_ratio,
                    "min_unit_ratio": args.min_unit_ratio,
                    "min_count_jaccard": args.min_count_jaccard,
                    "min_block_jaccard": args.min_block_jaccard,
                    "min_edge_jaccard": args.min_edge_jaccard,
                    "min_semantic_score": args.min_semantic_score,
                },
            }
            report = {"verdict": "mismatch", "summary": summary, "rows": []}
            out = json.dumps(report, indent=2)
            if args.out:
                Path(args.out).write_text(out)
            else:
                print(out)
            return

        comp_map: dict[str, list[dict]] = {}
        for unit in comp_data["units"]:
            comp_map.setdefault(unit["path"], []).append(unit)
        comp_seen: dict[str, int] = {}
        rows = []
        total_ratio = 0.0
        total_jaccard = 0.0
        total_block_j = 0.0
        total_edge_j = 0.0
        total_semantic = 0.0
        total_count = 0
        missing = []
        min_ratio = 1.0
        min_jaccard = 1.0
        min_block_j = 1.0
        min_edge_j = 1.0
        min_semantic = 1.0
        exact_units = 0
        for unit in orig_data["units"]:
            path = unit["path"]
            idx = comp_seen.get(path, 0)
            comp_seen[path] = idx + 1
            candidates = comp_map.get(path)
            if not candidates or idx >= len(candidates):
                missing.append(path)
                continue
            other = candidates[idx]
            ratio = seq_ratio(unit["norm_ops"], other["norm_ops"])
            jac = count_jaccard(unit.get("op_counts", {}), other.get("op_counts", {}))
            block_counts = unit.get("block_sig_counts", {})
            edge_counts = unit.get("edge_sig_counts", {})
            other_block_counts = other.get("block_sig_counts", {})
            other_edge_counts = other.get("edge_sig_counts", {})
            block_j = multiset_jaccard(block_counts, other_block_counts)
            edge_j = multiset_jaccard(edge_counts, other_edge_counts)
            semantic = semantic_score(block_j, edge_j)
            exact = unit["norm_ops"] == other["norm_ops"]
            meta_mismatch = meta_diff(unit.get("meta", {}), other.get("meta", {}))
            block_sig_diff = counter_diff(block_counts, other_block_counts)
            edge_sig_diff = counter_diff(edge_counts, other_edge_counts)
            total_ratio += ratio
            total_jaccard += jac
            total_block_j += block_j
            total_edge_j += edge_j
            total_semantic += semantic
            total_count += 1
            if ratio < min_ratio:
                min_ratio = ratio
            if jac < min_jaccard:
                min_jaccard = jac
            if block_j < min_block_j:
                min_block_j = block_j
            if edge_j < min_edge_j:
                min_edge_j = edge_j
            if semantic < min_semantic:
                min_semantic = semantic
            if exact:
                exact_units += 1
            tier = "mismatch"
            if exact:
                tier = "exact"
            elif not meta_mismatch and block_j >= args.min_block_jaccard and edge_j >= args.min_edge_jaccard:
                tier = "semantic_equiv"
            rows.append(
                {
                    "path": path,
                    "len_orig": len(unit["norm_ops"]),
                    "len_comp": len(other["norm_ops"]),
                    "seq_ratio": ratio,
                    "count_jaccard": jac,
                    "block_jaccard": block_j,
                    "edge_jaccard": edge_j,
                    "semantic_score": semantic,
                    "exact": exact,
                    "tier": tier,
                    "meta_mismatch": meta_mismatch,
                    "cfg_sig_orig": unit.get("cfg_sig", {}),
                    "cfg_sig_comp": other.get("cfg_sig", {}),
                    "block_sig_diff": block_sig_diff,
                    "edge_sig_diff": edge_sig_diff,
                }
            )

        avg_ratio = (total_ratio / total_count) if total_count else 0.0
        avg_jaccard = (total_jaccard / total_count) if total_count else 0.0
        avg_block_j = (total_block_j / total_count) if total_count else 0.0
        avg_edge_j = (total_edge_j / total_count) if total_count else 0.0
        avg_semantic = (total_semantic / total_count) if total_count else 0.0
        verdict = "mismatch"
        if total_count == 0:
            verdict = "mismatch"
        elif missing:
            verdict = "mismatch"
        elif exact_units == total_count:
            verdict = "exact"
        elif (
            avg_ratio >= args.avg_ratio
            and min_ratio >= args.min_unit_ratio
            and avg_jaccard >= args.min_count_jaccard
            and avg_block_j >= args.min_block_jaccard
            and avg_edge_j >= args.min_edge_jaccard
            and avg_semantic >= args.min_semantic_score
        ):
            verdict = "close"

        summary = {
            "orig_version": orig_data["version"],
            "compiled_version": comp_data["version"],
            "units_compared": total_count,
            "units_missing": missing,
            "avg_seq_ratio": avg_ratio,
            "avg_count_jaccard": avg_jaccard,
            "avg_block_jaccard": avg_block_j,
            "avg_edge_jaccard": avg_edge_j,
            "avg_semantic_score": avg_semantic,
            "min_seq_ratio": min_ratio if total_count else 0.0,
            "min_count_jaccard": min_jaccard if total_count else 0.0,
            "min_block_jaccard": min_block_j if total_count else 0.0,
            "min_edge_jaccard": min_edge_j if total_count else 0.0,
            "min_semantic_score": min_semantic if total_count else 0.0,
            "exact_units": exact_units,
            "verdict": verdict,
            "thresholds": {
                "avg_ratio": args.avg_ratio,
                "min_unit_ratio": args.min_unit_ratio,
                "min_count_jaccard": args.min_count_jaccard,
                "min_block_jaccard": args.min_block_jaccard,
                "min_edge_jaccard": args.min_edge_jaccard,
                "min_semantic_score": args.min_semantic_score,
            },
        }

        report = {"verdict": verdict, "summary": summary, "rows": rows}
        out = json.dumps(report, indent=2)
        if args.out:
            Path(args.out).write_text(out)
        else:
            print(out)
    finally:
        if args.keep_temp:
            print(f"temp={tmpdir}", file=sys.stderr)
        else:
            shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == "__main__":
    main()
