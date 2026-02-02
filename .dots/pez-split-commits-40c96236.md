---
title: Split commits
status: active
priority: 2
issue-type: task
created-at: "\"2026-02-02T18:05:14.262395+01:00\""
---

Context: mixed changes in src/decompile.zig, src/ctrl.zig, tools/compare/*; cause: multiple fixes bundled; fix: split tool updates vs decompiler/tests into separate jj commits; verification: jj log shows distinct changesets.
