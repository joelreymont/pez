//! Snapshot tests for comprehension, genexpr, and lambda output.

const std = @import("std");
const testing = std.testing;
const OhSnap = @import("ohsnap");

const opcodes = @import("opcodes.zig");
const decoder = @import("decoder.zig");
const pyc = @import("pyc.zig");
const stack = @import("stack.zig");
const codegen = @import("codegen.zig");

const Allocator = std.mem.Allocator;
const Version = opcodes.Version;
const Opcode = opcodes.Opcode;
const Instruction = decoder.Instruction;

fn inst(op: Opcode, arg: u32) Instruction {
    return .{
        .opcode = op,
        .arg = arg,
        .offset = 0,
        .size = 2,
        .cache_entries = 0,
    };
}

fn renderExpr(allocator: Allocator, expr: *const stack.Expr) ![]const u8 {
    var writer = codegen.Writer.init(allocator);
    defer writer.deinit(allocator);
    try writer.writeExpr(allocator, expr);
    return writer.getOutput(allocator);
}

fn renderExprWithNewline(allocator: Allocator, expr: *const stack.Expr) ![]const u8 {
    const output = try renderExpr(allocator, expr);
    defer allocator.free(output);
    return std.mem.concat(allocator, u8, &[_][]const u8{ output, "\n" });
}

fn dupeStrings(allocator: Allocator, items: []const []const u8) ![][]const u8 {
    const out = try allocator.alloc([]const u8, items.len);
    var count: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            allocator.free(out[i]);
        }
        allocator.free(out);
    }

    for (items, 0..) |item, i| {
        out[i] = try allocator.dupe(u8, item);
        count += 1;
    }
    return out;
}

fn simulateExpr(allocator: Allocator, code: *pyc.Code, version: Version, insts: []const Instruction) !*stack.Expr {
    var sim = stack.SimContext.init(allocator, code, version);
    defer sim.deinit();

    for (insts) |item| {
        try sim.simulate(item);
    }
    return sim.stack.popExpr();
}

fn opcodeByte(version: Version, op: Opcode) u8 {
    const table = opcodes.getOpcodeTable(version);
    for (table, 0..) |entry, idx| {
        if (entry == op) return @intCast(idx);
    }
    @panic("opcode not in table");
}

fn emitOp(bytes: *std.ArrayList(u8), allocator: Allocator, version: Version, op: Opcode, arg: u32) !void {
    try bytes.append(allocator, opcodeByte(version, op));
    try bytes.append(allocator, @intCast(arg & 0xFF));

    const cache_entries = opcodes.cacheEntries(op, version);
    if (cache_entries > 0) {
        const cache_bytes = @as(usize, cache_entries) * 2;
        try bytes.appendNTimes(allocator, 0, cache_bytes);
    }
}

fn allocCode(
    allocator: Allocator,
    name: []const u8,
    varnames_in: []const []const u8,
    consts_in: []const pyc.Object,
    bytecode: []const u8,
    argcount: u32,
) !*pyc.Code {
    const code = try allocator.create(pyc.Code);
    errdefer allocator.destroy(code);

    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);

    const varnames = try dupeStrings(allocator, varnames_in);
    errdefer {
        for (varnames) |v| allocator.free(v);
        allocator.free(varnames);
    }

    const consts = try allocator.alloc(pyc.Object, consts_in.len);
    errdefer allocator.free(consts);
    for (consts_in, 0..) |obj, idx| {
        consts[idx] = obj;
    }

    const code_bytes = try allocator.dupe(u8, bytecode);
    errdefer allocator.free(code_bytes);

    code.* = .{
        .allocator = allocator,
        .argcount = argcount,
        .nlocals = @intCast(varnames_in.len),
        .code = code_bytes,
        .consts = consts,
        .varnames = varnames,
        .name = name_copy,
    };
    return code;
}

