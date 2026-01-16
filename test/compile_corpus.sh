#!/usr/bin/env bash
set -euo pipefail

# Compile test corpus across Python versions
SRC_DIR="${1:-test/corpus_src}"
OUT_DIR="${2:-test/corpus}"
mkdir -p "$OUT_DIR"

# Use available Python version
PYTHON_VER=$(python3 --version | awk '{print $2}' | cut -d. -f1,2)

for src in "$SRC_DIR"/*.py; do
    base=$(basename "$src" .py)
    python3 -m py_compile "$src" 2>/dev/null || true
    find "$SRC_DIR/__pycache__" -name "${base}*.pyc" -exec cp {} "$OUT_DIR/${base}.${PYTHON_VER}.pyc" \; 2>/dev/null || true
    rm -rf "$SRC_DIR/__pycache__"
done

echo "Compiled $(ls -1 "$OUT_DIR"/*.pyc 2>/dev/null | wc -l) test files"
