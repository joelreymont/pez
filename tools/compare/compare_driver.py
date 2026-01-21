#!/usr/bin/env python3
import argparse
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib import run_cmd


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--orig", required=True, help="Path to original .pyc")
    p.add_argument("--pez", required=True, help="Path to pez binary")
    p.add_argument("--py", default=sys.executable, help="Python interpreter to compile source")
    p.add_argument("--xdis-python", default="", help="Python interpreter with xdis installed")
    p.add_argument("--timeout", type=int, default=120, help="Timeout seconds per step")
    p.add_argument("--focus", default="", help="Optional focus path for decompile")
    p.add_argument("--path", default="", help="Code object path for locate_mismatch")
    p.add_argument("--out", default="", help="Write JSON report to this path")
    p.add_argument("--keep-temp", action="store_true", help="Keep temp files")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    orig = Path(args.orig)
    pez = Path(args.pez)
    if not orig.exists():
        raise SystemExit(f"missing: {orig}")
    if not pez.exists():
        raise SystemExit(f"missing: {pez}")

    tmpdir = Path(tempfile.mkdtemp(prefix="pez-cmp-driver-"))
    try:
        decompiled = tmpdir / "decompiled.py"
        cmd = [str(pez)]
        if args.focus:
            cmd.append(f"--focus={args.focus}")
        cmd.append(str(orig))
        proc = run_cmd(cmd, args.timeout)
        if proc.returncode != 0:
            sys.stderr.write(proc.stderr)
            raise SystemExit(proc.returncode)
        decompiled.write_text(proc.stdout)

        compare_json = tmpdir / "compare.json"
        compare_cmd = [
            sys.executable,
            str(Path(__file__).with_name("compare.py")),
            "--orig",
            str(orig),
            "--src",
            str(decompiled),
            "--py",
            args.py,
            "--xdis-python",
            args.xdis_python,
            "--timeout",
            str(args.timeout),
            "--out",
            str(compare_json),
        ]
        proc = run_cmd(compare_cmd, args.timeout)
        if proc.returncode != 0:
            sys.stderr.write(proc.stderr)
            raise SystemExit(proc.returncode)
        compare_data = json.loads(compare_json.read_text())

        locate_data = None
        locate_json = None
        if args.path:
            locate_json = tmpdir / "locate.json"
            locate_cmd = [
                sys.executable,
                str(Path(__file__).with_name("locate_mismatch.py")),
                "--orig",
                str(orig),
                "--src",
                str(decompiled),
                "--path",
                args.path,
                "--py",
                args.py,
                "--xdis-python",
                args.xdis_python,
                "--timeout",
                str(args.timeout),
                "--out",
                str(locate_json),
            ]
            proc = run_cmd(locate_cmd, args.timeout)
            if proc.returncode != 0:
                sys.stderr.write(proc.stderr)
                raise SystemExit(proc.returncode)
            locate_data = json.loads(locate_json.read_text())

        report = {
            "decompiled_src": str(decompiled),
            "compare": compare_data,
            "locate": locate_data,
        }
        out_text = json.dumps(report, indent=2)
        if args.out:
            Path(args.out).write_text(out_text)
        else:
            print(out_text)
    finally:
        if args.keep_temp:
            pass
        else:
            try:
                for child in tmpdir.iterdir():
                    child.unlink()
                tmpdir.rmdir()
            except Exception:
                pass


if __name__ == "__main__":
    main()
