---
title: Fix imp mismatch paths
status: active
priority: 1
issue-type: task
created-at: "\"2026-02-07T10:12:40.634527+01:00\""
---

Files: src/decompile.zig + /tmp/pez-imp-driver.json; cause: imp.pyc mismatch in find_module/load_module structural control-flow; fix: locate first divergence and normalize if/for break structure with snapshots; proof: imp.pyc verdict close/exact and suite mismatch decreases.
