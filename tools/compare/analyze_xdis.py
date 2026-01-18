#!/usr/bin/env python3
import hashlib
import json
import sys
from collections import Counter, defaultdict

from xdis import load, op_imports
from xdis.bytecode import Bytecode


IGNORE_OPS = {
    "CACHE",
    "EXTENDED_ARG",
    "NOP",
    "RESUME",
    "COPY_FREE_VARS",
    "PUSH_NULL",
}

CONST_OPS = {
    "LOAD_CONST",
    "LOAD_SMALL_INT",
    "LOAD_BIG_INT",
}

NAME_OPS = {
    "LOAD_NAME",
    "STORE_NAME",
    "LOAD_GLOBAL",
    "STORE_GLOBAL",
    "LOAD_FAST",
    "STORE_FAST",
    "LOAD_FAST_CHECK",
    "LOAD_FAST_BORROW",
    "STORE_FAST_MAYBE_NULL",
    "LOAD_DEREF",
    "STORE_DEREF",
    "LOAD_CLASSDEREF",
}

CALL_OPS = {
    "CALL",
    "CALL_FUNCTION",
    "CALL_FUNCTION_KW",
    "CALL_FUNCTION_EX",
    "CALL_METHOD",
}

RETURN_OPS = {
    "RETURN_VALUE",
    "RETURN_CONST",
}

RAISE_OPS = {
    "RAISE_VARARGS",
    "RERAISE",
}


def sha1_text(text: str) -> str:
    return hashlib.sha1(text.encode("utf-8")).hexdigest()


def short_hash(text: str) -> str:
    return sha1_text(text)[:12]


def const_token(val) -> str:
    if val is None:
        return "const:none"
    t = type(val).__name__
    if t == "code" or t.startswith("Code"):
        return "const:code"
    if t in ("int", "float", "complex", "bool"):
        return f"const:{t}:{val}"
    if t in ("str", "bytes"):
        rep = repr(val)
        return f"const:{t}:{short_hash(rep)}"
    if t in ("tuple", "list", "set", "dict"):
        return f"const:{t}:{short_hash(repr(val))}"
    return f"const:{t}"


def name_token(opname: str, name: str) -> str:
    scope = "name"
    if "GLOBAL" in opname:
        scope = "global"
    elif "FAST" in opname:
        scope = "local"
    elif "DEREF" in opname:
        scope = "free"
    return f"{scope}:{name}"


def arity_bin(n: int) -> str:
    if n <= 0:
        return "0"
    if n == 1:
        return "1"
    if n <= 3:
        return "2-3"
    return "4+"


def is_jump(opname: str) -> bool:
    return (
        opname.startswith("JUMP")
        or opname.startswith("POP_JUMP")
        or opname.startswith("JUMP_IF")
        or opname == "FOR_ITER"
    )


def is_cond_jump(opname: str) -> bool:
    if opname == "FOR_ITER":
        return True
    if opname.startswith("POP_JUMP"):
        return True
    if opname.startswith("JUMP_IF"):
        return True
    if opname == "JUMP_IF_NOT_EXC_MATCH":
        return True
    return False


def is_uncond_jump(opname: str) -> bool:
    if opname.startswith("JUMP") and "IF" not in opname:
        return True
    return opname in {"JUMP_ABSOLUTE", "JUMP_FORWARD", "JUMP_BACKWARD", "JUMP_BACKWARD_NO_INTERRUPT"}


def op_class(opname: str) -> str:
    if opname in CONST_OPS:
        return "const"
    if opname in NAME_OPS:
        return "name"
    if opname in CALL_OPS:
        return "call"
    if opname in RETURN_OPS:
        return "return"
    if opname in RAISE_OPS:
        return "raise"
    if opname.startswith("BINARY_") or opname == "BINARY_OP" or opname.startswith("INPLACE_"):
        return "binop"
    if opname.startswith("UNARY_"):
        return "unary"
    if opname in ("COMPARE_OP", "IS_OP", "CONTAINS_OP"):
        return "compare"
    if is_jump(opname):
        return "branch"
    if opname.startswith("LOAD_"):
        return "load"
    if opname.startswith("STORE_"):
        return "store"
    if opname.startswith("BUILD_") or opname in {"MAKE_FUNCTION", "MAKE_CELL", "MAKE_CLOSURE"}:
        return "build"
    if opname in {"GET_ITER", "GET_AITER", "GET_ANEXT", "YIELD_FROM", "YIELD_VALUE"}:
        return "iter"
    if opname in {"COPY", "DUP_TOP", "ROT_TWO", "ROT_THREE", "ROT_FOUR", "SWAP"}:
        return "stack"
    return "other"


def norm_arg(opname: str, argval, argrepr: str, arg: int) -> str:
    if opname in CONST_OPS:
        return const_token(argval)
    if opname in NAME_OPS:
        return name_token(opname, argval or "<unknown>")
    if opname in CALL_OPS:
        return f"call:{arity_bin(arg or 0)}"
    if opname in ("COMPARE_OP", "IS_OP", "CONTAINS_OP"):
        return f"cmp:{argrepr}"
    if is_jump(opname):
        return "jump"
    if opname == "BINARY_OP":
        return f"bin:{argrepr}"
    return ""


