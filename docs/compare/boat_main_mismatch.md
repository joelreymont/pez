# Boat Main Compare Report (py3.9)

## Dataset
- /Users/joel/Work/Shakhed/boat_main_extracted_3.9

## Repro
```bash
zig build -Doptimize=ReleaseFast
python3 tools/compare/decompile_dir.py \
  --pez zig-out/bin/pez \
  --orig-dir /Users/joel/Work/Shakhed/boat_main_extracted_3.9 \
  --out-dir /private/tmp/pez_decompiled_boat_20260202i \
  --timeout 120 \
  --keep-stderr \
  --out /private/tmp/pez_decompile_boat_20260202i.json

# xdis venv (one-time)
python3 -m venv /tmp/pez-xdis
/tmp/pez-xdis/bin/pip install xdis

python3 tools/compare/compare_dir.py \
  --orig-dir /Users/joel/Work/Shakhed/boat_main_extracted_3.9 \
  --src-dir /private/tmp/pez_decompiled_boat_20260202i \
  --py /Users/joel/.local/bin/python3.9 \
  --xdis-python /tmp/pez-xdis/bin/python \
  --timeout 120 \
  --out /private/tmp/pez_compare_boat_20260202i.json \
  --report-dir /private/tmp/pez_compare_boat_reports_20260202i
```

## Summary (from /private/tmp/pez_compare_boat_20260202i.json)
- total: 342
- exact: 152
- close: 43
- mismatch: 139
- error: 0
- missing_src: 8

## Worst semantic mismatches (min_semantic_score)
- PYZ-00.pyz_extracted/pickle.pyc (min=0.1000)
- PYZ-00.pyz_extracted/aiortc/rtcrtpsender.pyc (min=0.1143)
- PYZ-00.pyz_extracted/bdb.pyc (min=0.1317)
- PYZ-00.pyz_extracted/certifi/core.pyc (min=0.1333)
- PYZ-00.pyz_extracted/serial/serialposix.pyc (min=0.1333)
- PYZ-00.pyz_extracted/pathlib.pyc (min=0.1491)
- PYZ-00.pyz_extracted/telebot/__init__.pyc (min=0.1531)
- PYZ-00.pyz_extracted/pycparser/ply/lex.pyc (min=0.1544)
- PYZ-00.pyz_extracted/getopt.pyc (min=0.1555)
- PYZ-00.pyz_extracted/calendar.pyc (min=0.1591)

## Notes
- Detailed per-file reports: /private/tmp/pez_compare_boat_reports_20260202i
- Decompile errors: 8 (see /private/tmp/pez_decompile_boat_20260202i.json)
