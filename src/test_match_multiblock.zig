//! Tests for multi-block pattern extraction in match statements.

const std = @import("std");
const testing = std.testing;
const OhSnap = @import("ohsnap");
const Allocator = std.mem.Allocator;

const cfg_mod = @import("cfg.zig");
const decompile = @import("decompile.zig");
const pyc = @import("pyc.zig");
const tu = @import("test_utils.zig");
const codegen = @import("codegen.zig");
const Version = @import("opcodes.zig").Version;
const decoder = @import("decoder.zig");
const Instruction = decoder.Instruction;
const ast = @import("ast.zig");

fn buildInsts(allocator: Allocator, ops: []const tu.OpArg) ![]Instruction {
    var result: std.ArrayList(Instruction) = .{};
    errdefer result.deinit(allocator);
    for (ops) |op_arg| {
        try result.append(allocator, tu.inst(op_arg.op, op_arg.arg));
    }
    return result.toOwnedSlice(allocator);
}

const JumpFix = struct {
    jump_idx: usize,
    target_idx: usize,
};

fn patchJumpArgs(allocator: Allocator, version: Version, bytecode: []u8, fixes: []const JumpFix) !void {
    var iter = decoder.InstructionIterator.init(bytecode, version);
    const insts = try iter.collectAlloc(allocator);
    defer allocator.free(insts);

    const multiplier: u32 = if (version.gte(3, 10)) 2 else 1;
    for (fixes) |fix| {
        const jump = insts[fix.jump_idx];
        const target_offset = insts[fix.target_idx].offset;
        const next_offset = jump.offset + jump.size;
        const arg: u32 = switch (jump.opcode) {
            .JUMP_FORWARD,
            .FOR_ITER,
            .SEND,
            => blk: {
                if (target_offset < next_offset) return error.InvalidJump;
                break :blk (target_offset - next_offset) / multiplier;
            },
            .POP_JUMP_IF_TRUE,
            .POP_JUMP_IF_FALSE,
            .POP_JUMP_IF_NONE,
            .POP_JUMP_IF_NOT_NONE,
            .POP_JUMP_FORWARD_IF_TRUE,
            .POP_JUMP_FORWARD_IF_FALSE,
            => blk: {
                if (version.gte(3, 11)) {
                    if (target_offset < next_offset) return error.InvalidJump;
                    break :blk (target_offset - next_offset) / multiplier;
                }
                break :blk target_offset / multiplier;
            },
            .JUMP_ABSOLUTE, .CONTINUE_LOOP => target_offset / multiplier,
            else => return error.InvalidJump,
        };
        if (arg > 0xFF) return error.InvalidJump;
        bytecode[jump.offset + 1] = @intCast(arg);
    }
}

test "match sequence pattern multiblock" {
    const allocator = testing.allocator;
    const version = Version.init(3, 14);

    const varnames = try tu.dupeStrings(allocator, &[_][]const u8{ "x", "y" });
    defer {
        for (varnames) |v| allocator.free(v);
        allocator.free(varnames);
    }

    const ops1 = [_]tu.OpArg{
        .{ .op = .LOAD_FAST, .arg = 0 },
        .{ .op = .MATCH_SEQUENCE, .arg = 0 },
        .{ .op = .POP_JUMP_IF_FALSE, .arg = 0 },
        .{ .op = .GET_LEN, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 1 },
        .{ .op = .COMPARE_OP, .arg = 2 },
        .{ .op = .POP_JUMP_IF_FALSE, .arg = 0 },
        .{ .op = .UNPACK_SEQUENCE, .arg = 1 },
        .{ .op = .STORE_FAST, .arg = 1 },
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
        .{ .op = .POP_TOP, .arg = 0 },
        .{ .op = .NOP, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
    };

    const insts = try buildInsts(allocator, &ops1);
    defer allocator.free(insts);

    const bytecode = try tu.emitOpsOwned(allocator, version, &ops1);
    defer allocator.free(bytecode);
    try patchJumpArgs(allocator, version, bytecode, &[_]JumpFix{
        .{ .jump_idx = 2, .target_idx = 11 },
        .{ .jump_idx = 6, .target_idx = 11 },
    });

    const name = try allocator.dupe(u8, "test_match");
    defer allocator.free(name);

    var code = pyc.Code{
        .allocator = allocator,
        .varnames = varnames,
        .name = name,
        .code = bytecode,
    };

    var d = try decompile.Decompiler.init(allocator, &code, version);
    defer d.deinit();

    const pat = try d.extractMatchPatternFromInsts(insts, false);

    var w = codegen.Writer.init(allocator);
    defer w.deinit(allocator);
    try w.writePattern(allocator, pat);
    const output = try w.getOutput(allocator);
    defer allocator.free(output);

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]const u8
        \\  "[y]"
    ).expectEqual(output);
}

