#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
OUT_DIR="$ROOT_DIR/tools/parity/out"
mkdir -p "$OUT_DIR"

: "${PARITY_CORPUS_DIRS:=$ROOT_DIR/refs/pycdc/tests/compiled:$ROOT_DIR/test/corpus}"

zig build

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

ensure_venv() {
  local pybin="$1"
  local venv="$2"
  if [[ ! -f "$venv/pyvenv.cfg" ]]; then
    if [[ -d "$venv" ]]; then
      trash "$venv"
    fi
  fi
  if [[ ! -x "$venv/bin/python" ]]; then
    "$pybin" -m venv "$venv"
  fi
  if [[ ! -x "$venv/bin/pip" ]]; then
    PIP_BREAK_SYSTEM_PACKAGES=1 "$venv/bin/python" -m ensurepip --upgrade
  fi
  PIP_BREAK_SYSTEM_PACKAGES=1 "$venv/bin/python" -m pip install -U pip setuptools wheel
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

  ensure_venv "$pybin" "$UNCOMPYLE6_VENV"
  "$UNCOMPYLE6_VENV/bin/python" -m pip install -U git+https://github.com/rocky/python-xdis.git
  "$UNCOMPYLE6_VENV/bin/python" -m pip install -e "$UNCOMPYLE6_DIR"
  UNCOMPYLE6_BIN="$UNCOMPYLE6_VENV/bin/uncompyle6"
fi

if [[ -z "${DECOMPYLE3_BIN:-}" ]]; then
  DECOMPYLE3_DIR="/tmp/python-decompile3"
  if [[ ! -d "$DECOMPYLE3_DIR" ]]; then
    gh repo clone rocky/python-decompile3 "$DECOMPYLE3_DIR"
  fi

  pybin=$(pick_py || true)
  if [[ -z "${pybin:-}" ]]; then
    if command -v brew >/dev/null 2>&1; then
      brew install python@3.12
      pybin="$(command -v python3.12)"
    fi
  fi
  if [[ -z "${pybin:-}" ]]; then
    echo "Need python3.12 or python3.11 for decompyle3" >&2
    exit 2
  fi

  if [[ "$pybin" == *"python3.12"* ]]; then
    DECOMPYLE3_VENV="/tmp/decompyle3-venv-312"
  else
    DECOMPYLE3_VENV="/tmp/decompyle3-venv-311"
  fi

  ensure_venv "$pybin" "$DECOMPYLE3_VENV"
  "$DECOMPYLE3_VENV/bin/python" -m pip install -U git+https://github.com/rocky/python-xdis.git@f19046be089a515f2041a14a696774e82851d3c5
  "$DECOMPYLE3_VENV/bin/python" -m pip install -e "$DECOMPYLE3_DIR"
  DECOMPYLE3_BIN="$DECOMPYLE3_VENV/bin/decompyle3"
fi

python3 "$ROOT_DIR/tools/parity/run.py" \
  --corpus-dirs "$PARITY_CORPUS_DIRS" \
  --out "$OUT_DIR" \
  --pez "$ROOT_DIR/zig-out/bin/pez" \
  --pycdc "$PYCDC_BIN" \
  --uncompyle6 "$UNCOMPYLE6_BIN" \
  --decompyle3 "$DECOMPYLE3_BIN"
