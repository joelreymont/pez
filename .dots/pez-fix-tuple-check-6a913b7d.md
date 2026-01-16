---
title: Fix tuple check with switch
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T08:01:29.205486+02:00"
---

File: src/stack.zig:3466
Replace direct comparison with proper switch:
if (keys_val == .expr) {
    switch (keys_val.expr.*) {
        .tuple => |t| { extract keys from t.elts },
        else => { set keys to null },
    }
}
Dependencies: pez-read-build-const-ae05fc67
Verify: zig build test
