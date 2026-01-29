---
title: Wire def align
status: open
priority: 2
issue-type: task
created-at: "2026-01-29T17:55:05.089502+01:00"
---

Context: src/decompile.zig:22080 and 22577; cause: module output ignores child code firstlineno; fix: apply alignDefLines to module output before write; deps: none; verification: zig build run -- test/corpus/ternary_attr_prelude.3.9.pyc
