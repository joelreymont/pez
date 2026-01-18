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
- exact: 77
- close: 14
- mismatch: 251
- error: 0
- missing_src: 0

## Worst semantic mismatches (min_semantic_score)
- PYZ-00.pyz_extracted/threading.pyc (min=0.0, avg=0.8263)
- PYZ-00.pyz_extracted/datetime.pyc (min=0.0, avg=0.8699)
- PYZ-00.pyz_extracted/subprocess.pyc (min=0.0, avg=0.8430)
- PYZ-00.pyz_extracted/tarfile.pyc (min=0.0, avg=0.8187)
- PYZ-00.pyz_extracted/cameraController.pyc (min=0.0, avg=0.6543)
- PYZ-00.pyz_extracted/platform.pyc (min=0.0, avg=0.8734)
- PYZ-00.pyz_extracted/dataclasses.pyc (min=0.0, avg=0.8988)
- PYZ-00.pyz_extracted/bdb.pyc (min=0.0, avg=0.8777)
- PYZ-00.pyz_extracted/pkgutil.pyc (min=0.0, avg=0.7850)
- PYZ-00.pyz_extracted/signal.pyc (min=0.0, avg=0.9195)

## Notes
- Detailed per-file reports: /private/tmp/pez_compare_boat_reports
- Decompile errors/timeouts: none (see /private/tmp/pez_decompile_boat.json)
