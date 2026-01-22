#!/usr/bin/env python3
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
COMPARE = ROOT / "tools" / "compare" / "compare.py"
COMPARE_DIR = ROOT / "tools" / "compare" / "compare_dir.py"
ANALYZE = ROOT / "tools" / "compare" / "analyze_xdis.py"
UNIT_DIFF = ROOT / "tools" / "compare" / "unit_diff.py"
def resolve_py39():
    env = os.environ.get("PEZ_PY39")
    if env:
        return Path(env)
    exe = shutil.which("python3.9")
    if exe:
        return Path(exe)
    return None


def has_xdis(py: str) -> bool:
    proc = subprocess.run([py, "-c", "import xdis"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return proc.returncode == 0


def resolve_xdis_py():
    env = os.environ.get("PEZ_XDIS_PY")
    if env:
        return Path(env)
    if has_xdis(sys.executable):
        return Path(sys.executable)
    exe = shutil.which("python3")
    if exe and has_xdis(exe):
        return Path(exe)
    return None


XDIS_PY = resolve_xdis_py()
PY39 = resolve_py39()


def run(cmd, env=None):
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "command failed")
    return proc.stdout


def compile_src(py, src, out_pyc):
    code = "import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)"
    run([str(py), "-c", code, str(src), str(out_pyc)])


def test_analyze_xdis(tmpdir: Path):
    src = tmpdir / "m.py"
    src.write_text("def f(x):\n    return x + 1\n")
    pyc = tmpdir / "m.pyc"
    compile_src(PY39, src, pyc)
    out = run([str(XDIS_PY), str(ANALYZE), str(pyc)])
    data = json.loads(out)
    assert "version" in data and "units" in data
    assert len(data["units"]) >= 1
    unit = data["units"][0]
    assert "block_sig_counts" in unit
    assert "edge_sig_counts" in unit
    assert "cfg_sig" in unit
    assert unit["cfg_sig"]["block_count"] >= 1


def test_analyze_xdis_marshal(tmpdir: Path):
    src = tmpdir / "m_marshal.py"
    src.write_text("def f(x):\n    return x - 1\n")
    pyc = tmpdir / "m_marshal.pyc"
    compile_src(PY39, src, pyc)
    env = dict(os.environ, PEZ_COMPARE_FORCE_MARSHAL="1")
    out = run([str(XDIS_PY), str(ANALYZE), str(pyc)], env=env)
    data = json.loads(out)
    assert "version" in data and "units" in data
    assert len(data["units"]) >= 1
    unit = data["units"][0]
    assert "block_sig_counts" in unit
    assert "edge_sig_counts" in unit
    assert "cfg_sig" in unit
    assert unit["cfg_sig"]["block_count"] >= 1


def test_compare_exact(tmpdir: Path):
    src = tmpdir / "m2.py"
    src.write_text("def g(y):\n    if y:\n        return 2\n    return 3\n")
    pyc = tmpdir / "m2.pyc"
    compile_src(PY39, src, pyc)
    out = run([
        sys.executable,
        str(COMPARE),
        "--orig",
        str(pyc),
        "--src",
        str(src),
        "--py",
        str(PY39),
        "--xdis-python",
        str(XDIS_PY),
    ])
    data = json.loads(out)
    assert data["summary"]["units_compared"] >= 1
    assert data["verdict"] in ("exact", "close")


def test_compare_auto_py(tmpdir: Path):
    src = tmpdir / "m_auto.py"
    src.write_text("def k(a, b):\n    return a + b\n")
    pyc = tmpdir / "m_auto.pyc"
    compile_src(PY39, src, pyc)
    out = run(
        [
            sys.executable,
            str(COMPARE),
            "--orig",
            str(pyc),
            "--src",
            str(src),
            "--xdis-python",
            str(XDIS_PY),
        ]
    )
    data = json.loads(out)
    assert data["summary"]["units_compared"] >= 1
    assert data["verdict"] in ("exact", "close", "mismatch")


def test_compare_dir_outdir(tmpdir: Path):
    orig_root = tmpdir / "orig"
    src_root = tmpdir / "src"
    orig_root.mkdir()
    src_root.mkdir()
    src = src_root / "m3.py"
    src.write_text("def h(z):\n    return z * 2\n")
    pyc = orig_root / "m3.pyc"
    compile_src(PY39, src, pyc)
    out_path = tmpdir / "reports" / "summary.json"
    run(
        [
            sys.executable,
            str(COMPARE_DIR),
            "--orig-dir",
            str(orig_root),
            "--src-dir",
            str(src_root),
            "--py",
            str(PY39),
            "--xdis-python",
            str(XDIS_PY),
            "--out",
            str(out_path),
        ]
    )
    assert out_path.exists()
    data = json.loads(out_path.read_text())
    assert data["summary"]["total"] == 1


def test_unit_diff(tmpdir: Path):
    src = tmpdir / "m_unit.py"
    src.write_text("def f(x):\n    return x * 3\n")
    pyc = tmpdir / "m_unit.pyc"
    compile_src(PY39, src, pyc)
    out = run(
        [
            str(XDIS_PY),
            str(UNIT_DIFF),
            "--orig",
            str(pyc),
            "--src",
            str(src),
            "--path",
            "<module>.f",
            "--xdis-python",
            str(XDIS_PY),
        ]
    )
    data = json.loads(out)
    assert data["path"] == "<module>.f"
    assert "orig_unit" in data and "comp_unit" in data


def test_unit_diff_index(tmpdir: Path):
    src = tmpdir / "m_dup.py"
    src.write_text("x = 1\nif x:\n    def f():\n        return 1\nelse:\n    def f():\n        return 2\n")
    pyc = tmpdir / "m_dup.pyc"
    compile_src(PY39, src, pyc)
    out = run(
        [
            str(XDIS_PY),
            str(UNIT_DIFF),
            "--orig",
            str(pyc),
            "--src",
            str(src),
            "--list",
            "--xdis-python",
            str(XDIS_PY),
        ]
    )
    paths = [line.strip() for line in out.splitlines() if line.strip()]
    assert paths.count("<module>.f") == 2
    for idx in (0, 1):
        out = run(
            [
                str(XDIS_PY),
                str(UNIT_DIFF),
                "--orig",
                str(pyc),
                "--src",
                str(src),
                "--path",
                "<module>.f",
                "--index",
                str(idx),
                "--xdis-python",
                str(XDIS_PY),
            ]
        )
        data = json.loads(out)
        assert data["path"] == "<module>.f"
        assert "orig_unit" in data and "comp_unit" in data


def main():
    if XDIS_PY is None or not XDIS_PY.exists():
        raise RuntimeError("missing xdis python (set PEZ_XDIS_PY or install xdis)")
    if PY39 is None or not PY39.exists():
        raise RuntimeError("missing python 3.9 (set PEZ_PY39 or install python3.9)")
    with tempfile.TemporaryDirectory(prefix="pez-compare-test-") as td:
        tmpdir = Path(td)
        test_analyze_xdis(tmpdir)
        test_analyze_xdis_marshal(tmpdir)
        test_compare_exact(tmpdir)
        test_compare_auto_py(tmpdir)
        test_compare_dir_outdir(tmpdir)
        test_unit_diff(tmpdir)
        test_unit_diff_index(tmpdir)


if __name__ == "__main__":
    main()
