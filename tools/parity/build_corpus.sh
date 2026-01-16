#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
OUT_DIR="$ROOT_DIR/test/parity_corpus"
SRC_DIRS="${PARITY_SRC_DIRS:-$ROOT_DIR/test/corpus_src}"
PY_VERSIONS="${PARITY_PYTHONS:-3.8 3.9 3.10 3.11 3.12 3.13 3.14}"

mkdir -p "$OUT_DIR"

find_python() {
  local ver="$1"
  if command -v "python$ver" >/dev/null 2>&1; then
    command -v "python$ver"
    return 0
  fi
  if command -v pyenv >/dev/null 2>&1; then
    local prefix
    prefix=$(pyenv prefix "$ver" 2>/dev/null || true)
    if [[ -n "$prefix" && -x "$prefix/bin/python" ]]; then
      echo "$prefix/bin/python"
      return 0
    fi
  fi
  return 1
}

for ver in $PY_VERSIONS; do
  pybin=$(find_python "$ver") || { echo "Missing python $ver" >&2; exit 2; }
  ver_out="$OUT_DIR/$ver"
  rm -rf "$ver_out"
  mkdir -p "$ver_out"

  for src_dir in $SRC_DIRS; do
    if [[ ! -d "$src_dir" ]]; then
      echo "Missing source dir: $src_dir" >&2
      exit 2
    fi
    for src in "$src_dir"/*.py; do
      [[ -f "$src" ]] || continue
      "$pybin" -m py_compile "$src"
      cache_dir="$src_dir/__pycache__"
      if [[ -d "$cache_dir" ]]; then
        cp "$cache_dir"/*.pyc "$ver_out"/
        rm -rf "$cache_dir"
      fi
    done
  done

done

echo "Wrote parity corpus to $OUT_DIR"
