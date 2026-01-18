#!/usr/bin/env python3
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Optional, Tuple


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