test "snapshot list comprehension" {
    const allocator = testing.allocator;
    const version = Version.init(3, 14);

    const varnames = try dupeStrings(allocator, &[_][]const u8{ "b", "y" });
    defer {
        for (varnames) |v| allocator.free(v);
        allocator.free(varnames);
    }

    const name = try allocator.dupe(u8, "listcomp");
    defer allocator.free(name);

    var code = pyc.Code{
        .allocator = allocator,
        .varnames = varnames,
        .name = name,
    };

    const insts = [_]Instruction{
        inst(.LOAD_FAST_BORROW, 0),
        inst(.GET_ITER, 0),
        inst(.LOAD_FAST_AND_CLEAR, 1),
        inst(.SWAP, 2),
        inst(.BUILD_LIST, 0),
        inst(.SWAP, 2),
        inst(.FOR_ITER, 0),
        inst(.STORE_FAST_LOAD_FAST, 0x11),
        inst(.LIST_APPEND, 2),
        inst(.END_FOR, 0),
        inst(.POP_ITER, 0),
        inst(.SWAP, 2),
        inst(.STORE_FAST, 1),
    };

    const expr = try simulateExpr(allocator, &code, version, &insts);
    defer {
        expr.deinit(allocator);
        allocator.destroy(expr);
    }

    const output = try renderExprWithNewline(allocator, expr);
    defer allocator.free(output);

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]const u8
        \\  "[y for y in b]
        \\"
    ).expectEqual(output);
}

test "snapshot list comprehension with if" {
    const allocator = testing.allocator;
    const version = Version.init(3, 14);

    const varnames = try dupeStrings(allocator, &[_][]const u8{ "b", "y" });
    defer {
        for (varnames) |v| allocator.free(v);
        allocator.free(varnames);
    }

    const name = try allocator.dupe(u8, "listcomp_if");
    defer allocator.free(name);

    var code = pyc.Code{
        .allocator = allocator,
        .varnames = varnames,
        .name = name,
    };

    const insts = [_]Instruction{
        inst(.LOAD_FAST_BORROW, 0),
        inst(.GET_ITER, 0),
        inst(.LOAD_FAST_AND_CLEAR, 1),
        inst(.SWAP, 2),
        inst(.BUILD_LIST, 0),
        inst(.SWAP, 2),
        inst(.FOR_ITER, 0),
        inst(.STORE_FAST_LOAD_FAST, 0x11),
        inst(.TO_BOOL, 0),
        inst(.POP_JUMP_IF_TRUE, 0),
        inst(.LOAD_FAST_BORROW, 1),
        inst(.LIST_APPEND, 2),
        inst(.END_FOR, 0),
        inst(.POP_ITER, 0),
        inst(.SWAP, 2),
        inst(.STORE_FAST, 1),
    };

    const expr = try simulateExpr(allocator, &code, version, &insts);
    defer {
        expr.deinit(allocator);
        allocator.destroy(expr);
    }

    const output = try renderExprWithNewline(allocator, expr);
    defer allocator.free(output);

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]const u8
        \\  "[y for y in b if y]
        \\"
    ).expectEqual(output);
}

test "snapshot list comprehension with is None" {
    const allocator = testing.allocator;
    const version = Version.init(3, 14);

    const varnames = try dupeStrings(allocator, &[_][]const u8{ "b", "y" });
    defer {
        for (varnames) |v| allocator.free(v);
        allocator.free(varnames);
    }

    const name = try allocator.dupe(u8, "listcomp_none");
    defer allocator.free(name);

    var code = pyc.Code{
        .allocator = allocator,
        .varnames = varnames,
        .name = name,
    };

    const insts = [_]Instruction{
        inst(.LOAD_FAST_BORROW, 0),
        inst(.GET_ITER, 0),
        inst(.LOAD_FAST_AND_CLEAR, 1),
        inst(.SWAP, 2),
        inst(.BUILD_LIST, 0),
        inst(.SWAP, 2),
        inst(.FOR_ITER, 0),
        inst(.STORE_FAST_LOAD_FAST, 0x11),
        inst(.POP_JUMP_IF_NONE, 0),
        inst(.LOAD_FAST_BORROW, 1),
        inst(.LIST_APPEND, 2),
        inst(.END_FOR, 0),
        inst(.POP_ITER, 0),
        inst(.SWAP, 2),
        inst(.STORE_FAST, 1),
    };

    const expr = try simulateExpr(allocator, &code, version, &insts);
    defer {
        expr.deinit(allocator);
        allocator.destroy(expr);
    }

    const output = try renderExprWithNewline(allocator, expr);
    defer allocator.free(output);

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]const u8
        \\  "[y for y in b if y is None]
        \\"
    ).expectEqual(output);
}

