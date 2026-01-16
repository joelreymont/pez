const std = @import("std");
const testing = std.testing;

const opcodes = @import("opcodes.zig");
const decoder = @import("decoder.zig");
const cfg_mod = @import("cfg.zig");
const pyc = @import("pyc.zig");
const decompile = @import("decompile.zig");
const tu = @import("test_utils.zig");

const Version = opcodes.Version;
const OpArg = tu.OpArg;

test "stack flow handles deep jump chain" {
    const allocator = testing.allocator;
    const version = Version.init(3, 14);

    const varnames = &[_][]const u8{"x"};
    const consts = &[_]pyc.Object{.{ .int = pyc.Int.fromI64(1) }};

    const jump_count: usize = 17;
    const total = 1 + jump_count + 3;
    var ops: [total]OpArg = undefined;
    var idx: usize = 0;

    ops[idx] = .{ .op = .LOAD_CONST, .arg = 0 };
    idx += 1;

    for (0..jump_count) |_| {
        ops[idx] = .{ .op = .JUMP_FORWARD, .arg = 0 };
        idx += 1;
    }

    ops[idx] = .{ .op = .STORE_FAST, .arg = 0 };
    idx += 1;
    ops[idx] = .{ .op = .LOAD_FAST, .arg = 0 };
    idx += 1;
    ops[idx] = .{ .op = .RETURN_VALUE, .arg = 0 };

    const bytecode = try tu.emitOpsOwned(allocator, version, &ops);
    var code = try tu.allocCode(allocator, "stack_flow", varnames, consts, bytecode, 0);
    defer {
        code.deinit();
        allocator.destroy(code);
    }

    var cfg = try cfg_mod.buildCFG(allocator, code.code, version);
    defer cfg.deinit();

    var iter = decoder.InstructionIterator.init(code.code, version);
    const insts = try iter.collectAlloc(allocator);
    defer allocator.free(insts);

    var store_off: ?u32 = null;
    for (insts) |inst| {
        if (inst.opcode == .STORE_FAST) {
            store_off = inst.offset;
            break;
        }
    }
    try testing.expect(store_off != null);

    const block_id = cfg.blockAtOffset(store_off.?) orelse return error.InvalidBlock;

    const depths = try decompile.computeStackDepthsForTest(allocator, code, version);
    defer allocator.free(depths);

    try testing.expectEqual(@as(?usize, 1), depths[block_id]);
}
