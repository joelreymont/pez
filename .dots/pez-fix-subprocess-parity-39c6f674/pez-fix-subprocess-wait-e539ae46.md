---
title: Fix subprocess _wait parity
status: closed
priority: 1
issue-type: task
created-at: "\"2026-02-06T13:33:33.245683+01:00\""
closed-at: "2026-02-06T14:00:31.143568+01:00"
close-reason: Implemented _wait lock-release/finally rewrite, added timeout handler normalization, added subprocess regression fixtures and snapshots, committed in 97cba021
blocks:
  - pez-repro-subprocess-wait-fc746981
---

Context: implement decompile rewrite for _wait mismatch, keep glob/tarfile exact