def seq_token(opname: str, arg_token: str) -> str:
    cls = op_class(opname)
    if arg_token and cls in {"const", "name", "call", "compare", "branch", "binop"}:
        return f"{cls}:{arg_token}"
    return cls


def stack_delta(opc, opname: str, arg: int) -> int:
    op = opc.opmap.get(opname)
    if op is None:
        return 0
    pop = opc.oppop[op]
    push = opc.oppush[op]
    if pop >= 0 and push >= 0:
        return push - pop
    if opname in CALL_OPS:
        extra = 0
        if opname == "CALL_FUNCTION_KW":
            extra = 1
        elif opname == "CALL_FUNCTION_EX":
            extra = 1 + (1 if (arg & 1) else 0)
        elif opname == "CALL":
            extra = 1
        return 1 - (arg + extra)
    if opname == "BUILD_LIST" or opname == "BUILD_TUPLE" or opname == "BUILD_SET":
        return 1 - arg
    if opname == "BUILD_MAP":
        return 1 - (arg * 2)
    if opname == "BUILD_SLICE":
        return 1 - arg
    if opname == "UNPACK_SEQUENCE":
        return arg - 1
    if opname == "UNPACK_EX":
        before = arg & 0xFF
        after = (arg >> 8) & 0xFF
        return (before + after + 1) - 1
    if opname == "MAKE_FUNCTION":
        pops = 2
        if arg & 0x01:
            pops += 1
        if arg & 0x02:
            pops += 1
        if arg & 0x04:
            pops += 1
        if arg & 0x08:
            pops += 1
        return 1 - pops
    return 0


def normalize_instructions(instrs):
    out = []
    i = 0
    while i < len(instrs):
        ins = instrs[i]
        if ins.opname in IGNORE_OPS:
            i += 1
            continue
        if ins.opname == "PUSH_NULL":
            i += 1
            continue
        out.append(ins)
        i += 1
    return out


def build_cfg(instrs):
    if not instrs:
        return [], [], {}
    leaders = {instrs[0].offset}
    offsets = [ins.offset for ins in instrs]
    offset_set = set(offsets)

    for idx, ins in enumerate(instrs):
        if is_jump(ins.opname):
            if isinstance(ins.argval, int) and ins.argval in offset_set:
                leaders.add(ins.argval)
            if idx + 1 < len(instrs):
                leaders.add(instrs[idx + 1].offset)
        elif ins.opname in RETURN_OPS or ins.opname in RAISE_OPS:
            if idx + 1 < len(instrs):
                leaders.add(instrs[idx + 1].offset)

    leaders = sorted(leaders)
    blocks = []
    off_to_block = {}
    for i, start in enumerate(leaders):
        end = leaders[i + 1] if i + 1 < len(leaders) else None
        block_instrs = []
        for ins in instrs:
            if ins.offset < start:
                continue
            if end is not None and ins.offset >= end:
                break
            block_instrs.append(ins)
        if not block_instrs:
            continue
        bid = len(blocks)
        blocks.append({"id": bid, "start": start, "instrs": block_instrs})
        off_to_block[start] = bid

    edges = []
    for i, block in enumerate(blocks):
        last = block["instrs"][-1]
        src = block["id"]
        next_block = blocks[i + 1]["id"] if i + 1 < len(blocks) else None
        if is_cond_jump(last.opname):
            if isinstance(last.argval, int) and last.argval in off_to_block:
                dst = off_to_block[last.argval]
                edges.append((src, dst, "cond"))
            if next_block is not None:
                edges.append((src, next_block, "fallthrough"))
        elif is_uncond_jump(last.opname):
            if isinstance(last.argval, int) and last.argval in off_to_block:
                dst = off_to_block[last.argval]
                edges.append((src, dst, "jump"))
        elif last.opname in RETURN_OPS or last.opname in RAISE_OPS:
            pass
        else:
            if next_block is not None:
                edges.append((src, next_block, "fallthrough"))
    return blocks, edges, off_to_block


def reachable_blocks(blocks, edges):
    if not blocks:
        return set()
    adj = defaultdict(list)
    for src, dst, _ in edges:
        adj[src].append(dst)
    seen = set()
    stack = [blocks[0]["id"]]
    while stack:
        b = stack.pop()
        if b in seen:
            continue
        seen.add(b)
        stack.extend(adj.get(b, []))
    return seen


