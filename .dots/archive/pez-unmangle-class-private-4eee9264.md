---
title: Unmangle class-private names
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-18T08:26:36.899547+02:00\\\"\""
closed-at: "2026-01-18T08:55:26.107279+02:00"
close-reason: completed
---

Full context: src/decompile.zig:9505 (decompileNestedBody), src/decompile.zig:9647 (makeClassDef), src/decompile.zig:9706 (handleStoreValue). Cause: class-private identifiers stay mangled (_Class__name) in class/function bodies. Fix: track class_name on Decompiler, propagate to nested decompilers, unmangle names when creating Name/Attribute/Store where class_name applies.
