---
title: Wire uv paths in compare tools
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-05T20:10:35.732289+01:00\\\"\""
closed-at: "2026-02-05T20:14:32.725377+01:00"
close-reason: completed
blocks:
  - pez-add-uv-venv-48730f83
---

Context: /Users/joel/Work/pez/tools/compare/lib.py:40-100, /Users/joel/Work/pez/tools/compare/compare_suite.py:16-70; cause: /tmp venv fallbacks; fix: prefer .uv/py39 python + decompyle3; deps: pez-add-uv-venv-48730f83; verification: compare_suite uses uv paths
