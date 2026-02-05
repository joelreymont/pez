# Boat Main Compare Report (py3.9)

## Dataset
- /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted (329 .pyc)

## One-shot suite (pez + decompyle3)
```bash
zig build -Doptimize=ReleaseFast
python3 tools/compare/compare_suite.py \
  --orig-dir /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted \
  --py python3.9 \
  --xdis-python /private/tmp/xdis-venv39/bin/python \
  --out-root /tmp/pez-boatmain-suite \
  --out /tmp/pez-boatmain-suite.json
```

## Summary (from /tmp/pez-boatmain-suite7.json)
- pez decompile: ok=329 error=0
- pez compare: exact=164 close=48 mismatch=117 error=0 missing_src=0
- decompyle3 decompile: ok=329 error=0
- decompyle3 compare: exact=8 close=0 mismatch=321 error=0 missing_src=0

## Worst semantic mismatches (pez, min_semantic_score)
- bdb.pyc (min=0.0)
- picamera2/outputs/fileoutput.pyc (min=0.1143)
- optparse.pyc (min=0.1162)
- statistics.pyc (min=0.1333)
- getopt.pyc (min=0.1555)
- calendar.pyc (min=0.1591)
- aioice/ice.pyc (min=0.1600)
- tarfile.pyc (min=0.1600)
- pycparser/ply/yacc.pyc (min=0.1686)
- pycparser/ply/lex.pyc (min=0.1903)

## Drill-down (single file)
```bash
python3 tools/compare/compare_driver.py \
  --orig /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted/bdb.pyc \
  --src /tmp/pez-boatmain-suite7/pez_src/bdb.py \
  --pez zig-out/bin/pez \
  --py python3.9 \
  --xdis-python /private/tmp/xdis-venv39/bin/python \
  --out /tmp/pez-bdb-compare.json

python3 tools/compare/locate_mismatch.py \
  --orig /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted/bdb.pyc \
  --src /tmp/pez-boatmain-suite7/pez_src/bdb.py \
  --path '<module>' \
  --py python3.9 \
  --xdis-python /private/tmp/xdis-venv39/bin/python \
  --out /tmp/pez-bdb-locate.json
```
