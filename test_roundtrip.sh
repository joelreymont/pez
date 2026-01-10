#!/usr/bin/env bash
set -euo pipefail

# Test round-trip: .pyc -> .py -> .pyc -> .py
# Output should match modulo whitespace

PYTHON="${1:-python3.11}"
PYC="${2:-test/hello.pyc}"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo "Testing round-trip with $PYC"

# First decompile
./zig-out/bin/pez "$PYC" > "$TMPDIR/first.py"

# Recompile
$PYTHON -m py_compile "$TMPDIR/first.py"
PYC2=$(find "$TMPDIR/__pycache__" -name "first*.pyc" | head -1)

# Second decompile
./zig-out/bin/pez "$PYC2" > "$TMPDIR/second.py"

# Compare (normalize whitespace, skip header comments)
diff -u <(cat "$TMPDIR/first.py" | sed 's/[[:space:]]*$//' | grep -v '^#' | grep -v '^$') \
        <(cat "$TMPDIR/second.py" | sed 's/[[:space:]]*$//' | grep -v '^#' | grep -v '^$') \
    && echo "PASS" || echo "FAIL"
