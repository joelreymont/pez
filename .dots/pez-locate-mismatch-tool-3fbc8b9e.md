---
title: locate mismatch tool
status: open
priority: 2
issue-type: task
created-at: "2026-01-20T13:32:54.319956+02:00"
---

Full context: tools/compare/locate_mismatch.py: new script to align first bytecode mismatch with block ids. Cause: debugging serial_for_url mismatch slow. Fix: compile src, run unit diff, map offsets to cfg blocks via dump_view, print aligned context. Why: pinpoint divergence quickly.
