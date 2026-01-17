---
title: Group import-from
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-17T20:01:43.002382+02:00\\\"\""
closed-at: "2026-01-17T20:08:04.300815+02:00"
close-reason: implemented
---

Full context: src/decompile.zig:798, grouped IMPORT_FROM sequences currently emitted as separate statements which skews roundtrip compare; fix by invoking tryDecompileImportFromGroup to collapse IMPORT_FROM+STORE pairs into one import_from stmt and skip consumed ops.
