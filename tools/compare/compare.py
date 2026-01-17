#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from difflib import SequenceMatcher
from pathlib import Path


IGNORE_OPS = {
    "CACHE",
    "EXTENDED_ARG",
    "NOP",
    "RESUME",
    "COPY_FREE_VARS",
}

CONST_OPS = {
    "LOAD_CONST",
    "LOAD_SMALL_INT",
    "LOAD_BIG_INT",
}

NAME_OPS = {
    "LOAD_NAME",
    "STORE_NAME",
    "LOAD_GLOBAL",
    "STORE_GLOBAL",
    "LOAD_FAST",
    "STORE_FAST",
    "LOAD_FAST_CHECK",
    "LOAD_FAST_BORROW",
    "STORE_FAST_MAYBE_NULL",
    "LOAD_DEREF",
    "STORE_DEREF",
}

JUMP_OPS_PREFIX = (
    "JUMP",
    "POP_JUMP",
    "JUMP_IF",
    "FOR_ITER",
)


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
    p.add_argument("--timeout", type=int, default=30, help="Timeout seconds per step")
    p.add_argument("--out", default="", help="Write JSON report to this path")
    p.add_argument("--keep-temp", action="store_true", help="Keep temp files")
    p.add_argument("--min-unit-ratio", type=float, default=0.90, help="Min per-unit seq ratio")
    p.add_argument("--avg-ratio", type=float, default=0.97, help="Min average seq ratio")
    p.add_argument("--min-count-jaccard", type=float, default=0.95, help="Min avg opcode-count Jaccard")
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


def pick_xdis_python(arg: str, timeout: int) -> str:
    if arg:
        return arg
    candidate = "/private/tmp/uncompyle6-venv312/bin/python"
    if Path(candidate).exists() and check_xdis(candidate, timeout):
        return candidate
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
    helper = r"""
import json
import sys
from xdis import load
from xdis import op_imports
from xdis.bytecode import Bytecode

IGNORE = set(""" + json.dumps(sorted(IGNORE_OPS)) + r""")
CONST_OPS = set(""" + json.dumps(sorted(CONST_OPS)) + r""")
NAME_OPS = set(""" + json.dumps(sorted(NAME_OPS)) + r""")
JUMP_PREFIX = """ + json.dumps(list(JUMP_OPS_PREFIX)) + r"""

def norm_arg(opname, argval, argrepr):
    if opname in CONST_OPS:
        if argval is None:
            return "const:none"
        t = type(argval).__name__
        if t == "code" or t.startswith("Code"):
            return "const:code"
        if t in ("int", "float", "complex", "str", "bytes", "bool"):
            return "const:" + t
        return "const:other"
    if opname in NAME_OPS:
        return "name"
    for p in JUMP_PREFIX:
        if opname.startswith(p):
            return "jump"
    if opname == "COMPARE_OP":
        return "cmp:" + str(argrepr)
    if argrepr is None:
        return ""
    return "arg"

def walk(code, opc, path, out):
    ops = []
    norm_ops = []
    counts = {}
    for ins in Bytecode(code, opc):
        opname = ins.opname
        if opname in IGNORE:
            continue
        ops.append(opname)
        narg = norm_arg(opname, getattr(ins, "argval", None), getattr(ins, "argrepr", None))
        norm_ops.append(opname + (":" + narg if narg else ""))
        counts[opname] = counts.get(opname, 0) + 1
    out.append({"path": path, "ops": ops, "norm_ops": norm_ops, "counts": counts})
    for c in code.co_consts:
        if hasattr(c, "co_code"):
            walk(c, opc, path + "." + c.co_name, out)

def main():
    pyc = sys.argv[1]
    res = load.load_module(pyc)
    ver = res[0]
    code = res[3]
    try:
        from xdis.op_imports import PythonImplementation
    except Exception:
        PythonImplementation = None

    if PythonImplementation is None:
        opc = op_imports.get_opcode_module(ver)
    else:
        impl = None
        for item in res:
            if isinstance(item, PythonImplementation):
                impl = item
                break
        if impl is None:
            impl = PythonImplementation.CPython
        opc = op_imports.get_opcode_module(ver, impl)
    out = []
    walk(code, opc, code.co_name, out)
    print(json.dumps({"version": list(ver), "units": out}))

if __name__ == "__main__":
    main()
"""
    proc = run_cmd([xdis_py, "-c", helper, str(pyc_path)], timeout)
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
        compiled_pyc = tmpdir / "compiled.pyc"
        compile_source(args.py, src, compiled_pyc, args.timeout)

        orig_data = disassemble_with_xdis(xdis_py, orig, args.timeout)
        comp_data = disassemble_with_xdis(xdis_py, compiled_pyc, args.timeout)

        comp_map = {u["path"]: u for u in comp_data["units"]}
        rows = []
        total_ratio = 0.0
        total_jaccard = 0.0
        total_count = 0
        missing = []
        min_ratio = 1.0
        min_jaccard = 1.0
        exact_units = 0
        for unit in orig_data["units"]:
            path = unit["path"]
            other = comp_map.get(path)
            if other is None:
                missing.append(path)
                continue
            ratio = seq_ratio(unit["norm_ops"], other["norm_ops"])
            jac = count_jaccard(unit["counts"], other["counts"])
            exact = unit["norm_ops"] == other["norm_ops"]
            total_ratio += ratio
            total_jaccard += jac
            total_count += 1
            if ratio < min_ratio:
                min_ratio = ratio
            if jac < min_jaccard:
                min_jaccard = jac
            if exact:
                exact_units += 1
            rows.append(
                {
                    "path": path,
                    "len_orig": len(unit["norm_ops"]),
                    "len_comp": len(other["norm_ops"]),
                    "seq_ratio": ratio,
                    "count_jaccard": jac,
                    "exact": exact,
                }
            )

        avg_ratio = (total_ratio / total_count) if total_count else 0.0
        avg_jaccard = (total_jaccard / total_count) if total_count else 0.0
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
        ):
            verdict = "close"

        summary = {
            "orig_version": orig_data["version"],
            "compiled_version": comp_data["version"],
            "units_compared": total_count,
            "units_missing": missing,
            "avg_seq_ratio": avg_ratio,
            "avg_count_jaccard": avg_jaccard,
            "min_seq_ratio": min_ratio if total_count else 0.0,
            "min_count_jaccard": min_jaccard if total_count else 0.0,
            "exact_units": exact_units,
            "verdict": verdict,
            "thresholds": {
                "avg_ratio": args.avg_ratio,
                "min_unit_ratio": args.min_unit_ratio,
                "min_count_jaccard": args.min_count_jaccard,
            },
        }

        report = {"summary": summary, "rows": rows}
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
