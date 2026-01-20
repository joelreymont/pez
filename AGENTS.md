# Pez

## Active Plan

Decompiler parity spec: `~/.claude/plans/composed-wishing-diffie.md`

## Dot

- Run dot without asking when task tracking helps.

## Tools

- When new tooling would speed or unblock work, add it plus skills/triggers, then use it.

## Build

```bash
zig build        # compile
zig build run    # run
zig build test   # test
```

## Zig 0.15 Reference

See `docs/zig-0.15-io-api.md` for I/O and container API changes.

Key points:
- ArrayList is unmanaged: pass allocator to methods
- I/O: `std.fs.File.stdout()` not `std.io.getStdOut()`
- Allocator is always the first argument
