#!/usr/bin/env python3
import argparse
import json
import sys
import tempfile
from pathlib import Path
from difflib import SequenceMatcher

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib import compile_source, pick_xdis_python, run_cmd, select_compile_python


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--orig", required=True, help="Path to original .pyc")
    p.add_argument("--src", required=True, help="Path to decompiled .py source")
    p.add_argument("--path", required=True, help="Code object path (e.g. <module>.func)")
    p.add_argument("--index", type=int, default=0, help="Path index if duplicates exist")
    p.add_argument("--py", default=sys.executable, help="Python interpreter to compile source")
    p.add_argument("--xdis-python", default="", help="Python interpreter with xdis installed")
    p.add_argument("--timeout", type=int, default=120, help="Timeout seconds")
    p.add_argument("--out", default="", help="Write JSON report to this path")
    return p.parse_args()


def disassemble_with_xdis(xdis_py: str, pyc_path: Path, timeout: int) -> dict:
    script = Path(__file__).with_name("analyze_xdis.py")
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


def counter_diff(a: dict, b: dict, limit: int = 8) -> dict:
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


def pick_unit(units: list[dict], path: str, index: int) -> dict:
    matches = [u for u in units if u.get("path") == path]
    if not matches:
        raise SystemExit(f"path not found: {path}")
    if index < 0 or index >= len(matches):
        raise SystemExit(f"invalid index {index} for path {path} (count {len(matches)})")
    return matches[index]


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

    tmpdir = Path(tempfile.mkdtemp(prefix="pez-unit-trace-"))
    try:
        orig_data = disassemble_with_xdis(xdis_py, orig, args.timeout)
        ver_list = orig_data.get("version", [])
        orig_ver = tuple(ver_list[:2]) if len(ver_list) >= 2 else None
        py = select_compile_python(args.py, orig_ver, args.timeout)

        compiled_pyc = tmpdir / "compiled.pyc"
        orig_filename = orig_data.get("filename")
        compile_source(py, src, compiled_pyc, args.timeout, orig_filename)
        comp_data = disassemble_with_xdis(xdis_py, compiled_pyc, args.timeout)

        orig_unit = pick_unit(orig_data["units"], args.path, args.index)
        comp_unit = pick_unit(comp_data["units"], args.path, args.index)

        metrics = {
            "seq_ratio": seq_ratio(orig_unit.get("norm_ops", []), comp_unit.get("norm_ops", [])),
            "count_jaccard": count_jaccard(orig_unit.get("op_counts", {}), comp_unit.get("op_counts", {})),
            "block_jaccard": count_jaccard(orig_unit.get("block_sig_counts", {}), comp_unit.get("block_sig_counts", {})),
            "edge_jaccard": count_jaccard(orig_unit.get("edge_sig_counts", {}), comp_unit.get("edge_sig_counts", {})),
        }
        metrics["semantic_score"] = (0.4 * metrics["block_jaccard"]) + (0.6 * metrics["edge_jaccard"])

        report = {
            "path": args.path,
            "index": args.index,
            "orig_meta": orig_unit.get("meta", {}),
            "comp_meta": comp_unit.get("meta", {}),
            "metrics": metrics,
            "block_sig_diff": counter_diff(
                orig_unit.get("block_sig_counts", {}),
                comp_unit.get("block_sig_counts", {}),
            ),
            "edge_sig_diff": counter_diff(
                orig_unit.get("edge_sig_counts", {}),
                comp_unit.get("edge_sig_counts", {}),
            ),
            "orig_blocks": orig_unit.get("block_sigs", []),
            "comp_blocks": comp_unit.get("block_sigs", []),
        }
        out_text = json.dumps(report, indent=2)
        if args.out:
            Path(args.out).write_text(out_text)
        else:
            print(out_text)
    finally:
        try:
            for child in tmpdir.iterdir():
                child.unlink()
            tmpdir.rmdir()
        except Exception:
            pass


if __name__ == "__main__":
    main()
