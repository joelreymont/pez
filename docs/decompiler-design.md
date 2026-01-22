# Decompiler Design (Current)

## Goals
- Reconstruct readable, semantically equivalent Python source from `.pyc` bytecode.
- Preserve control-flow structure (if/elif/else, loops, try/except/finally/with, match).
- Maintain stack-correct output for recompile/compare tests.
- Provide debug visibility for mismatches (CFG dumps, decision traces, sim traces).

## High-Level Pipeline
1. **Load module**: `pyc.Module.loadFromFile` loads constants, code objects, exception table, version.
2. **Decode bytecode**: `decoder.InstructionIterator` produces `Instruction[]` with offsets, opcode, args.
3. **Build CFG**: `cfg.buildCFGWithExceptions` constructs `CFG` of `BasicBlock` nodes and edges:
   - Normal/conditional edges, exception edges, loop-back edges.
   - Per-block start/end offsets, instruction slices, successors/predessors.
4. **Dominators/loops**: `dom.DomTree` and CFG loop headers used by control-flow analysis.
5. **Control-flow analysis**: `ctrl.Analyzer` detects structured patterns per block:
   - `IfPattern`, `WhilePattern`, `ForPattern`, `TryPattern`, `WithPattern`, `MatchPattern`, `TernaryPattern`, bool-op patterns.
6. **Stack flow**: `Decompiler.initStackFlow` simulates across CFG to compute `stack_in[]` (merged entry stacks per block).
7. **Decompile to AST**:
   - Structured traversal over blocks using detected patterns.
   - Stack simulation (`stack.SimContext`) to build expressions and statements.
8. **Rewrite/cleanup**: Normalize statements for parity (remove redundant passes/returns, merge guards, fix cleanup assigns, etc.).
9. **Codegen**: `codegen` prints AST to Python source.

## Core Data Structures
- **AST** (`src/ast.zig`): `Expr`, `Stmt`, `Keyword`, `Pattern`, etc.
- **CFG** (`src/cfg.zig`):
  - `BasicBlock { id, start_offset, end_offset, instructions, successors, predecessors, is_exception_handler, is_loop_header }`.
  - `EdgeType`: normal, conditional_true/false, exception, loop_back.
- **Control-flow patterns** (`src/ctrl.zig`): `IfPattern`, `WhilePattern`, `ForPattern`, `TryPattern`, `WithPattern`, `MatchPattern`, `TernaryPattern`, `TernaryChainPattern`.
- **Stack simulation** (`src/stack.zig`):
  - `SimContext` tracks evaluation stack, locals, names, consts, call/signature handling.
  - `StackValue` union: expressions, function/class objects, comprehension builders, code objects, import modules, etc.
- **Decompiler** (`src/decompile.zig`):
  - Holds CFG, Analyzer, DOM, stack flow, consumed blocks, traces.
  - Performs structured decompile and post-rewrite passes.

## Decompilation Flow (Detailed)
### 1) Initialization
- `DecompileOptions` configures focus path and tracing (`trace_loop_guards`, `trace_sim_block`, `trace_decisions`).
- `DecompPipeline.ensureAnalyze` builds a `Decompiler` and loads CFG/analysis.
- `DecompPipeline.ensureDecompile` runs `Decompiler.decompile()` to produce raw `Stmt[]`.
- `DecompPipeline.ensureRewrite` applies module/function rewrite passes.

### 2) Structured Traversal
- `decompileStructuredRange(start, limit)` walks blocks in order:
  - Uses `Analyzer.detectPattern` to decide between `if`, `while`, `for`, `try`, `with`, `match`, or sequential.
  - A `consumed` bitset prevents reprocessing blocks absorbed into a higher-level structure.
  - `if_next` / `loop_next` / `chained_cmp_next_block` guide block skipping when patterns collapse multiple blocks.

### 3) Stack Simulation + Expression Recovery
- Each block uses `SimContext` to simulate opcode effects and build expressions.
- `stack_in[]` seeds the simulator with merged stack values per block.
- Expression reconstruction handles:
  - Calls, attributes, subscripts, binary/unary ops, comparisons, bool ops.
  - Comprehensions via `CompBuilder` and pending generator state.
  - Ternary expressions and chained ternary/bool-op constructs.

### 4) Pattern-Specific Decompile
- **If**: `decompileIfWithSkip` simulates condition block, computes then/else, merge points, and handles inversion/guard chains.
  - Supports chain-compare folding across blocks and consistent merge selection.
- **While**: builds condition from header, handles loop-body selection, guard folding, and continue detection.
- **For**: reconstructs iterator from setup block (GET_ITER / FOR_LOOP), derives target from body (STORE_* or UNPACK_*), decompiles body and optional else.
- **Try/Except/Finally**: uses CFG exception edges and handler analysis; constructs try body, except handlers, else/finally blocks.
- **With**: reconstructs context manager setup and cleanup blocks.
- **Match**: identifies subject block and case blocks, produces `match` AST with cases.

### 5) Rewrites / Normalization
Key rewrite passes in `decompile.zig`:
- Remove redundant `pass` blocks and trailing `return None` in contexts where bytecode already implies it.
- Merge guard patterns (`if cond: break/continue`, `if cond: raise ...`, `if cond: return None` sequences).
- Collapse chained condition blocks into single boolean expressions when safe.
- Normalize assert patterns (raise AssertionError on else path) to `assert`.
- Cleanup duplicate assignments or post-try cleanup artifacts.

### 6) Codegen
- AST is printed with `codegen`.
- Output is used for comparison/regression tools (`tools/compare`).

## Debug/Introspection Hooks
- `--dump` / `--dump-json` for bytecode/cfg/dom/loops/patterns/passes (`debug_dump`).
- `--trace-loop-guards`, `--trace-decisions`, `--trace-sim=BLOCK` emit JSONL traces to stderr.
- `tools/compare/locate_mismatch.py` and `tools/dump_codepath.py` assist in pinpointing divergences.

## Known Heuristics (Non-Exhaustive)
- Merge-point heuristics in `decompileIfWithSkip` to avoid pulling unrelated blocks into if/else.
- Condition inversion when empty-then or guard-style patterns are detected.
- Chain-compare folding across blocks when DUP/ROT/COMPARE patterns appear in adjacent conditional blocks.
- Stack flow merging prunes values on certain conditional edges (e.g., FOR_ITER false edge).

## Ownership & Memory
- AST nodes are allocated in the decompiler arena; stack sim uses stack allocator.
- Some transient arrays (`stack_in`, CFG edges) are heap-allocated and freed in `deinit` paths.

## Inputs/Outputs
- **Input**: Python `.pyc` with version-specific bytecode + exception tables.
- **Output**: Python source text via codegen, or JSON dumps/traces.

## Version Support
- Opcode decoding and CFG construction are version-aware (`decoder.Version`).
- Conditional jump target resolution and exception table parsing are versioned.

## Testing/Regression
- Unit tests for stack flow, ternary/boolop handling, and snapshot tests for decompiled output.
- `test_harness` and compare tools validate parity against known corpora.