test "snapshot set comprehension" {
    const allocator = testing.allocator;
    const version = Version.init(3, 14);

    const varnames = try dupeStrings(allocator, &[_][]const u8{ "b", "y" });
    defer {
        for (varnames) |v| allocator.free(v);
        allocator.free(varnames);
    }

    const name = try allocator.dupe(u8, "setcomp");
    defer allocator.free(name);

    var code = pyc.Code{
        .allocator = allocator,
        .varnames = varnames,
        .name = name,
    };

    const insts = [_]Instruction{
        inst(.LOAD_FAST_BORROW, 0),
        inst(.GET_ITER, 0),
        inst(.LOAD_FAST_AND_CLEAR, 1),
        inst(.SWAP, 2),
        inst(.BUILD_SET, 0),
        inst(.SWAP, 2),
        inst(.FOR_ITER, 0),
        inst(.STORE_FAST_LOAD_FAST, 0x11),
        inst(.SET_ADD, 2),
        inst(.END_FOR, 0),
        inst(.POP_ITER, 0),
        inst(.SWAP, 2),
        inst(.STORE_FAST, 1),
    };

    const expr = try simulateExpr(allocator, &code, version, &insts);
    defer {
        expr.deinit(allocator);
        allocator.destroy(expr);
    }

    const output = try renderExprWithNewline(allocator, expr);
    defer allocator.free(output);

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]const u8
        \\  "{y for y in b}
        \\"
    ).expectEqual(output);
}

test "snapshot dict comprehension" {
    const allocator = testing.allocator;
    const version = Version.init(3, 14);

    const varnames = try dupeStrings(allocator, &[_][]const u8{ "b", "y" });
    defer {
        for (varnames) |v| allocator.free(v);
        allocator.free(varnames);
    }

    const name = try allocator.dupe(u8, "dictcomp");
    defer allocator.free(name);

    var code = pyc.Code{
        .allocator = allocator,
        .varnames = varnames,
        .name = name,
    };

    const insts = [_]Instruction{
        inst(.LOAD_FAST_BORROW, 0),
        inst(.GET_ITER, 0),
        inst(.LOAD_FAST_AND_CLEAR, 1),
        inst(.SWAP, 2),
        inst(.BUILD_MAP, 0),
        inst(.SWAP, 2),
        inst(.FOR_ITER, 0),
        inst(.STORE_FAST_LOAD_FAST, 0x11),
        inst(.LOAD_FAST_BORROW, 1),
        inst(.MAP_ADD, 2),
        inst(.END_FOR, 0),
        inst(.POP_ITER, 0),
        inst(.SWAP, 2),
        inst(.STORE_FAST, 1),
    };

    const expr = try simulateExpr(allocator, &code, version, &insts);
    defer {
        expr.deinit(allocator);
        allocator.destroy(expr);
    }

    const output = try renderExprWithNewline(allocator, expr);
    defer allocator.free(output);

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]const u8
        \\  "{y: y for y in b}
        \\"
    ).expectEqual(output);
}

