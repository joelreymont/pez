---
title: [HIGH] seed-path
status: open
priority: 2
issue-type: task
created-at: "2026-01-30T12:56:03.488882+01:00"
---

Full context: src/decompile.zig:6225-6231,18569-18575; cause: predecessor selection by block id heuristic can pick wrong path; fix: select via CFG reachability/postdom or dataflow; add test.
