## CODE REVIEW REPORT

### CRITICAL
1. Hot-path stack pops allocate per opcode
- File: src/stack.zig:383
- Type: Performance
- Description: Stack.popN allocates a fresh slice for every pop and valuesToExprs allocates expr arrays in the same hot path.
- Impact: high allocation pressure and non-linear slowdown on large bytecode (timeouts in boat_main corpus).
- Recommendation: add SimContext scratch buffers for StackValue/Expr slices and reuse; avoid heap allocs in hot paths.

2. Branch cloning allocates SimContext per merge
- File: src/decompile.zig:491
- Type: Performance
- Description: cloneStackValues/cloneStackValuesWithExpr allocate a new SimContext and deep-clone every stack value for each branch/conditional.
- Impact: O(B*D) clones across the CFG, large memory/time overhead.
- Recommendation: reuse a dedicated clone SimContext per decompiler pass and/or use arena-backed shallow copies with structural sharing.

### HIGH
3. Call handling duplication with inconsistent ownership
- File: src/stack.zig:2210
- Type: DRY | Correctness
- Description: CALL_METHOD/CALL_FUNCTION* duplicate arg handling and manual cleanup; args_with_self uses stack_alloc but frees with allocator.
- Impact: allocator mismatch (leaks/invalid frees) and higher regression risk for opcode variants.
- Recommendation: centralize call-arg assembly with explicit ownership; use stack_alloc consistently for transient arrays.

4. mergeStackEntry allocates new arrays even when unchanged
- File: src/decompile.zig:593
- Type: Performance
- Description: mergeStackEntry always allocates a new StackValue array and marks unknowns, even when no changes.
- Impact: unnecessary allocations during dataflow merges; scales poorly with block count.
- Recommendation: detect identical stacks and reuse existing slice; use scratch buffer and only allocate on change.

### MEDIUM
5. Comprehension builder clone is deep-copy per merge
- File: src/stack.zig:1310
- Type: Performance | DRY
- Description: cloneCompBuilder deep-clones exprs, generators, and ifs on every clone.
- Impact: expensive for nested comprehensions or merge-heavy CFGs.
- Recommendation: make comp builder immutable with structural sharing or re-simulate comp bodies from a cached slice.

6. allow_underflow synthesizes unknowns in core stack ops
- File: src/stack.zig:337
- Type: Anti-pattern | Correctness
- Description: pop/popExpr/popN fabricate __unknown__/unknown when allow_underflow is set.
- Impact: masks real stack errors and reduces compare fidelity.
- Recommendation: split FlowSimContext vs strict SimContext; require explicit opt-in and track unknown counts.

### LOW
7. Monolithic opcode switch impedes optimization and testability
- File: src/stack.zig:1615
- Type: DRY | Maintainability
- Description: single giant switch mixes semantics for all versions and op categories.
- Impact: higher regression risk and slower iteration for 3.11+ changes.
- Recommendation: refactor into grouped handler functions or a dispatch table with shared helpers.

### SUMMARY
- Total issues: 7 (Critical: 2, High: 2, Medium: 2, Low: 1)
- Oracle: skipped (user request)
