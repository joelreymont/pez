#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib import compile_source, pick_xdis_python, select_compile_python


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--orig", required=True, help="Path to original .pyc")
    p.add_argument("--src", required=True, help="Path to decompiled .py source")
    p.add_argument("--path", required=True, help="Code object path (e.g. <module>.func)")
    p.add_argument("--py", default=sys.executable, help="Python interpreter to compile source")
    p.add_argument("--xdis-python", default="", help="Python interpreter with xdis installed")
    p.add_argument("--timeout", type=int, default=120, help="Timeout seconds")
    p.add_argument("--context", type=int, default=8, help="Instruction context window")
    p.add_argument("--code-path", default="", help="Override code path for cfg lookup")
    p.add_argument("--out", default="", help="Write JSON to this path")
    p.add_argument("--keep-temp", action="store_true", help="Keep temp dir")
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


def find_code_by_path(code, target: str):
    matches = []

    def walk(obj, path):
        if path == target or path.endswith("." + target):
            matches.append((path, obj))
        for c in obj.co_consts:
            if hasattr(c, "co_code"):
                walk(c, path + "." + c.co_name)

    walk(code, code.co_name)
    if not matches:
        return None, []
    if len(matches) == 1:
        return matches[0], matches
    exact = [m for m in matches if m[0] == target]
    if len(exact) == 1:
        return exact[0], matches
    return None, matches


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


def strip_module(path: str) -> str:
    if path == "<module>":
        return ""
    if path.startswith("<module>."):
        return path[len("<module>.") :]
    return path


def run_dump_view(pyc: Path, code_path: str, timeout: int) -> list:
    args = [
        sys.executable,
        str(Path(__file__).resolve().parent.parent / "dump_view.py"),
        "--pyc",
        str(pyc),
        "--section",
        "cfg",
    ]
    if code_path:
        args += ["--code-path", code_path]
    proc = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        raise SystemExit(proc.returncode)
    return json.loads(proc.stdout)


def block_for_offset(blocks: list, offset: int) -> int:
    for blk in blocks:
        start = blk.get("start_offset")
        end = blk.get("end_offset")
        if start is None or end is None:
            continue
        if start <= offset < end:
            return int(blk["id"])
    return -1


def main() -> None:
    args = parse_args()
    ensure_xdis(args)

    import analyze_xdis as ax
    from xdis import op_imports
    from xdis.bytecode import Bytecode

    orig = Path(args.orig)
    src = Path(args.src)
    if not orig.exists():
        raise SystemExit(f"missing: {orig}")
    if not src.exists():
        raise SystemExit(f"missing: {src}")

    orig_ver, orig_code = ax.load_code(str(orig))
    orig_ver_list = list(orig_ver)

    orig_match, _ = find_code_by_path(orig_code, args.path)
    if not orig_match:
        raise SystemExit(f"ambiguous or missing path: {args.path}")
    orig_path, orig_unit = orig_match

    py = select_compile_python(args.py, tuple(orig_ver_list[:2]), args.timeout)
    tmpdir = Path(tempfile.mkdtemp(prefix="pez-locate-"))
    compiled_pyc = tmpdir / "compiled.pyc"
    compile_source(py, src, compiled_pyc, args.timeout, orig_code.co_filename)

    comp_ver, comp_code = ax.load_code(str(compiled_pyc))
    comp_ver_list = list(comp_ver)
    comp_match, _ = find_code_by_path(comp_code, orig_path)
    if not comp_match:
        raise SystemExit(f"missing compiled path: {orig_path}")
    comp_path, comp_unit = comp_match

    orig_opc = op_imports.get_opcode_module(orig_ver)
    comp_opc = op_imports.get_opcode_module(comp_ver)

    orig_instrs = list(Bytecode(orig_unit, orig_opc))
    comp_instrs = list(Bytecode(comp_unit, comp_opc))

    orig_list = inst_dump(orig_instrs)
    comp_list = inst_dump(comp_instrs)

    max_len = min(len(orig_list), len(comp_list))
    mismatch = None
    for i in range(max_len):
        oa = orig_list[i]
        ob = comp_list[i]
        if (oa["op"], oa["argrepr"]) != (ob["op"], ob["argrepr"]):
            mismatch = i
            break
    if mismatch is None and len(orig_list) != len(comp_list):
        mismatch = max_len

    code_path = args.code_path or strip_module(orig_path)
    orig_cfg = run_dump_view(orig, code_path, args.timeout)
    comp_cfg = run_dump_view(compiled_pyc, code_path, args.timeout)

    def annotate(seq, blocks, idx):
        if idx < 0 or idx >= len(seq):
            return None
        inst = seq[idx]
        block_id = block_for_offset(blocks, inst["offset"])
        out = dict(inst)
        out["index"] = idx
        out["block"] = block_id
        return out

    ctx = args.context
    ctx_start = max(0, (mismatch or 0) - ctx)
    ctx_end = max(ctx_start, min(len(orig_list), len(comp_list), (mismatch or 0) + ctx + 1))

    payload = {
        "path": orig_path,
        "compiled_path": comp_path,
        "orig_version": orig_ver_list,
        "compiled_version": comp_ver_list,
        "mismatch_index": mismatch,
        "orig": annotate(orig_list, orig_cfg, mismatch) if mismatch is not None else None,
        "comp": annotate(comp_list, comp_cfg, mismatch) if mismatch is not None else None,
        "orig_context": [
            annotate(orig_list, orig_cfg, i) for i in range(ctx_start, min(ctx_end, len(orig_list)))
        ],
        "comp_context": [
            annotate(comp_list, comp_cfg, i) for i in range(ctx_start, min(ctx_end, len(comp_list)))
        ],
        "compiled_pyc": str(compiled_pyc),
    }

    if not args.keep_temp:
        try:
            for child in tmpdir.iterdir():
                child.unlink()
            tmpdir.rmdir()
        except Exception:
            pass

    if args.out:
        Path(args.out).write_text(json.dumps(payload, indent=2))
    else:
        print(json.dumps(payload, indent=2))


if __name__ == "__main__":
    main()
