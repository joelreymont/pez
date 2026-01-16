---
title: Update decompileMatch to pass is_first_case
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:51:27.912565+02:00"
---

src/decompile.zig:decompileMatch: Update callers.
- Pass is_first_case=true for first case, false for rest
- Loop over cases with index tracking
- Depends: is_first_case param
- Verify: zig build
