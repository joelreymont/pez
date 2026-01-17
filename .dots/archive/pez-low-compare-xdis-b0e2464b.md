---
title: [LOW] compare xdis impl
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T23:17:28.437531+02:00\""
closed-at: "2026-01-16T23:17:31.758082+02:00"
---

Full context: tools/compare/compare.py helper. Cause: xdis load_module tuple index for implementation is version-dependent; tool reads res[4] and passes wrong impl, breaking disassembly. Fix: detect PythonImplementation in result and default CPython.
