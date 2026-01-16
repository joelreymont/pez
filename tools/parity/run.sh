#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
OUT_DIR="$ROOT_DIR/tools/parity/out"
mkdir -p "$OUT_DIR"

: "${PARITY_CORPUS_DIRS:=$ROOT_DIR/refs/pycdc/tests/compiled:$ROOT_DIR/test/corpus}"

zig build

if [[ -z "${PYCDC_BIN:-}" ]]; then
  PYCDC_DIR="/tmp/pycdc"
  if [[ ! -d "$PYCDC_DIR" ]]; then
    git clone https://github.com/zrax/pycdc.git "$PYCDC_DIR"
  fi
  if [[ ! -x "$PYCDC_DIR/build/pycdc" ]]; then
    cmake -S "$PYCDC_DIR" -B "$PYCDC_DIR/build"
    cmake --build "$PYCDC_DIR/build"
  fi
  PYCDC_BIN="$PYCDC_DIR/build/pycdc"
fi

if [[ -z "${UNCOMPYLE6_BIN:-}" ]]; then
  UNCOMPYLE6_DIR="/tmp/uncompyle6"
  if [[ ! -d "$UNCOMPYLE6_DIR" ]]; then
    git clone https://github.com/rocky/python-uncompyle6.git "$UNCOMPYLE6_DIR"
  fi

  pick_py() {
    if command -v python3.12 >/dev/null 2>&1; then
      echo "$(command -v python3.12)"
      return 0
    fi
    if command -v python3.11 >/dev/null 2>&1; then
      echo "$(command -v python3.11)"
      return 0
    fi
    return 1
  }

  pybin=$(pick_py || true)
  if [[ -z "${pybin:-}" ]]; then
    if command -v brew >/dev/null 2>&1; then
      brew install python@3.12
      pybin="$(command -v python3.12)"
    fi
  fi
  if [[ -z "${pybin:-}" ]]; then
    echo "Need python3.12 or python3.11 for uncompyle6" >&2
    exit 2
  fi

  if [[ "$pybin" == *"python3.12"* ]]; then
    UNCOMPYLE6_VENV="/tmp/uncompyle6-venv312"
  else
    UNCOMPYLE6_VENV="/tmp/uncompyle6-venv311"
  fi

  if [[ ! -x "$UNCOMPYLE6_VENV/bin/python" ]]; then
    "$pybin" -m venv "$UNCOMPYLE6_VENV"
  fi
  "$UNCOMPYLE6_VENV/bin/pip" install -U pip setuptools wheel
  "$UNCOMPYLE6_VENV/bin/pip" install -U git+https://github.com/rocky/python-xdis.git
  "$UNCOMPYLE6_VENV/bin/pip" install -e "$UNCOMPYLE6_DIR"
  UNCOMPYLE6_BIN="$UNCOMPYLE6_VENV/bin/uncompyle6"
fi

python3 "$ROOT_DIR/tools/parity/run.py" \
  --corpus-dirs "$PARITY_CORPUS_DIRS" \
  --out "$OUT_DIR" \
  --pez "$ROOT_DIR/zig-out/bin/pez" \
  --pycdc "$PYCDC_BIN" \
  --uncompyle6 "$UNCOMPYLE6_BIN"
