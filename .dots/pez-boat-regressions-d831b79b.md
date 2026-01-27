---
title: Boat regressions
status: open
priority: 2
issue-type: task
created-at: "2026-01-29T12:12:28.358650+01:00"
---

Context: src/test_boat_main_regressions_snapshot.zig:1; cause: boolop/if/try output differs from snapshots; fix: audit control-flow rewrite/merge logic in src/decompile.zig:18124 and related; deps: Capture failures; verification: boat_main_regressions snapshot tests.
