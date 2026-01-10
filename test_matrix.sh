#!/usr/bin/env bash
set -euo pipefail

# Test same Python source across multiple Python versions
# All versions should decompile to equivalent source

VERSIONS=(python2.7 python3.6 python3.7 python3.8 python3.9 python3.10 python3.11 python3.12 python3.13)
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Simple test program
cat > "$TMPDIR/test.py" <<'EOF'
def foo(x):
    if x > 0:
        return x * 2
    else:
        return 0

def bar(items):
    result = []
    for item in items:
        if item % 2 == 0:
            result.append(item)
    return result
EOF

echo "Testing across Python versions"

for ver in "${VERSIONS[@]}"; do
    if ! command -v "$ver" &>/dev/null; then
        echo "  $ver: SKIP (not installed)"
        continue
    fi

    echo -n "  $ver: "

    # Compile
    $ver -m py_compile "$TMPDIR/test.py" 2>/dev/null || {
        echo "SKIP (compile failed)"
        continue
    }

    # Find pyc
    PYC=$(find "$TMPDIR" -name "test*.pyc" -o -name "test.pyc" 2>/dev/null | head -1)
    if [[ -z "$PYC" || ! -f "$PYC" ]]; then
        echo "SKIP (no pyc)"
        rm -rf "$TMPDIR/__pycache__"
        continue
    fi

    # Decompile
    if ./zig-out/bin/pez "$PYC" > "$TMPDIR/$ver.py" 2>/dev/null; then
        # Check for expected symbols
        if grep -q "def foo" "$TMPDIR/$ver.py" && grep -q "def bar" "$TMPDIR/$ver.py"; then
            echo "OK"
        else
            echo "FAIL (missing symbols)"
        fi
    else
        echo "FAIL (decompile error)"
    fi

    rm -rf "$TMPDIR/__pycache__" "$PYC"
done
