---
title: Wire uv paths in parity harness
status: open
priority: 1
issue-type: task
created-at: "2026-02-05T20:10:39.333704+01:00"
blocks:
  - pez-add-uv-venv-48730f83
---

Context: /Users/joel/Work/pez/tools/parity/run.sh:40-120; cause: /tmp venvs; fix: use .uv/py312 and auto-create via uv; deps: pez-add-uv-venv-48730f83; verification: parity run uses uv bins
