#!/usr/bin/env bash
set -euo pipefail

# Test decompilation of Python stdlib modules
# Usage: ./test_stdlib.sh [python_version]

PYTHON="${1:-python3.11}"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo "Testing with $PYTHON"

# Find stdlib path
STDLIB=$($PYTHON -c "import sys; print(sys.prefix + '/lib/' + sys.implementation._multiarch + '/python' + sys.version[:4] if hasattr(sys.implementation, '_multiarch') else sys.prefix + '/lib/python' + sys.version[:4])" 2>/dev/null || echo "")
if [[ -z "$STDLIB" || ! -d "$STDLIB" ]]; then
    STDLIB=$($PYTHON -c "import sysconfig; print(sysconfig.get_paths()['stdlib'])")
fi

echo "Stdlib: $STDLIB"

# Test a few simple modules
for mod in abc.py base64.py calendar.py; do
    if [[ ! -f "$STDLIB/$mod" ]]; then
        continue
    fi

    echo "Testing $mod"

    # Compile to pyc
    $PYTHON -m py_compile "$STDLIB/$mod"

    # Find pyc
    PYC=$(find "$STDLIB/__pycache__" -name "${mod%.py}*.pyc" | head -1)
    if [[ -z "$PYC" ]]; then
        echo "  Skipping: no pyc found"
        continue
    fi

    # Decompile
    ./zig-out/bin/pez "$PYC" > "$TMPDIR/${mod}"

    # Verify syntax
    $PYTHON -m py_compile "$TMPDIR/${mod}" && echo "  OK" || echo "  FAIL"
done
