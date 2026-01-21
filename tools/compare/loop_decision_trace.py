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
    p.add_argument("--focus", default="", help="Optional focus path for decompile")
    p.add_argument("--trace-sim", default="", help="Block id for sim trace")
    p.add_argument("--out", default="", help="Write JSON report to this path")
    p.add_argument("--src-out", default="", help="Write decompiled source to this path")
    p.add_argument("--timeout", type=int, default=120, help="Timeout seconds")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    orig = Path(args.orig)
    pez = Path(args.pez)
    if not orig.exists():
        raise SystemExit(f"missing: {orig}")
    if not pez.exists():
        raise SystemExit(f"missing: {pez}")

    tmpdir = Path(tempfile.mkdtemp(prefix="pez-trace-"))
    try:
        out_path = Path(args.src_out) if args.src_out else tmpdir / "decompiled.py"
        cmd = [str(pez), "--trace-loop-guards", "--trace-decisions"]
        if args.trace_sim:
            cmd.append(f"--trace-sim={args.trace_sim}")
        if args.focus:
            cmd.append(f"--focus={args.focus}")
        cmd.append(str(orig))
        proc = run_cmd(cmd, args.timeout)
        if proc.returncode != 0:
            sys.stderr.write(proc.stderr)
            raise SystemExit(proc.returncode)
        out_path.write_text(proc.stdout)

        events = []
        for line in proc.stderr.splitlines():
            if not line.strip():
                continue
            events.append(json.loads(line))

        counts = {}
        notes = {}
        for ev in events:
            kind = ev.get("kind", "unknown")
            counts[kind] = counts.get(kind, 0) + 1
            note = ev.get("note")
            if note:
                notes[note] = notes.get(note, 0) + 1

        report = {
            "decompiled_src": str(out_path),
            "event_count": len(events),
            "counts": counts,
            "notes": notes,
            "events": events,
        }
        out_text = json.dumps(report, indent=2)
        if args.out:
            Path(args.out).write_text(out_text)
        else:
            print(out_text)
    finally:
        if args.src_out:
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
