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
    p.add_argument("--path", required=True, help="Code object path to minimize")
    p.add_argument("--py", default=sys.executable, help="Python interpreter to compile source")
    p.add_argument("--xdis-python", default="", help="Python interpreter with xdis installed")
    p.add_argument("--timeout", type=int, default=120, help="Timeout seconds")
    p.add_argument("--out", default="", help="Write minimized source to this path")
    p.add_argument("--stats-out", default="", help="Write JSON stats to this path")
    p.add_argument("--max-iter", type=int, default=200, help="Max ddmin iterations")
    p.add_argument("--verify", action="store_true", help="Run compare on minimized output")
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

    tmpdir = Path(tempfile.mkdtemp(prefix="pez-min-unit-"))
    try:
        decompiled = tmpdir / "decompiled.py"
        proc = run_cmd([str(pez), str(orig)], args.timeout)
        if proc.returncode != 0:
            sys.stderr.write(proc.stderr)
            raise SystemExit(proc.returncode)
        decompiled.write_text(proc.stdout)

        out_src = Path(args.out) if args.out else tmpdir / "minimized.py"
        emit_cmd = [
            sys.executable,
            str(Path(__file__).with_name("emit_min.py")),
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
            str(out_src),
            "--max-iter",
            str(args.max_iter),
        ]
        if args.stats_out:
            emit_cmd.extend(["--stats-out", args.stats_out])
        proc = run_cmd(emit_cmd, args.timeout)
        if proc.returncode != 0:
            sys.stderr.write(proc.stderr)
            raise SystemExit(proc.returncode)

        compare_data = None
        if args.verify:
            compare_json = tmpdir / "compare.json"
            compare_cmd = [
                sys.executable,
                str(Path(__file__).with_name("compare.py")),
                "--orig",
                str(orig),
                "--src",
                str(out_src),
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

        report = {
            "decompiled_src": str(decompiled),
            "minimized_src": str(out_src),
            "stats_out": args.stats_out or None,
            "compare": compare_data,
        }
        print(json.dumps(report, indent=2))
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