test "snapshot generator expression" {
    const allocator = testing.allocator;
    const version = Version.init(3, 14);

    var gen_bytes: std.ArrayList(u8) = .{};
    defer gen_bytes.deinit(allocator);

    try emitOp(&gen_bytes, allocator, version, .RESUME, 0);
    try emitOp(&gen_bytes, allocator, version, .LOAD_FAST, 0);
    try emitOp(&gen_bytes, allocator, version, .FOR_ITER, 0);
    try emitOp(&gen_bytes, allocator, version, .STORE_FAST_LOAD_FAST, 0x11);
    try emitOp(&gen_bytes, allocator, version, .LOAD_FAST_BORROW, 1);
    try emitOp(&gen_bytes, allocator, version, .YIELD_VALUE, 0);
    try emitOp(&gen_bytes, allocator, version, .END_FOR, 0);
    try emitOp(&gen_bytes, allocator, version, .POP_ITER, 0);
    try emitOp(&gen_bytes, allocator, version, .LOAD_CONST, 0);
    try emitOp(&gen_bytes, allocator, version, .RETURN_VALUE, 0);

    const gen_consts = [_]pyc.Object{.none};
    const gen_code = try allocCode(
        allocator,
        "<genexpr>",
        &[_][]const u8{ ".0", "y" },
        &gen_consts,
        gen_bytes.items,
        1,
    );

    const outer_consts = try allocator.alloc(pyc.Object, 1);
    outer_consts[0] = .{ .code = gen_code };

    const varnames = try dupeStrings(allocator, &[_][]const u8{"b"});
    const name = try allocator.dupe(u8, "genexpr_outer");

    var outer_code = pyc.Code{
        .allocator = allocator,
        .varnames = varnames,
        .consts = outer_consts,
        .name = name,
    };
    defer outer_code.deinit();

    const insts = [_]Instruction{
        inst(.LOAD_CONST, 0),
        inst(.MAKE_FUNCTION, 0),
        inst(.LOAD_FAST_BORROW, 0),
        inst(.GET_ITER, 0),
        inst(.CALL, 0),
    };

    const expr = try simulateExpr(allocator, &outer_code, version, &insts);
    defer {
        expr.deinit(allocator);
        allocator.destroy(expr);
    }

    const output = try renderExprWithNewline(allocator, expr);
    defer allocator.free(output);

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]const u8
        \\  "(y for y in b)
        \\"
    ).expectEqual(output);
}

test "snapshot lambda expression" {
    const allocator = testing.allocator;
    const version = Version.init(3, 14);

    var lambda_bytes: std.ArrayList(u8) = .{};
    defer lambda_bytes.deinit(allocator);

    try emitOp(&lambda_bytes, allocator, version, .RESUME, 0);
    try emitOp(&lambda_bytes, allocator, version, .LOAD_FAST, 0);
    try emitOp(&lambda_bytes, allocator, version, .RETURN_VALUE, 0);

    const lambda_consts = [_]pyc.Object{};
    const lambda_code = try allocCode(
        allocator,
        "<lambda>",
        &[_][]const u8{"x"},
        &lambda_consts,
        lambda_bytes.items,
        1,
    );

    const outer_consts = try allocator.alloc(pyc.Object, 1);
    outer_consts[0] = .{ .code = lambda_code };

    const name = try allocator.dupe(u8, "lambda_outer");

    var outer_code = pyc.Code{
        .allocator = allocator,
        .consts = outer_consts,
        .name = name,
    };
    defer outer_code.deinit();

    const insts = [_]Instruction{
        inst(.LOAD_CONST, 0),
        inst(.MAKE_FUNCTION, 0),
    };

    const expr = try simulateExpr(allocator, &outer_code, version, &insts);
    defer {
        expr.deinit(allocator);
        allocator.destroy(expr);
    }

    const output = try renderExprWithNewline(allocator, expr);
    defer allocator.free(output);

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]const u8
        \\  "lambda x: x
        \\"
    ).expectEqual(output);
}
