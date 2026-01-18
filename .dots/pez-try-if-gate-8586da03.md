---
title: Try if gate
status: active
priority: 1
issue-type: task
created-at: "\"2026-01-18T12:43:10.161699+02:00\""
---

Full context: src/ctrl.zig:370-416, 836-900; cause: try-setup blocks misdetected as if, suppressing real if inside try (boat_main.init_cameras). Fix: implement hasTrySetup scanning SETUP_EXCEPT/SETUP_FINALLY and gate if detection only for try-setup headers, not all try bodies; re-run decompile/compare.
