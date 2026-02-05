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
  --out-root /tmp/pez-boatmain-suite16 \
  --out /tmp/pez-boatmain-suite16.json
```

## Summary (from /tmp/pez-boatmain-suite16.json)
- pez decompile: ok=329 error=0
- pez compare: exact=174 close=54 mismatch=101 error=0 missing_src=0
- decompyle3 decompile: ok=329 error=0
- decompyle3 compare: exact=8 close=0 mismatch=321 error=0 missing_src=0

## Worst semantic mismatches (pez, min_semantic_score)
- datetime.pyc (min=0.1904)
- aioice/mdns.pyc (min=0.1965)
- packaging/specifiers.pyc (min=0.2000)
- telebot/types.pyc (min=0.2000)
- typing.pyc (min=0.2000)
- subprocess.pyc (min=0.2000)
- code.pyc (min=0.2000)
- ftplib.pyc (min=0.2000)
- glob.pyc (min=0.2000)
- picamera2/controls.pyc (min=0.2000)

## Drill-down (single file)
```bash
python3 tools/compare/compare_driver.py \
  --orig /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted/datetime.pyc \
  --pez zig-out/bin/pez \
  --py python3.9 \
  --xdis-python /private/tmp/xdis-venv39/bin/python \
  --path '<module>._ord2ymd' \
  --out /tmp/pez-datetime-ord2ymd.json \
  --keep-temp

SRC="$(python3 - <<'PY'
import json
print(json.load(open('/tmp/pez-datetime-ord2ymd.json'))['decompiled_src'])
PY
)"

python3 tools/compare/locate_mismatch.py \
  --orig /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted/datetime.pyc \
  --src "$SRC" \
  --path '<module>._ord2ymd' \
  --py python3.9 \
  --xdis-python /private/tmp/xdis-venv39/bin/python \
  --out /tmp/pez-datetime-ord2ymd-locate.json
```

## Decompyle3 corpus (extra .pyc fixtures)
- repo: /tmp/python-decompile3
- corpora: /tmp/python-decompile3/test/bytecode_3.8 (needs python3.8), /tmp/python-decompile3/test/bytecode_3.7, pypy bytecode under /tmp/python-decompile3/test/bytecode_*pypy
