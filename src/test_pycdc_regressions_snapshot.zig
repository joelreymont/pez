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
