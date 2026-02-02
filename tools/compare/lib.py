#!/usr/bin/env python3
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Optional, Tuple


_CODE_ADDR_RE = re.compile(r"0x[0-9a-fA-F]+")


def run_cmd(cmd, timeout: int) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout,
    )


def norm_argrepr(argrepr: str) -> str:
    if not argrepr:
        return argrepr
    if "code object" in argrepr:
        text = _CODE_ADDR_RE.sub("0x?", argrepr)
        return re.sub(r", line \d+", ", line ?", text)
    return argrepr


def check_xdis(python: str, timeout: int) -> bool:
    try:
        proc = run_cmd([python, "-c", "import xdis"], timeout)
        return proc.returncode == 0
    except Exception:
        return False


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


def select_compile_python(requested_py: str, orig_ver: Optional[Tuple[int, int]], timeout: int) -> str:
    if not orig_ver:
        return requested_py
    if requested_py != sys.executable:
        return requested_py
    py_ver = python_version(requested_py, timeout)
    if py_ver and py_ver != orig_ver:
        alt = find_python_for_version(orig_ver, timeout)
        if alt:
            return alt
    return requested_py


def compile_source(py: str, src: Path, out_pyc: Path, timeout: int, dfile: Optional[str] = None) -> None:
    code = (
        "import py_compile, sys\n"
        "src = sys.argv[1]\n"
        "dst = sys.argv[2]\n"
        "dfile = sys.argv[3] if len(sys.argv) > 3 else None\n"
        "py_compile.compile(src, cfile=dst, dfile=dfile, doraise=True)\n"
    )
    cmd = [py, "-c", code, str(src), str(out_pyc)]
    if dfile:
        cmd.append(dfile)
    proc = run_cmd(cmd, timeout)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        raise SystemExit(proc.returncode)


def get_opc(ver, impl=None):
    from xdis import op_imports

    try:
        return op_imports.get_opcode_module(ver)
    except TypeError:
        if impl is None:
            from xdis.version_info import PythonImplementation

            impl = PythonImplementation.CPYTHON
        return op_imports.get_opcode_module(ver, impl)


def collect_paths(code) -> list[str]:
    paths: list[str] = []

    def walk(obj, path: str) -> None:
        paths.append(path)
        for c in obj.co_consts:
            if hasattr(c, "co_code"):
                walk(c, path + "." + c.co_name)

    walk(code, code.co_name)
    return paths


def find_code_by_path(code, target: str, index: Optional[int] = None):
    matches = []

    def walk(obj, path: str) -> None:
        if path == target or path.endswith("." + target):
            matches.append((path, obj))
        for c in obj.co_consts:
            if hasattr(c, "co_code"):
                walk(c, path + "." + c.co_name)

    walk(code, code.co_name)
    if not matches:
        return None, matches
    if index is not None:
        if index < 0 or index >= len(matches):
            return None, matches
        return matches[index], matches
    if len(matches) == 1:
        return matches[0], matches
    exact = [m for m in matches if m[0] == target]
    if len(exact) == 1:
        return exact[0], matches
    return None, matches
