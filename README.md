# Pez

A Python bytecode decompiler written in Zig.

Pez parses `.pyc` files (Python's compiled bytecode format), disassembles bytecode to human-readable instructions, and reconstructs Python source code.

## Features

- **Multi-version support**: Parses `.pyc` files from Python 1.0 through 3.14
- **Bytecode disassembly**: Human-readable opcode output with argument annotations
- **Symbol annotation**: Shows constant values, variable names, and attribute names
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

Output includes:
- Python version (detected from magic number)
- Code object metadata (argcount, stacksize, flags, etc.)
- Disassembled bytecode with symbolic annotations

## Project Structure

```
src/
├── main.zig          # CLI entry point
├── pyc.zig           # .pyc format parsing & disassembly
├── opcodes.zig       # Opcode definitions by Python version
├── decoder.zig       # Instruction decoding & line table parsing
├── cfg.zig           # Control flow graph construction
├── ast.zig           # AST node definitions
├── stack.zig         # Stack simulation for expression reconstruction
├── codegen.zig       # Python source code generation
└── property_tests.zig # Property-based tests (zcheck)
docs/
├── python-bytecode.md   # Technical reference
└── zig-0.15-io-api.md   # Zig API patterns
```

## Status

- [x] Magic number detection (all Python versions)
- [x] Marshal format parsing
- [x] Code object extraction
- [x] Bytecode disassembly
- [x] Control flow graph construction
- [x] Exception table parsing (3.11+)
- [x] Line number table parsing (all versions)
- [ ] AST reconstruction
- [ ] Source code generation

## License

MIT
