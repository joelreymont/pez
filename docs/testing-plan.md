Pez Testing Plan
================

Goals
-----
- Prove correctness across Python 2.7 through 3.14 opcode formats.
- Ensure decoder, CFG, stack simulation, and decompiler never crash on valid input.
- Make failures reproducible with zcheck seeds and minimal counterexamples.

Snapshot Tests (golden output)
------------------------------
- Expand `src/snapshot_tests.zig` to cover:
  - Functions: decorators, defaults, kwdefaults, annotations, closures.
  - Classes: `LOAD_BUILD_CLASS`, `MAKE_CLASS`, metaclass paths.
  - Control flow: if/elif/else, for/while, try/except/finally, with, match.
  - Expressions: ternary, comprehensions, chained comparisons, f-strings.
- Add version-specific snapshots for opcodes with divergent semantics (3.10 vs 3.11+).
- Feed the test harness with curated `.pyc` fixtures and compare output to expected `.py`.

Property Tests (zcheck)
-----------------------
- Decoder invariants (`src/property_tests.zig`):
  - `InstructionIterator` never panics on arbitrary byte slices.
  - Offsets are monotonically increasing and instruction sizes are valid.
  - Pre-3.6 arg sizes are 1 or 3 bytes; 3.6+ sizes are 2 + cache bytes.
  - EXTENDED_ARG composition matches 8-bit (3.6+) or 16-bit (pre-3.6) chunks.
- Opcode tables (`src/property_tests.zig`):
  - Each table covers exactly 256 entries (including null gaps).
  - Opcodes map to unique byte values per version.
  - `hasArg` is consistent with per-version `HAVE_ARGUMENT`.
- CFG invariants (`src/property_tests.zig`):
  - Blocks do not overlap.
  - Successor IDs are valid.
  - Entry block starts at offset 0 for non-empty bytecode.
- Stack simulation invariants (`src/property_tests.zig`):
  - Stack depth never goes negative for generated valid sequences.
  - Simulated expressions are well-formed and deinit cleanly.
  - Per-opcode stack effect matches `stack.effect()` for supported opcodes.
- Decompiler invariants (`src/property_tests.zig` + harness):
  - For a restricted opcode subset, decompile output round-trips through CPython.
  - Decompiler never emits invalid indentation or trailing whitespace.
- Marshal format invariants (`src/property_tests.zig`):
  - Randomly generated marshal blobs either parse or fail cleanly.
  - Ref tables do not underflow for stringref usage.

zcheck Features to Use
----------------------
- `BoundedSlice(u8, N)` for bytecode buffers without heap allocation.
- `String`, `Id`, `FilePath` for bounded printable input.
- `intRange` for constrained opcode/arg generation per version.
- `checkResult` for reproducible failures with captured seeds.
- Increased `iterations` and `max_shrinks` for decoder/CFG stress.

External Cross-checks
---------------------
- Parity harness (`tools/parity/run.sh`) runs pez against pycdc, uncompyle6, and decompyle3.
- decompyle3:
  - Clone: `gh repo clone rocky/python-decompile3 /tmp/python-decompile3`
  - Repo: `/tmp/python-decompile3` (keep in sync via `gh repo sync`)
  - Local snapshot (subset for quick diffs): `refs/python-decompile3/`
  - Venv (py3.12): `/opt/homebrew/bin/python3.12 -m venv /tmp/decompyle3-venv-312`
  - xdis (pre-opcode reorg, compatible with decompyle3): `/tmp/decompyle3-venv-312/bin/pip install git+https://github.com/rocky/python-xdis.git@f19046be089a515f2041a14a696774e82851d3c5`
  - Install: `/tmp/decompyle3-venv-312/bin/pip install -e /tmp/python-decompile3`
  - Tests: `PYTHON=/tmp/decompyle3-venv-312/bin/python make -C /tmp/python-decompile3 check-3.12`
  - Harness:
    - `/tmp/python-decompile3/test/test_pythonlib.py`
    - `/tmp/python-decompile3/test/test_pyenvlib.py`
    - `/tmp/python-decompile3/test/simple-decompile-code-test.py`
    - `/tmp/python-decompile3/compile_tests`
- External corpora to compare against decompyle3 (3.x only):
  - `/tmp/python-decompile3/test/bytecode_3.7`
  - `/tmp/python-decompile3/test/bytecode_3.7pypy`
  - `/tmp/python-decompile3/test/bytecode_3.8`
  - `/tmp/python-decompile3/test/bytecode_3.8pypy`
  - `/tmp/python-decompile3/test/bytecode_pypy37_run`
  - `/tmp/python-decompile3/test/bytecode_pypy38_run`
  - `/tmp/python-decompile3/test/bytecompile-tests`
  - `/tmp/python-decompile3/test/decompyle`
  - `/tmp/python-decompile3/test/simple_source`
  - `/tmp/python-decompile3/test/stdlib`
  - `/tmp/python-decompile3/test/test_one`
- Compare pez output against decompyle3 on shared corpora when diagnosing mismatches.

Next Steps
----------
- Implement missing properties in `src/property_tests.zig`.
- Add a `.pyc`/`.py` fixture harness (`src/test_harness.zig`).
- Wire version matrix runs to exercise all supported opcode tables.
