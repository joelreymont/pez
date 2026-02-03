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
  --xdis-python /private/tmp/xdis-venv39/bin/python \
  --timeout 120 \
  --out /tmp/pez_boat_main_compare_full_xdis39.json \
  --report-dir /tmp/pez_boat_main_compare_reports_full_xdis39
```

## Summary (from /tmp/pez_boat_main_compare_full_xdis39.json)
- total: 342
- exact: 155
- close: 45
- mismatch: 142
- error: 0
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
- Detailed per-file reports: /tmp/pez_boat_main_compare_reports_full_xdis39
- Use xdis under python3.9 for this dataset; python3.12+xdis fails to load some stdlib pyc.

## Locate mismatch (top files)
- zipfile.pyc (<module>._ZipWriteFile.close): idx 5, orig EXTENDED_ARG 256 @off 10 blk 2, comp SETUP_FINALLY to 102 @off 10 blk 2
- aioice/stun.pyc (<module>): idx 0, orig SETUP_ANNOTATIONS @off 0 blk 0, comp LOAD_NAME ATTRIBUTES @off 0 blk 0
- datetime.pyc (<module>.time.__hash__): idx 4, orig POP_JUMP_IF_FALSE to 210 @off 8 blk 0, comp POP_JUMP_IF_FALSE to 34 @off 8 blk 0
- shlex.pyc (<module>.split): idx 26, orig POP_JUMP_IF_TRUE to 60 @off 52 blk 2, comp POP_JUMP_IF_FALSE to 62 @off 52 blk 2
- getopt.pyc (<module>.getopt): idx 18, orig LOAD_FAST args @off 36 blk 3, comp LOAD_CONST None @off 36 blk 3

## Fix targets
- zipfile.pyc: EXTENDED_ARG vs SETUP_FINALLY in _ZipWriteFile.close @off 10 blk 2
- aioice/stun.pyc: SETUP_ANNOTATIONS vs LOAD_NAME ATTRIBUTES @off 0 blk 0
- datetime.pyc: POP_JUMP_IF_FALSE target mismatch in time.__hash__ @off 8 blk 0
- shlex.pyc: POP_JUMP_IF_TRUE vs POP_JUMP_IF_FALSE in split @off 52 blk 2
- getopt.pyc: LOAD_FAST args vs LOAD_CONST None in getopt @off 36 blk 3
