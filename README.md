# Pez

A Python bytecode decompiler written in Zig.

Pez parses `.pyc` files (Python's compiled bytecode format), disassembles bytecode to human-readable instructions, and reconstructs Python source code.

## Features

- **Multi-version support**: Parses `.pyc` files from Python 1.0 through 3.14
- **Bytecode disassembly**: Human-readable opcode output with argument annotations
- **Source reconstruction**: Generates readable Python source from bytecode
- **Nested code objects**: Recursively processes closures and nested functions

## Build

Requires Zig 0.15+.

```bash
zig build              # compile
zig build run -- file.pyc   # run on a .pyc file
zig build test         # run tests
```

## Usage

```bash
./zig-out/bin/pez example.pyc
```

## Verification

Batch decompile and validate syntax:

```bash
# Decompile all .pyc files in a directory
for f in /path/to/*.pyc; do
  ./zig-out/bin/pez "$f" > "/tmp/out/$(basename "$f" .pyc).py" 2>/dev/null
done

# Verify all outputs are valid Python
for f in /tmp/out/*.py; do
  python3 -m py_compile "$f" || echo "FAIL: $f"
done
```

Roundtrip comparison (requires xdis):

```bash
python3 tools/compare/compare_dir.py \
  --orig-dir /path/to/pyc/files \
  --src-dir /path/to/decompiled \
  --out /tmp/compare.json
```

External cross-check (decompyle3):

```bash
gh repo clone rocky/python-decompile3 /tmp/python-decompile3
(cd /tmp/python-decompile3 && make check)
```

## Test Corpora

- **Local corpus** (`test/corpus/`): 93 files, 88 pass (94.6%)
- **pycdc corpus** (`refs/pycdc/tests/compiled/`): 190 files, 108 pass (56.8%)
- **boat_main**: 118/118 files decompile to valid Python
- **decompyle3 suite** (`/tmp/python-decompile3`): `make check` / `remake --tasks`

## Project Structure

```
src/
├── main.zig          # CLI entry point
├── pyc.zig           # .pyc format parsing & disassembly
├── opcodes.zig       # Opcode definitions by Python version
├── decoder.zig       # Instruction decoding & line table parsing
├── cfg.zig           # Control flow graph construction
├── ctrl.zig          # Control flow pattern detection
├── ast.zig           # AST node definitions
├── stack.zig         # Stack simulation for expression reconstruction
├── decompile.zig     # Main decompilation logic
├── codegen.zig       # Python source code generation
tools/
├── compare/          # Roundtrip comparison tools
└── dump_view.py      # Bytecode/CFG visualization
```

## Known Limitations

- Python 3.14 inline comprehensions (PEP 709)
- Python 3.14 match statement optimizations
- except* (PEP 654)
- Some Python 2.x edge cases

## License

MIT
