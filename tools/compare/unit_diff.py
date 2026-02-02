#!/usr/bin/env python3
import argparse
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib import collect_paths, compile_source, find_code_by_path, pick_xdis_python, select_compile_python


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--orig", required=True, help="Path to original .pyc")
    p.add_argument("--src", required=True, help="Path to decompiled .py source")
    p.add_argument("--path", default="", help="Code object path (e.g. <module>.func)")
    p.add_argument("--index", type=int, default=-1, help="Path index if duplicates exist")
    p.add_argument("--list", action="store_true", help="List available code paths")
    p.add_argument("--no-insts", action="store_true", help="Skip raw instruction dumps")
    p.add_argument("--py", default=sys.executable, help="Python interpreter to compile source")
    p.add_argument("--xdis-python", default="", help="Python interpreter with xdis installed")
    p.add_argument("--timeout", type=int, default=120, help="Timeout seconds")
    p.add_argument("--out", default="", help="Write JSON report to this path")
    return p.parse_args()


def ensure_xdis(args: argparse.Namespace) -> None:
    try:
        import xdis  # noqa: F401
        return
    except Exception:
        xdis_py = pick_xdis_python(args.xdis_python, args.timeout)
        if not xdis_py:
            raise SystemExit("xdis not found; set --xdis-python or install xdis")
        os.execv(xdis_py, [xdis_py, str(Path(__file__).resolve())] + sys.argv[1:])


def inst_dump(instrs):
    out = []
    for ins in instrs:
        out.append(
            {
                "offset": ins.offset,
                "op": ins.opname,
                "arg": ins.arg or 0,
                "argrepr": ins.argrepr,
            }
        )
    return out


def main() -> None:
    args = parse_args()
    ensure_xdis(args)

    import analyze_xdis as ax
    from lib import get_opc
    from xdis.bytecode import Bytecode

    orig_ver, orig_code, orig_impl = ax.load_code(args.orig)
    orig_ver_list = list(orig_ver)

    if args.list:
        paths = collect_paths(orig_code)
        if args.out:
            Path(args.out).write_text(json.dumps({"paths": paths}, indent=2))
        else:
            for p in paths:
                print(p)
        return

    if not args.path:
        raise SystemExit("missing --path (use --list to see code paths)")

    idx = args.index if args.index >= 0 else None
    orig_match, orig_matches = find_code_by_path(orig_code, args.path, idx)
    if not orig_match:
        raise SystemExit(f"ambiguous or missing path: {args.path}")
    orig_path, orig_unit = orig_match

    py = select_compile_python(args.py, tuple(orig_ver_list[:2]), args.timeout)
    tmpdir = Path(tempfile.mkdtemp(prefix="pez-unit-diff-"))
    compiled_pyc = tmpdir / "compiled.pyc"
    compile_source(py, Path(args.src), compiled_pyc, args.timeout, orig_code.co_filename)

    comp_ver, comp_code, comp_impl = ax.load_code(str(compiled_pyc))
    comp_ver_list = list(comp_ver)
    comp_match, comp_matches = find_code_by_path(comp_code, orig_path, idx)
    if not comp_match:
        raise SystemExit(f"missing compiled path: {orig_path}")
    comp_path, comp_unit = comp_match

    orig_opc = get_opc(orig_ver, orig_impl)
    comp_opc = get_opc(comp_ver, comp_impl)

    orig_instrs = list(Bytecode(orig_unit, orig_opc))
    comp_instrs = list(Bytecode(comp_unit, comp_opc))

    orig_norm = ax.normalize_instructions(orig_instrs)
    comp_norm = ax.normalize_instructions(comp_instrs)

    orig_norm_ops = [
        ax.seq_token(ins.opname, ax.norm_arg(ins.opname, ins.argval, ins.argrepr, ins.arg or 0))
        for ins in orig_norm
    ]
    comp_norm_ops = [
        ax.seq_token(ins.opname, ax.norm_arg(ins.opname, ins.argval, ins.argrepr, ins.arg or 0))
        for ins in comp_norm
    ]

    orig_unit_dump = ax.analyze_code(orig_unit, orig_opc, orig_path)
    comp_unit_dump = ax.analyze_code(comp_unit, comp_opc, comp_path)

    out = {
        "path": orig_path,
        "index": idx,
        "orig_version": orig_ver_list,
        "compiled_version": comp_ver_list,
        "orig_unit": orig_unit_dump,
        "comp_unit": comp_unit_dump,
        "orig_norm_ops": orig_norm_ops,
        "comp_norm_ops": comp_norm_ops,
    }

    if not args.no_insts:
        out["orig_insts"] = inst_dump(orig_instrs)
        out["comp_insts"] = inst_dump(comp_instrs)

    payload = json.dumps(out, indent=2)
    if args.out:
        Path(args.out).write_text(payload)
    else:
        print(payload)


if __name__ == "__main__":
    main()