test "match STORE_FAST_LOAD_FAST guard" {
    const allocator = testing.allocator;
    const version = Version.init(3, 14);

    const varnames = try tu.dupeStrings(allocator, &[_][]const u8{ "x", "y" });
    defer {
        for (varnames) |v| allocator.free(v);
        allocator.free(varnames);
    }

    const ops2 = [_]tu.OpArg{
        .{ .op = .LOAD_FAST, .arg = 0 },
        .{ .op = .MATCH_SEQUENCE, .arg = 0 },
        .{ .op = .POP_JUMP_IF_FALSE, .arg = 0 },
        .{ .op = .GET_LEN, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 1 },
        .{ .op = .COMPARE_OP, .arg = 2 },
        .{ .op = .POP_JUMP_IF_FALSE, .arg = 0 },
        .{ .op = .UNPACK_SEQUENCE, .arg = 1 },
        .{ .op = .STORE_FAST_LOAD_FAST, .arg = 0x11 },
        .{ .op = .TO_BOOL, .arg = 0 },
        .{ .op = .POP_JUMP_IF_FALSE, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
        .{ .op = .POP_TOP, .arg = 0 },
        .{ .op = .NOP, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
    };

    const insts = try buildInsts(allocator, &ops2);
    defer allocator.free(insts);

    const bytecode = try tu.emitOpsOwned(allocator, version, &ops2);
    defer allocator.free(bytecode);
    try patchJumpArgs(allocator, version, bytecode, &[_]JumpFix{
        .{ .jump_idx = 2, .target_idx = 13 },
        .{ .jump_idx = 6, .target_idx = 13 },
        .{ .jump_idx = 10, .target_idx = 14 },
    });

    const name = try allocator.dupe(u8, "test_guard");
    defer allocator.free(name);

    var code = pyc.Code{
        .allocator = allocator,
        .varnames = varnames,
        .name = name,
        .code = bytecode,
    };

    var d = try decompile.Decompiler.init(allocator, &code, version);
    defer d.deinit();

    const pat = try d.extractMatchPatternFromInsts(insts, false);

    var w = codegen.Writer.init(allocator);
    defer w.deinit(allocator);
    try w.writePattern(allocator, pat);
    const output = try w.getOutput(allocator);
    defer allocator.free(output);

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]const u8
        \\  "[y]"
    ).expectEqual(output);
}

