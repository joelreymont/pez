---
name: instruments-profile
description: macOS Instruments profiling workflow for performance investigations. Use when profiling compilation, throughput, or any performance regression where Instruments Time Profiler (xctrace) is required.
---

# Instruments Profile

## Overview

Use macOS Instruments (xctrace Time Profiler) to capture call stacks with symbols for performance work.

## Workflow

### 1) Build with symbols

Always profile optimized code without stripping symbols:
```bash
timeout 60s zig build -Doptimize=ReleaseFast -Dstrip=false
```

### 2) Capture a Time Profiler trace

Use a short capture window and Time Profiler template:
```bash
OUT=/tmp/pez-profile-$(date +%s).trace
timeout 60s xcrun xctrace record --template "Time Profiler" --time-limit 20s --output "$OUT" \
  --launch -- ./zig-out/bin/pez <args>
```

### 3) Export sample data for inspection

Export the time-profile table (schema shows stack samples):
```bash
xcrun xctrace export --input "$OUT" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
  --output /tmp/pez-profile.time-profile.xml
```

### 4) Triage hotspots

Look for repeated stack frames and dominant call paths, then map them to code locations. Prioritize:
- Tight loops (allocator, hash/maps, memmove, sorting)
- High-frequency recursive lowering
- Large cache lookups or hashing
