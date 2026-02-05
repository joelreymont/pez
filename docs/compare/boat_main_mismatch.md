# Boat Main Compare Report (py3.9)

## Dataset
- /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted (329 .pyc)

## One-shot suite (pez + decompyle3)
```bash
zig build -Doptimize=ReleaseFast
python3 tools/compare/compare_suite.py \
  --orig-dir /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted \
  --py /Users/joel/Work/pez/.uv/py39/bin/python \
  --xdis-python /Users/joel/Work/pez/.uv/py39/bin/python \
  --decompyle3 /Users/joel/Work/pez/.uv/py39/bin/decompyle3 \
  --out-root /tmp/pez-boatmain-suite18 \
  --out /tmp/pez-boatmain-suite18.json
```

## Summary (from /tmp/pez-boatmain-suite18.json)
- pez decompile: ok=329 error=0
- pez compare: exact=173 close=54 mismatch=102 error=0 missing_src=0
- decompyle3 decompile: ok=329 error=0
- decompyle3 compare: exact=8 close=0 mismatch=321 error=0 missing_src=0

## Worst semantic mismatches (pez, min_semantic_score)
- aioice/mdns.pyc (min=0.1965)
- code.pyc (min=0.2000)
- ftplib.pyc (min=0.2000)
- glob.pyc (min=0.2000)
- packaging/specifiers.pyc (min=0.2000)
- picamera2/controls.pyc (min=0.2000)
- subprocess.pyc (min=0.2000)
- tarfile.pyc (min=0.2000)
- telebot/types.pyc (min=0.2000)
- typing.pyc (min=0.2000)

## Drill-down (single file)
```bash
python3 tools/compare/compare_driver.py \
  --orig /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted/aioice/mdns.pyc \
  --pez zig-out/bin/pez \
  --py /Users/joel/Work/pez/.uv/py39/bin/python \
  --xdis-python /Users/joel/Work/pez/.uv/py39/bin/python \
  --path '<module>' \
  --out /tmp/pez-aioice-mdns.json \
  --keep-temp

SRC="$(python3 - <<'PY'
import json
print(json.load(open('/tmp/pez-aioice-mdns.json'))['decompiled_src'])
PY
)"

python3 tools/compare/locate_mismatch.py \
  --orig /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted/aioice/mdns.pyc \
  --src "$SRC" \
  --path '<module>' \
  --py /Users/joel/Work/pez/.uv/py39/bin/python \
  --xdis-python /Users/joel/Work/pez/.uv/py39/bin/python \
  --out /tmp/pez-aioice-mdns-locate.json
```

## Decompyle3 corpus (extra .pyc fixtures)
- repo: /Users/joel/Work/pez/refs/python-decompile3
- corpora: /Users/joel/Work/pez/refs/python-decompile3/test/bytecode_3.8, /Users/joel/Work/pez/refs/python-decompile3/test/bytecode_3.7, pypy bytecode under /Users/joel/Work/pez/refs/python-decompile3/test/bytecode_*pypy
