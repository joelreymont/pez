---
title: Fix handler cleanup output
status: active
priority: 2
issue-type: task
created-at: "\"2026-01-17T15:42:17.942881+02:00\""
---

Full context: compare failures show IndentationError; decompiled outputs contain '__exception__' and mis-indented handler bodies (e.g., /tmp/argparse.new.py:1016-1017). Likely handler body range/cleanup handling bug. Investigate decompileTry/decompileHandlerBody to skip exception cleanup blocks and correctly bind exception names; remove placeholder assignments from output; rerun compare.
