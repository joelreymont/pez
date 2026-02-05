---
title: Locate telebot types divergence
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-05T21:25:22.502607+01:00\""
closed-at: "2026-02-05T22:27:33.511034+01:00"
close-reason: completed
blocks:
  - pez-repro-telebot-types-7a75ab24
---

Context: tools/compare/locate_mismatch.py:1, tools/compare/unit_trace.py:1; cause: first divergence and CFG delta unknown; fix: run locate_mismatch+unit_trace and map diverging block/edge signatures; deps: pez-repro-telebot-types-7a75ab24; verification: locate/unittrace artifacts for telebot types written to /tmp.
