---
title: try regions
status: open
priority: 1
issue-type: task
created-at: "2026-01-24T12:38:33.881029+02:00"
---

Full context: src/ctrl.zig:1508 detectTryPattern; cause: try/except regions inferred ad-hoc and decompile still edge-walks; fix: model try regions explicitly in ctrl and have decompile consume boundaries only; why: correct handler bodies and stable merges.
