---
title: strict-parse-errors
status: open
priority: 2
issue-type: task
created-at: "2026-01-29T16:04:47.828231+01:00"
---

Full context: src/pyc.zig:1255-1265; src/pycdc_tests.zig:30-31; cause: forbidden catch-return error handling; fix: introduce helpers returning ParseError/InvalidFilename and use try at call sites.
