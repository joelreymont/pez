# Boat Main Compare Report (py3.9)

## Dataset
- /Users/joel/Work/Shakhed/boat_main_extracted_3.9

## Repro
```bash
zig build -Doptimize=ReleaseFast
python3 tools/compare/decompile_dir.py \
  --pez zig-out/bin/pez \
  --orig-dir /Users/joel/Work/Shakhed/boat_main_extracted_3.9 \
  --out-dir /private/tmp/pez_decompiled_boat \
  --timeout 120 \
  --keep-stderr \
  --out /private/tmp/pez_decompile_boat.json

# xdis venv (one-time)
python3 -m venv /tmp/pez-xdis
/tmp/pez-xdis/bin/pip install xdis

python3 tools/compare/compare_dir.py \
  --orig-dir /Users/joel/Work/Shakhed/boat_main_extracted_3.9 \
  --src-dir /private/tmp/pez_decompiled_boat \
  --py /Users/joel/.local/bin/python3.9 \
  --xdis-python /tmp/pez-xdis/bin/python \
  --timeout 120 \
  --out /private/tmp/pez_compare_boat.json \
  --report-dir /private/tmp/pez_compare_boat_reports
```

## Summary (from /private/tmp/pez_compare_boat.json)
- total: 342
- exact: 146
- close: 42
- mismatch: 146
- error: 0
- missing_src: 8

## Worst semantic mismatches (min_semantic_score)
- PYZ-00.pyz_extracted/difflib.pyc (min=0.025)
- PYZ-00.pyz_extracted/argparse.pyc (min=0.05)
- PYZ-00.pyz_extracted/doctest.pyc (min=0.074)
- PYZ-00.pyz_extracted/quopri.pyc (min=0.0848)
- PYZ-00.pyz_extracted/datetime.pyc (min=0.0973)
- PYZ-00.pyz_extracted/telebot/__init__.pyc (min=0.1)
- PYZ-00.pyz_extracted/bdb.pyc (min=0.1143)
- PYZ-00.pyz_extracted/piexif/_dump.pyc (min=0.12)
- PYZ-00.pyz_extracted/inspect.pyc (min=0.1253)
- PYZ-00.pyz_extracted/subprocess.pyc (min=0.1254)

## Notes
- Detailed per-file reports: /private/tmp/pez_compare_boat_reports
- Decompile errors/timeouts: none (see /private/tmp/pez_decompile_boat.json)