def block_invariants(opc, block):
    op_seq = []
    op_counts = Counter()
    consts = Counter()
    names = Counter()
    call_bins = Counter()
    depth = 0
    max_depth = 0
    min_depth = 0
    for ins in block["instrs"]:
        arg_token = norm_arg(ins.opname, ins.argval, ins.argrepr, ins.arg or 0)
        op_seq.append(seq_token(ins.opname, arg_token))
        cls = op_class(ins.opname)
        op_counts[cls] += 1
        if ins.opname in CONST_OPS:
            consts[const_token(ins.argval)] += 1
        if ins.opname in NAME_OPS:
            names[name_token(ins.opname, ins.argval or "<unknown>")] += 1
        if ins.opname in CALL_OPS:
            call_bins[arity_bin(ins.arg or 0)] += 1
        delta = stack_delta(opc, ins.opname, ins.arg or 0)
        depth += delta
        if depth > max_depth:
            max_depth = depth
        if depth < min_depth:
            min_depth = depth
    return {
        "op_seq": op_seq,
        "op_counts": op_counts,
        "consts": consts,
        "names": names,
        "call_bins": call_bins,
        "stack_delta": depth,
        "stack_max": max_depth,
        "stack_min": min_depth,
    }


def sig_key(inv):
    payload = {
        "op_seq_hash": short_hash(" ".join(inv["op_seq"])),
        "stack_delta": inv["stack_delta"],
        "stack_max": inv["stack_max"],
        "consts": sorted(inv["consts"].items()),
        "names": sorted(inv["names"].items()),
        "call_bins": sorted(inv["call_bins"].items()),
    }
    return short_hash(json.dumps(payload, sort_keys=True))


def unit_meta(code) -> dict:
    meta = {
        "argcount": getattr(code, "co_argcount", 0),
        "posonlyargcount": getattr(code, "co_posonlyargcount", 0),
        "kwonlyargcount": getattr(code, "co_kwonlyargcount", 0),
        "nlocals": getattr(code, "co_nlocals", 0),
        "stacksize": getattr(code, "co_stacksize", 0),
        "flags": getattr(code, "co_flags", 0),
        "varnames_len": len(getattr(code, "co_varnames", ())),
        "freevars": list(getattr(code, "co_freevars", ())),
        "cellvars": list(getattr(code, "co_cellvars", ())),
    }
    exc_table = getattr(code, "co_exceptiontable", b"") or b""
    meta["exception_table_len"] = len(exc_table)
    meta["exception_table_hash"] = short_hash(exc_table.hex()) if exc_table else ""
    return meta


def analyze_code(code, opc, path):
    instrs = list(Bytecode(code, opc))
    instrs = normalize_instructions(instrs)
    blocks, edges, _ = build_cfg(instrs)
    reachable = reachable_blocks(blocks, edges)
    blocks = [b for b in blocks if b["id"] in reachable]
    edges = [e for e in edges if e[0] in reachable and e[1] in reachable]

    block_sigs = []
    block_sig_counts = Counter()
    for b in blocks:
        inv = block_invariants(opc, b)
        key = sig_key(inv)
        block_sigs.append(
            {
                "id": b["id"],
                "start": b["start"],
                "sig": key,
                "stack_delta": inv["stack_delta"],
                "stack_max": inv["stack_max"],
                "stack_min": inv["stack_min"],
                "op_seq_hash": short_hash(" ".join(inv["op_seq"])),
                "consts": dict(inv["consts"]),
                "names": dict(inv["names"]),
                "call_bins": dict(inv["call_bins"]),
            }
        )
        block_sig_counts[key] += 1

    edge_sig_counts = Counter()
    for src, dst, etype in edges:
        src_sig = next((b["sig"] for b in block_sigs if b["id"] == src), "")
        dst_sig = next((b["sig"] for b in block_sigs if b["id"] == dst), "")
        if src_sig and dst_sig:
            edge_sig_counts[f"{src_sig}:{etype}:{dst_sig}"] += 1

    op_seq = []
    op_counts = Counter()
    for ins in instrs:
        arg_token = norm_arg(ins.opname, ins.argval, ins.argrepr, ins.arg or 0)
        token = seq_token(ins.opname, arg_token)
        op_seq.append(token)
        op_counts[op_class(ins.opname)] += 1

    loop_edges = 0
    starts = {b["id"]: b["start"] for b in blocks}
    for src, dst, _ in edges:
        if starts.get(dst, 0) <= starts.get(src, 0):
            loop_edges += 1

    cfg_sig = {
        "block_count": len(blocks),
        "edge_count": len(edges),
        "loop_edges": loop_edges,
    }

    unit = {
        "path": path,
        "meta": unit_meta(code),
        "norm_ops": op_seq,
        "op_counts": dict(op_counts),
        "block_sig_counts": dict(block_sig_counts),
        "edge_sig_counts": dict(edge_sig_counts),
        "block_sigs": block_sigs,
        "cfg_sig": cfg_sig,
    }
    return unit


def walk(code, opc, path, out):
    out.append(analyze_code(code, opc, path))
    for c in code.co_consts:
        if hasattr(c, "co_code"):
            walk(c, opc, path + "." + c.co_name, out)


def main():
    pyc = sys.argv[1]
    res = load.load_module(pyc)
    ver = res[0]
    code = res[3]
    opc = op_imports.get_opcode_module(ver)
    out = []
    walk(code, opc, code.co_name, out)
    print(json.dumps({"version": list(ver), "units": out}))


if __name__ == "__main__":
    main()
