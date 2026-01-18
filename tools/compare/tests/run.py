#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
COMPARE = ROOT / "tools" / "compare" / "compare.py"
COMPARE_DIR = ROOT / "tools" / "compare" / "compare_dir.py"
ANALYZE = ROOT / "tools" / "compare" / "analyze_xdis.py"
XDIS_PY = Path("/private/tmp/xdis-venv39/bin/python")
PY39 = Path("/Users/joel/.local/share/uv/python/cpython-3.9.24-macos-aarch64-none/bin/python3.9")


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


def main():
    if not XDIS_PY.exists():
        raise RuntimeError("missing xdis python")
    if not PY39.exists():
        raise RuntimeError("missing python 3.9")
    with tempfile.TemporaryDirectory(prefix="pez-compare-test-") as td:
        tmpdir = Path(td)
        test_analyze_xdis(tmpdir)
        test_analyze_xdis_marshal(tmpdir)
        test_compare_exact(tmpdir)
        test_compare_auto_py(tmpdir)
        test_compare_dir_outdir(tmpdir)


if __name__ == "__main__":
    main()
