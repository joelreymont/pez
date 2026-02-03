# Boat Main Compare Report (py3.9)

## Dataset
- /Users/joel/Work/Shakhed/boat_main_extracted_3.9 (342 files)

## Repro
```bash
zig build -Doptimize=ReleaseFast
python3 tools/compare/decompile_dir.py \
  --pez zig-out/bin/pez \
  --orig-dir /Users/joel/Work/Shakhed/boat_main_extracted_3.9 \
  --out-dir /tmp/pez_boat_main_src_full \
  --timeout 120 \
  --out /tmp/pez_boat_main_decompile_report_full.json

python3 tools/compare/compare_dir.py \
  --orig-dir /Users/joel/Work/Shakhed/boat_main_extracted_3.9 \
  --src-dir /tmp/pez_boat_main_src_full \
  --py python3.9 \
  --xdis-python /private/tmp/uncompyle6-venv312/bin/python \
  --timeout 120 \
  --out /tmp/pez_boat_main_compare_full.json \
  --report-dir /tmp/pez_boat_main_compare_reports_full
```

## Summary (from /tmp/pez_boat_main_compare_full.json)
- total: 342
- exact: 155
- close: 45
- mismatch: 139
- error: 3
- missing_src: 0

## Worst semantic mismatches (min_semantic_score)
- PYZ-00.pyz_extracted/pickle.pyc (min=0.1000)
- PYZ-00.pyz_extracted/aiortc/rtcrtpsender.pyc (min=0.1143)
- PYZ-00.pyz_extracted/certifi/core.pyc (min=0.1333)
- PYZ-00.pyz_extracted/telebot/apihelper.pyc (min=0.1333)
- PYZ-00.pyz_extracted/serial/serialposix.pyc (min=0.1333)
- PYZ-00.pyz_extracted/bdb.pyc (min=0.1462)
- PYZ-00.pyz_extracted/getopt.pyc (min=0.1555)
- PYZ-00.pyz_extracted/calendar.pyc (min=0.1591)
- PYZ-00.pyz_extracted/tarfile.pyc (min=0.1600)
- PYZ-00.pyz_extracted/aioice/ice.pyc (min=0.1600)

## Notes
- Detailed per-file reports: /tmp/pez_boat_main_compare_reports_full
- xdis load errors (valid pyc; python3.9 `marshal.load` works):
  - PYZ-00.pyz_extracted/plistlib.pyc
  - PYZ-00.pyz_extracted/uuid.pyc
  - PYZ-00.pyz_extracted/_pydecimal.pyc
