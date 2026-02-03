---
title: Wire decompyle3 compare
status: open
priority: 2
issue-type: task
created-at: "2026-02-03T22:23:38.219400+01:00"
---

Context: /tmp/python-decompile3 + tools/compare; cause: no direct harness to run decompyle3 on same corpus and compare with pez output; fix: add tools/compare/decompyle3_dir.py + docs entry to run decompyle3 decompile then tools/compare/compare_dir.py; deps: Fix xdis loader fallback; verification: can run on boat_main subset and produce summary JSON.