test "match STORE_FAST_STORE_FAST two vars" {
    const allocator = testing.allocator;
    const version = Version.init(3, 14);

    const varnames = try tu.dupeStrings(allocator, &[_][]const u8{ "x", "a", "b" });
    defer {
        for (varnames) |v| allocator.free(v);
        allocator.free(varnames);
    }

    const ops3 = [_]tu.OpArg{
        .{ .op = .LOAD_FAST, .arg = 0 },
        .{ .op = .MATCH_SEQUENCE, .arg = 0 },
        .{ .op = .POP_JUMP_IF_FALSE, .arg = 0 },
        .{ .op = .GET_LEN, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 2 },
        .{ .op = .COMPARE_OP, .arg = 2 },
        .{ .op = .POP_JUMP_IF_FALSE, .arg = 0 },
        .{ .op = .UNPACK_SEQUENCE, .arg = 2 },
        .{ .op = .STORE_FAST_STORE_FAST, .arg = 0x12 },
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
        .{ .op = .POP_TOP, .arg = 0 },
        .{ .op = .NOP, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
    };

    const insts = try buildInsts(allocator, &ops3);
    defer allocator.free(insts);

    const bytecode = try tu.emitOpsOwned(allocator, version, &ops3);
    defer allocator.free(bytecode);
    try patchJumpArgs(allocator, version, bytecode, &[_]JumpFix{
        .{ .jump_idx = 2, .target_idx = 11 },
        .{ .jump_idx = 6, .target_idx = 11 },
    });

    const name = try allocator.dupe(u8, "test_two");
    defer allocator.free(name);

    var code = pyc.Code{
        .allocator = allocator,
        .varnames = varnames,
        .name = name,
        .code = bytecode,
    };

    var d = try decompile.Decompiler.init(allocator, &code, version);
    defer d.deinit();

    const pat = try d.extractMatchPatternFromInsts(insts, false);

    var w = codegen.Writer.init(allocator);
    defer w.deinit(allocator);
    try w.writePattern(allocator, pat);
    const output = try w.getOutput(allocator);
    defer allocator.free(output);

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]const u8
        \\  "[a, b]"
    ).expectEqual(output);
}

test "match nested sequence with swap" {
    const allocator = testing.allocator;
    const version = Version.init(3, 14);

    const varnames = try tu.dupeStrings(allocator, &[_][]const u8{ "x", "a", "b", "c" });
    defer {
        for (varnames) |v| allocator.free(v);
        allocator.free(varnames);
    }

    const ops = [_]tu.OpArg{
        .{ .op = .LOAD_FAST, .arg = 0 },
        .{ .op = .MATCH_SEQUENCE, .arg = 0 },
        .{ .op = .POP_JUMP_IF_FALSE, .arg = 0 },
        .{ .op = .GET_LEN, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 2 },
        .{ .op = .COMPARE_OP, .arg = 2 },
        .{ .op = .POP_JUMP_IF_FALSE, .arg = 0 },
        .{ .op = .UNPACK_SEQUENCE, .arg = 2 },
        .{ .op = .SWAP, .arg = 2 },
        .{ .op = .MATCH_SEQUENCE, .arg = 0 },
        .{ .op = .POP_JUMP_IF_FALSE, .arg = 0 },
        .{ .op = .GET_LEN, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 2 },
        .{ .op = .COMPARE_OP, .arg = 2 },
        .{ .op = .POP_JUMP_IF_FALSE, .arg = 0 },
        .{ .op = .UNPACK_SEQUENCE, .arg = 2 },
        .{ .op = .STORE_FAST_STORE_FAST, .arg = 0x23 },
        .{ .op = .STORE_FAST, .arg = 1 },
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
        .{ .op = .POP_TOP, .arg = 0 },
        .{ .op = .POP_TOP, .arg = 0 },
        .{ .op = .NOP, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
    };

    const insts = try buildInsts(allocator, &ops);
    defer allocator.free(insts);

    const bytecode = try tu.emitOpsOwned(allocator, version, &ops);
    defer allocator.free(bytecode);
    try patchJumpArgs(allocator, version, bytecode, &[_]JumpFix{
        .{ .jump_idx = 2, .target_idx = 21 },
        .{ .jump_idx = 6, .target_idx = 21 },
        .{ .jump_idx = 10, .target_idx = 20 },
        .{ .jump_idx = 14, .target_idx = 20 },
    });

    const name = try allocator.dupe(u8, "test_nested");
    defer allocator.free(name);

    var code = pyc.Code{
        .allocator = allocator,
        .varnames = varnames,
        .name = name,
        .code = bytecode,
    };

    var d = try decompile.Decompiler.init(allocator, &code, version);
    defer d.deinit();

    const pat = try d.extractMatchPatternFromInsts(insts, false);

    var w = codegen.Writer.init(allocator);
    defer w.deinit(allocator);
    try w.writePattern(allocator, pat);
    const output = try w.getOutput(allocator);
    defer allocator.free(output);

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]const u8
        \\  "[a, [b, c]]"
    ).expectEqual(output);
}
