---
title: Repro glob divergence
status: closed
priority: 1
issue-type: task
created-at: "\"2026-02-06T12:38:05.877862+01:00\""
closed-at: "2026-02-06T12:49:08.384428+01:00"
close-reason: implemented in 9f96c628
---

Context: tools/compare/compare_driver.py; cause: need unit-level non-exact rows for glob.pyc; fix: run compare_driver with uv py39 and capture /tmp/glob-driver.json; deps: none; verification: JSON has non-exact path list
