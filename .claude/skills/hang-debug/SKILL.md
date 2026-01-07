---
name: hang-debug
description: Debug hangs/timeouts in tests or builds. Use when a build/test times out, seems stuck, or needs an lldb backtrace.
---

# Hang Debug

## Run the process in the background

```bash
timeout 60s zig build test -Doptimize=ReleaseFast -Dstrip=false &
proc_pid=$!
```

## Find the test process PID

```bash
pgrep -P $proc_pid
# If that is the zig build PID, drill down:
pgrep -P <zig_pid>
# Or search directly:
pgrep -fl '\\.zig-cache/.*/test'
```

## Attach lldb and capture backtraces

```bash
lldb -p <test_pid> -o "thread backtrace all" -o "detach" -o "quit"
```

## Report

- Note the hottest stack(s) and the frame where the program is spending time.
- If it is still actively allocating or iterating, report it as active (not a tight loop).
