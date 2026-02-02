//! Snapshot tests for pycdc regressions.

const std = @import("std");
const testing = std.testing;
const OhSnap = @import("ohsnap");

const tu = @import("test_utils.zig");

test "snapshot pycdc yield 2.2" {
    const allocator = testing.allocator;
    const output = try tu.renderPycFile(allocator, "refs/pycdc/tests/compiled/test_yield.2.2.pyc", false);
    defer allocator.free(output);

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]u8
        \\  "from __future__ import generators
        \\def inorder(t):
        \\    if t:
        \\        for x in inorder(t.left):
        \\            yield x
        \\        yield t.label
        \\        for x in inorder(t.right):
        \\            yield x
        \\def generate_ints(n):
        \\    for i in range(n):
        \\        yield i * 2
        \\for i in generate_ints(5):
        \\    print i,
        \\print
        \\gen = generate_ints(3)
        \\print gen.next(),
        \\print gen.next(),
        \\print gen.next(),
        \\print gen.next()
        \\"
    ).expectEqual(output);
}

test "snapshot pycdc try/except/finally 2.6" {
    const allocator = testing.allocator;
    const output = try tu.renderPycFile(allocator, "refs/pycdc/tests/compiled/try_except_finally.2.6.pyc", false);
    defer allocator.free(output);

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]u8
        \\  "try:
        \\    try:
        \\        import sys
        \\        try:
        \\            print b'something else'
        \\        except AssertionError:
        \\            print b'...failed'
        \\    except ImportError:
        \\        print b'Oh Noes!'
        \\finally:
        \\    print 'Exiting'
        \\"
    ).expectEqual(output);
}

test "snapshot pycdc chain compare with 3.9" {
    const allocator = testing.allocator;
    const output = try tu.renderPycFile(allocator, "refs/pycdc/tests/compiled/chain_compare_with.3.9.pyc", false);
    defer allocator.free(output);

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]u8
        \\  "def full(self):
        \\    with self.mutex:
        \\        return 0 < self.maxsize <= self._qsize()
        \\"
    ).expectEqual(output);
}

test "snapshot pycdc with nested if 3.9" {
    const allocator = testing.allocator;
    const output = try tu.renderPycFile(allocator, "refs/pycdc/tests/compiled/with_nested_if.3.9.pyc", false);
    defer allocator.free(output);

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]u8
        \\  "def task_done(self):
        \\    with self.all_tasks_done:
        \\        unfinished = self.unfinished_tasks - 1
        \\        if unfinished <= 0:
        \\            if unfinished < 0:
        \\                raise ValueError('task_done() called too many times')
        \\            self.all_tasks_done.notify_all()
        \\        self.unfinished_tasks = unfinished
        \\"
    ).expectEqual(output);
}

test "snapshot pycdc guard raise loop 3.9" {
    const allocator = testing.allocator;
    const output = try tu.renderPycFile(allocator, "test/corpus/guard_raise_loop.3.9.pyc", false);
    defer allocator.free(output);

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]u8
        \\  "def wait(x):
        \\    pass
        \\def f(cond, endtime):
        \\    while cond:
        \\        remaining = endtime - time()
        \\        if remaining <= 0.0:
        \\            raise Exception('x')
        \\        wait(remaining)
        \\"
    ).expectEqual(output);
}

test "snapshot pycdc guard continue 3.9" {
    const allocator = testing.allocator;
    const output = try tu.renderPycFile(allocator, "test/corpus/if_guard_continue.3.9.pyc", false);
    defer allocator.free(output);

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]u8
        \\  "def f(func):
        \\    is_duck = False
        \\    if not isfunction(func):
        \\        if not _signature_is_functionlike(func):
        \\            raise TypeError('bad')
        \\        is_duck = True
        \\    x = 3
        \\    return (is_duck, x)
        \\"
    ).expectEqual(output);
}
