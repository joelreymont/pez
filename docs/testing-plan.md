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
  - Clone: `jj git clone https://github.com/rocky/python-decompile3 refs/python-decompile3`
  - Repo: `/Users/joel/Work/pez/refs/python-decompile3` (@ 936ea1f36610ab20411b59d6d71323f2033a6bc2)
  - Runtime setup:
    - `uv python install 3.9`
    - `uv python install 3.12`
    - `uv venv -p 3.9 /Users/joel/Work/pez/.uv/py39`
    - `uv venv -p 3.12 /Users/joel/Work/pez/.uv/py312`
    - `uv pip install -p /Users/joel/Work/pez/.uv/py39 -e /Users/joel/Work/pez/refs/python-decompile3`
    - `uv pip install -p /Users/joel/Work/pez/.uv/py39 xdis==6.1.7 spark-parser click configobj`
    - `uv pip install -p /Users/joel/Work/pez/.uv/py312 uncompyle6 decompyle3 xdis`
  - Tests: `PYTHON=/Users/joel/Work/pez/.uv/py312/bin/python make -C /Users/joel/Work/pez/refs/python-decompile3 check-3.12`
  - Harness:
    - `/Users/joel/Work/pez/refs/python-decompile3/test/test_pythonlib.py`
    - `/Users/joel/Work/pez/refs/python-decompile3/test/test_pyenvlib.py`
    - `/Users/joel/Work/pez/refs/python-decompile3/test/simple-decompile-code-test.py`
    - `/Users/joel/Work/pez/refs/python-decompile3/compile_tests`
- External corpora to compare against decompyle3 (3.x only):
  - `/Users/joel/Work/pez/refs/python-decompile3/test/bytecode_3.7`
  - `/Users/joel/Work/pez/refs/python-decompile3/test/bytecode_3.7pypy`
  - `/Users/joel/Work/pez/refs/python-decompile3/test/bytecode_3.8`
  - `/Users/joel/Work/pez/refs/python-decompile3/test/bytecode_3.8pypy`
  - `/Users/joel/Work/pez/refs/python-decompile3/test/bytecode_pypy37_run`
  - `/Users/joel/Work/pez/refs/python-decompile3/test/bytecode_pypy38_run`
  - `/Users/joel/Work/pez/refs/python-decompile3/test/bytecompile-tests`
  - `/Users/joel/Work/pez/refs/python-decompile3/test/decompyle`
  - `/Users/joel/Work/pez/refs/python-decompile3/test/simple_source`
  - `/Users/joel/Work/pez/refs/python-decompile3/test/stdlib`
  - `/Users/joel/Work/pez/refs/python-decompile3/test/test_one`
- Decompyle3 → pez compare helper:
  - Decompile: `python3 tools/compare/decompyle3_dir.py --decompyle3 /Users/joel/Work/pez/.uv/py39/bin/decompyle3 --orig-dir /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted --out-dir /tmp/decompyle3_boat_src --timeout 120 --out /tmp/decompyle3_boat_decompile.json`
  - Compare: `python3 tools/compare/compare_dir.py --orig-dir /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted --src-dir /tmp/decompyle3_boat_src --py /Users/joel/Work/pez/.uv/py39/bin/python --xdis-python /Users/joel/Work/pez/.uv/py39/bin/python --timeout 120 --out /tmp/decompyle3_boat_compare.json --report-dir /tmp/decompyle3_boat_compare_reports`
- Compare pez output against decompyle3 on shared corpora when diagnosing mismatches.

Next Steps
----------
- Implement missing properties in `src/property_tests.zig`.
- Add a `.pyc`/`.py` fixture harness (`src/test_harness.zig`).
- Wire version matrix runs to exercise all supported opcode tables.
