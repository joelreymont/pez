---
title: [MED] stack-seed
status: open
priority: 2
issue-type: task
created-at: "2026-01-30T12:56:03.505483+01:00"
---

Full context: src/decompile.zig:2045-2083; cause: initStackFlow seeds only entry block; exception handlers lack stack placeholders; fix: seed handler blocks with exception values or integrate exception edges in flow.
