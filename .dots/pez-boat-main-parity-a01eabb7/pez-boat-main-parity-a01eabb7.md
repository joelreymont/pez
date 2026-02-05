---
title: Boat_main parity
status: active
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-05T09:47:22.814382+01:00\\\"\""
---

Full context: boat_main (py3.9) suite run: /tmp/pez-boatmain-suite16.json (artifacts: /tmp/pez-boatmain-suite16/). Pez: decompile ok=329 error=0; compare exact=174 close=54 mismatch=101 error=0 missing_src=0. Decompyle3: decompile ok=329 error=0; compare exact=8 close=0 mismatch=321 error=0 missing_src=0. Pez unit tests: PASS (`zig build test`). Previously-reported pycdc failures now PASS (`./zig-out/bin/pez` exit 0): test_listComprehensions.2.7.pyc (invalid-free), test_loops2.2.2.pyc (hang).

Current target: datetime.pyc (worst_semantic). Drill-down: `<module>._ord2ymd` (min_semantic_score=0.1904).

Plan:
1) Always run `python3 tools/compare/compare_suite.py` on boat_main (and any new corpora) after each fix; keep the latest suite JSON under /tmp for triage.
2) Pick next mismatch from `/tmp/pez-boatmain-suite16/pez_compare.json` (worst_semantic then worst_seq).
3) Repro single file with `tools/compare/compare_driver.py`; locate first divergence with `tools/compare/locate_mismatch.py`; if needed, dump/trace with pez `--trace-*`.
4) Fix root-cause in decompiler (arena-backed; no silent fallbacks; strict errors). Prove with `compare_driver` exact match on the repro file.
5) Add minimal `test/corpus_src/*.py` + compiled `test/corpus/*.pyc` and an ohsnap snapshot test; run `zig build test`.
6) `jj describe -m "..."` per fix; repeat until boat_main mismatch=0.
