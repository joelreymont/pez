#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
OUT_DIR="$ROOT_DIR/tools/parity/out"
mkdir -p "$OUT_DIR"

: "${PARITY_CORPUS_DIRS:=$ROOT_DIR/refs/pycdc/tests/compiled:$ROOT_DIR/test/corpus}"

zig build

ensure_uv_py312() {
  local venv="$ROOT_DIR/.uv/py312"
  if [[ ! -x "$venv/bin/python" ]]; then
    uv python install 3.12
    uv venv -p 3.12 "$venv"
  fi
  echo "$venv"
}

if [[ -z "${PYCDC_BIN:-}" ]]; then
  PYCDC_DIR="/tmp/pycdc"
  if [[ ! -d "$PYCDC_DIR/.git" || ! -f "$PYCDC_DIR/CMakeLists.txt" ]]; then
    if [[ -d "$PYCDC_DIR" ]]; then
      trash "$PYCDC_DIR"
    fi
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

  UNCOMPYLE6_VENV="$(ensure_uv_py312)"
  uv pip install -p "$UNCOMPYLE6_VENV" -U xdis
  uv pip install -p "$UNCOMPYLE6_VENV" -e "$UNCOMPYLE6_DIR"
  UNCOMPYLE6_BIN="$UNCOMPYLE6_VENV/bin/uncompyle6"
fi

if [[ -z "${DECOMPYLE3_BIN:-}" ]]; then
  DECOMPYLE3_DIR="/tmp/python-decompile3"
  if [[ ! -d "$DECOMPYLE3_DIR" ]]; then
    if [[ -d "$ROOT_DIR/refs/python-decompile3" ]]; then
      DECOMPYLE3_DIR="$ROOT_DIR/refs/python-decompile3"
    else
      gh repo clone rocky/python-decompile3 "$DECOMPYLE3_DIR"
    fi
  fi

  DECOMPYLE3_VENV="$(ensure_uv_py312)"
  uv pip install -p "$DECOMPYLE3_VENV" -U xdis
  uv pip install -p "$DECOMPYLE3_VENV" -e "$DECOMPYLE3_DIR"
  DECOMPYLE3_BIN="$DECOMPYLE3_VENV/bin/decompyle3"
fi

python3 "$ROOT_DIR/tools/parity/run.py" \
  --corpus-dirs "$PARITY_CORPUS_DIRS" \
  --out "$OUT_DIR" \
  --pez "$ROOT_DIR/zig-out/bin/pez" \
  --pycdc "$PYCDC_BIN" \
  --uncompyle6 "$UNCOMPYLE6_BIN" \
  --decompyle3 "$DECOMPYLE3_BIN"
