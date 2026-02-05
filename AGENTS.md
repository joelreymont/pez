# Pez

## Active Plan

Decompiler parity spec: `~/.claude/plans/composed-wishing-diffie.md`

## Dot

- Run dot without asking when task tracking helps.
- Never `dot off` unless the work is implemented, tests are updated, and the change is committed.
- After `dot off`, start a fresh change (`jj new`) before doing more work.

## Version Control (jj)

- Use `jj` for all VCS operations.
- Commit after every significant fix/feature; one fix/feature per commit.
- Use `jj describe -m "msg"` for commit messages; keep them short and imperative.
- Keep `master` as the integration bookmark and push with `jj git push`.

## Tools

- When new tooling would speed or unblock work, add it plus local skills/triggers, then use it.

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
