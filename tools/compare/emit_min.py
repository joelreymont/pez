#!/usr/bin/env python3
import argparse
import ast
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib import compile_source, find_code_by_path, norm_argrepr, pick_xdis_python, select_compile_python


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--orig", required=True, help="Path to original .pyc")
    p.add_argument("--src", required=True, help="Path to decompiled .py source")
    p.add_argument("--path", required=True, help="Code object path (e.g. <module>.func)")
    p.add_argument("--index", type=int, default=-1, help="Path index if duplicates exist")
    p.add_argument("--py", default=sys.executable, help="Python interpreter to compile source")
    p.add_argument("--xdis-python", default="", help="Python interpreter with xdis installed")
    p.add_argument("--timeout", type=int, default=120, help="Timeout seconds")
    p.add_argument("--out", default="", help="Write minimized source to this path")
    p.add_argument("--stats-out", default="", help="Write JSON stats to this path")
    p.add_argument("--max-iter", type=int, default=200, help="Max ddmin iterations")
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


def inst_key(inst):
    return inst.opname, norm_argrepr(inst.argrepr)


def target_parts(path: str) -> list[str]:
    if path.startswith("<module>."):
        path = path[len("<module>.") :]
    if path == "<module>":
        return []
    return [p for p in path.split(".") if p]


def find_target(module: ast.Module, parts: list[str]):
    node = module
    parents = [module]
    for name in parts:
        found = None
        body = getattr(node, "body", [])
        for item in body:
            if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and item.name == name:
                found = item
                break
        if found is None:
            return None, []
        node = found
        parents.append(node)
    return node, parents


def is_future_import(node: ast.stmt) -> bool:
    if not isinstance(node, ast.ImportFrom):
        return False
    return node.module == "__future__"


def module_docstring_index(mod: ast.Module) -> int:
    if not mod.body:
        return -1
    first = mod.body[0]
    if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant) and isinstance(first.value.value, str):
        return 0
    return -1


def build_module(mod: ast.Module, keep_idx: set[int]) -> ast.Module:
    body = []
    for i, node in enumerate(mod.body):
        if i in keep_idx:
            body.append(node)
    return ast.Module(body=body, type_ignores=[])


def same_unit(
    orig_code,
    orig_ver,
    orig_opc,
    src_path: Path,
    path: str,
    index,
    py: str,
    timeout: int,
) -> bool:
    import analyze_xdis as ax
    from xdis import op_imports
    from xdis.bytecode import Bytecode

    tmpdir = Path(tempfile.mkdtemp(prefix="pez-emit-min-"))
    compiled_pyc = tmpdir / "compiled.pyc"
    try:
        compile_source(py, src_path, compiled_pyc, timeout, orig_code.co_filename)
        comp_ver, comp_code = ax.load_code(str(compiled_pyc))
        if list(comp_ver) != list(orig_ver):
            return False
        comp_opc = op_imports.get_opcode_module(comp_ver)
        orig_match, _ = find_code_by_path(orig_code, path, index)
        if not orig_match:
            return False
        orig_path, orig_unit = orig_match
        comp_match, _ = find_code_by_path(comp_code, orig_path, index)
        if not comp_match:
            return False
        _, comp_unit = comp_match
        orig_instrs = list(Bytecode(orig_unit, orig_opc))
        comp_instrs = list(Bytecode(comp_unit, comp_opc))
        if len(orig_instrs) != len(comp_instrs):
            return False
        for a, b in zip(orig_instrs, comp_instrs):
            if inst_key(a) != inst_key(b):
                return False
        return True
    finally:
        try:
            for child in tmpdir.iterdir():
                child.unlink()
            tmpdir.rmdir()
        except Exception:
            pass


def ddmin(
    orig_code,
    orig_ver,
    orig_opc,
    module: ast.Module,
    keep_idx: set[int],
    removable: list[int],
    path: str,
    index,
    py: str,
    timeout: int,
    max_iter: int,
) -> tuple[ast.Module, int]:
    n = 2
    iters = 0
    removable = list(removable)
    while removable and iters < max_iter:
        iters += 1
        subsets = []
        size = max(1, len(removable) // n)
        for i in range(0, len(removable), size):
            subsets.append(removable[i : i + size])

        removed = False
        for subset in subsets:
            cand_keep = set(keep_idx)
            for idx in removable:
                if idx in subset:
                    continue
                cand_keep.add(idx)
            cand_mod = build_module(module, cand_keep)
            src_text = ast.unparse(cand_mod)
            tmp_src = Path(tempfile.mkstemp(prefix="pez-min-", suffix=".py")[1])
            try:
                tmp_src.write_text(src_text)
                if same_unit(orig_code, orig_ver, orig_opc, tmp_src, path, index, py, timeout):
                    removable = [i for i in removable if i not in subset]
                    removed = True
                    n = 2
                    break
            finally:
                try:
                    tmp_src.unlink()
                except Exception:
                    pass
        if not removed:
            if n >= len(removable):
                break
            n = min(len(removable), n * 2)
    final_keep = set(keep_idx) | set(removable)
    return build_module(module, final_keep), iters


def main() -> None:
    args = parse_args()
    ensure_xdis(args)

    import analyze_xdis as ax

    orig = Path(args.orig)
    src = Path(args.src)
    if not orig.exists():
        raise SystemExit(f"missing: {orig}")
    if not src.exists():
        raise SystemExit(f"missing: {src}")

    orig_ver, orig_code = ax.load_code(str(orig))
    orig_opc = ax.op_imports.get_opcode_module(orig_ver)
    orig_ver_list = list(orig_ver)
    py = select_compile_python(args.py, tuple(orig_ver_list[:2]), args.timeout)
    idx = args.index if args.index >= 0 else None
    orig_match, _ = find_code_by_path(orig_code, args.path, idx)
    if not orig_match:
        raise SystemExit(f"ambiguous or missing path: {args.path}")

    text = src.read_text()
    module = ast.parse(text)
    parts = target_parts(args.path)
    target, parents = find_target(module, parts)
    if target is None and args.path != "<module>":
        raise SystemExit(f"missing target: {args.path}")

    keep_idx = set()
    doc_idx = module_docstring_index(module)
    if doc_idx >= 0:
        keep_idx.add(doc_idx)
    for i, node in enumerate(module.body):
        if is_future_import(node):
            keep_idx.add(i)

    if parts:
        top = parents[1] if len(parents) > 1 else target
        for i, node in enumerate(module.body):
            if node is top:
                keep_idx.add(i)
                break

    removable = [i for i in range(len(module.body)) if i not in keep_idx]
    if not removable:
        out_path = Path(args.out) if args.out else src.with_suffix(".min.py")
        out_path.write_text(text)
        if args.stats_out:
            Path(args.stats_out).write_text(json.dumps({"iterations": 0, "removed": 0}, indent=2))
        return

    minimized, iters = ddmin(
        orig_code,
        orig_ver,
        orig_opc,
        module,
        keep_idx,
        removable,
        args.path,
        idx,
        py,
        args.timeout,
        args.max_iter,
    )

    out_text = ast.unparse(minimized)
    out_path = Path(args.out) if args.out else src.with_suffix(".min.py")
    out_path.write_text(out_text)

    if args.stats_out:
        removed = len(module.body) - len(minimized.body)
        Path(args.stats_out).write_text(json.dumps({"iterations": iters, "removed": removed}, indent=2))


if __name__ == "__main__":
    main()
