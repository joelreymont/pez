#!/usr/bin/env python3
import argparse
import json
import subprocess
import tempfile
from pathlib import Path
from typing import Optional


SECTIONS = ("bytecode", "cfg", "dom", "patterns", "passes")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--pyc", required=True, help="Path to .pyc")
    p.add_argument("--pez", default="zig-out/bin/pez", help="Path to pez binary")
    p.add_argument("--section", choices=SECTIONS, default="bytecode", help="Section to dump")
    p.add_argument("--code-path", default="", help="Dot path to nested code object")
    p.add_argument("--block", type=int, default=-1, help="Block id (cfg only)")
    p.add_argument("--out", default="", help="Write JSON to this path")
    return p.parse_args()


def run_dump(pez: str, pyc: str, section: str) -> dict:
    tmp = tempfile.NamedTemporaryFile(prefix="pez-dump-", suffix=".json", delete=False)
    tmp_path = Path(tmp.name)
    tmp.close()
    try:
        cmd = [pez, f"--dump={section}", f"--dump-json={tmp_path}", pyc]
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if proc.returncode != 0:
            raise SystemExit(proc.stderr.strip() or proc.stdout.strip() or "dump failed")
        return json.loads(tmp_path.read_text())
    finally:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass


def find_code(root: dict, path: str) -> Optional[dict]:
    if not path:
        return root
    parts = [p for p in path.split(".") if p]
    if not parts:
        return root

    def walk(node: dict, idx: int) -> Optional[dict]:
        if idx >= len(parts):
            return node
        for child in node.get("children") or []:
            name = child.get("name") or ""
            qual = child.get("qualname") or ""
            if parts[idx] == name or parts[idx] == qual:
                found = walk(child, idx + 1)
                if found:
                    return found
        return None

    return walk(root, 0)


def dump_bytecode(code: dict) -> list:
    items = code.get("bytecode")
    if items is None:
        raise SystemExit("bytecode section missing")
    return items


def dump_cfg(code: dict, block_id: int):
    cfg = code.get("cfg")
    if cfg is None:
        raise SystemExit("cfg section missing")
    blocks = cfg.get("blocks") or []
    if block_id >= 0:
        if block_id >= len(blocks):
            raise SystemExit(f"block {block_id} out of range")
        return blocks[block_id]
    out = []
    for blk in blocks:
        out.append(
            {
                "id": blk.get("id"),
                "start_offset": blk.get("start_offset"),
                "end_offset": blk.get("end_offset"),
                "preds": len(blk.get("predecessors") or []),
                "succs": len(blk.get("successors") or []),
                "is_loop_header": blk.get("is_loop_header"),
                "is_exception_handler": blk.get("is_exception_handler"),
            }
        )
    return out


def main() -> None:
    args = parse_args()
    data = run_dump(args.pez, args.pyc, args.section)
    root = data.get("code") or {}
    code = find_code(root, args.code_path)
    if code is None:
        raise SystemExit("code path not found")

    if args.section == "bytecode":
        out = dump_bytecode(code)
    elif args.section == "cfg":
        out = dump_cfg(code, args.block)
    elif args.section == "dom":
        out = code.get("dom")
        if out is None:
            raise SystemExit("dom section missing")
    elif args.section == "patterns":
        out = code.get("patterns")
        if out is None:
            raise SystemExit("patterns section missing")
    elif args.section == "passes":
        out = code.get("passes")
        if out is None:
            raise SystemExit("passes section missing")
    else:
        raise SystemExit(f"unknown section: {args.section}")

    payload = json.dumps(out, indent=2)
    if args.out:
        Path(args.out).write_text(payload)
    else:
        print(payload)


if __name__ == "__main__":
    main()
