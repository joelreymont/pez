---
title: Fix xdis loader fallback
status: open
priority: 2
issue-type: task
created-at: "2026-02-03T22:23:33.353800+01:00"
---

Context: tools/compare/analyze_xdis.py: load_code fallback only works when pyc magic matches runner; cause: xdis fails to unmarshal some valid py39 stdlib pyc (plistlib.pyc, uuid.pyc, _pydecimal.pyc) -> compare_dir errors; fix: add fallback path that uses python<maj>.<min> marshal.load when available (magic match) + keep xdis for disasm; deps: Update boat_main mismatch doc; verification: compare.py succeeds (no error) on those 3 files and compare_dir error count drops.
