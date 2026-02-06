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
  --out-root /tmp/pez-boatmain-suite-fix2 \
  --out /tmp/pez-boatmain-suite-fix2.json
```

## Summary (from /tmp/pez-boatmain-suite-fix2.json)
- pez decompile: ok=329 error=0
- pez compare: exact=179 close=64 mismatch=86 error=0 missing_src=0
- decompyle3 decompile: ok=329 error=0
- decompyle3 compare: exact=8 close=0 mismatch=321 error=0 missing_src=0

## Worst semantic mismatches (pez, min_semantic_score)
- pkgutil.pyc (min=0.0000)
- psutil/_pslinux.pyc (min=0.0000)
- plistlib.pyc (min=0.0093)
- dis.pyc (min=0.0607)
- inspect.pyc (min=0.0667)
- packaging/metadata.pyc (min=0.0667)
- pdb.pyc (min=0.0667)
- pydoc.pyc (min=0.1023)
- pathlib.pyc (min=0.1189)
- tempfile.pyc (min=0.1350)

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
- repo: /Users/joel/Work/pez/refs/python-decompile3 (@ 936ea1f36610ab20411b59d6d71323f2033a6bc2)
- corpora: /Users/joel/Work/pez/refs/python-decompile3/test/bytecode_3.8, /Users/joel/Work/pez/refs/python-decompile3/test/bytecode_3.7, pypy bytecode under /Users/joel/Work/pez/refs/python-decompile3/test/bytecode_*pypy
