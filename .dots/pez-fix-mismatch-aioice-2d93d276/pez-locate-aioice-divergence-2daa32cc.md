---
title: Locate aioice divergence
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-05T21:24:24.412226+01:00\""
closed-at: "2026-02-05T22:09:30.621346+01:00"
close-reason: completed
blocks:
  - pez-repro-aioice-mdns-f5a535e7
---

Context: tools/compare/locate_mismatch.py:1, tools/compare/unit_trace.py:1; cause: first instruction divergence and CFG delta unknown; fix: run locate_mismatch+unit_trace for <module>.MDnsProtocol.resolve and map block ids to source offsets; deps: pez-repro-aioice-mdns-f5a535e7; verification: /tmp/pez-aioice-mdns-resolve-locate*.json + /tmp/pez-aioice-mdns-resolve-unittrace*.json updated.
