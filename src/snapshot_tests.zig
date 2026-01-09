//! Snapshot tests for comprehension, genexpr, and lambda output.

const std = @import("std");
const testing = std.testing;
const OhSnap = @import("ohsnap");

const opcodes = @import("opcodes.zig");
const decoder = @import("decoder.zig");
const pyc = @import("pyc.zig");
const stack = @import("stack.zig");
const codegen = @import("codegen.zig");
const decompile = @import("decompile.zig");

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

const OpArg = struct {
    op: Opcode,
    arg: u32,
};

fn emitOps(bytes: *std.ArrayList(u8), allocator: Allocator, version: Version, ops: []const OpArg) !void {
    for (ops) |item| {
        try emitOp(bytes, allocator, version, item.op, item.arg);
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
    const gen_ops = [_]OpArg{
        .{ .op = .RESUME, .arg = 0 },
        .{ .op = .LOAD_FAST, .arg = 0 },
        .{ .op = .FOR_ITER, .arg = 0 },
        .{ .op = .STORE_FAST_LOAD_FAST, .arg = 0x11 },
        .{ .op = .LOAD_FAST_BORROW, .arg = 1 },
        .{ .op = .YIELD_VALUE, .arg = 0 },
        .{ .op = .END_FOR, .arg = 0 },
        .{ .op = .POP_ITER, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
    };
    try emitOps(&gen_bytes, allocator, version, &gen_ops);

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
    const lambda_ops = [_]OpArg{
        .{ .op = .RESUME, .arg = 0 },
        .{ .op = .LOAD_FAST, .arg = 0 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
    };
    try emitOps(&lambda_bytes, allocator, version, &lambda_ops);

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

test "snapshot list unpack" {
    const allocator = testing.allocator;
    const version = Version.init(3, 10);

    const names = try dupeStrings(allocator, &[_][]const u8{ "a", "b" });
    defer {
        for (names) |v| allocator.free(v);
        allocator.free(names);
    }

    const name = try allocator.dupe(u8, "list_unpack");
    defer allocator.free(name);

    var code = pyc.Code{
        .allocator = allocator,
        .names = names,
        .name = name,
    };

    const insts = [_]Instruction{
        inst(.LOAD_NAME, 0),
        inst(.LOAD_NAME, 1),
        inst(.BUILD_LIST_UNPACK, 2),
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
        \\  "[*a, *b]
        \\"
    ).expectEqual(output);
}

test "snapshot call with keywords" {
    const allocator = testing.allocator;
    const version = Version.init(3, 10);

    const names = try dupeStrings(allocator, &[_][]const u8{"f"});
    defer {
        for (names) |v| allocator.free(v);
        allocator.free(names);
    }

    const name = try allocator.dupe(u8, "call_kw");
    defer allocator.free(name);

    var kw_items = [_]pyc.Object{
        .{ .string = "a" },
        .{ .string = "b" },
    };

    var consts = [_]pyc.Object{
        .{ .int = pyc.Int.fromI64(1) },
        .{ .int = pyc.Int.fromI64(2) },
        .{ .tuple = kw_items[0..] },
    };

    var code = pyc.Code{
        .allocator = allocator,
        .names = names,
        .consts = &consts,
        .name = name,
    };

    const insts = [_]Instruction{
        inst(.LOAD_NAME, 0),
        inst(.LOAD_CONST, 0),
        inst(.LOAD_CONST, 1),
        inst(.LOAD_CONST, 2),
        inst(.CALL_FUNCTION_KW, 2),
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
        \\  "f(a=1, b=2)
        \\"
    ).expectEqual(output);
}

test "snapshot call method" {
    const allocator = testing.allocator;
    const version = Version.init(3, 10);

    const names = try dupeStrings(allocator, &[_][]const u8{ "obj", "m" });
    defer {
        for (names) |v| allocator.free(v);
        allocator.free(names);
    }

    const name = try allocator.dupe(u8, "call_method");
    defer allocator.free(name);

    var code = pyc.Code{
        .allocator = allocator,
        .names = names,
        .name = name,
    };

    const insts = [_]Instruction{
        inst(.LOAD_NAME, 0),
        inst(.LOAD_METHOD, 1),
        inst(.CALL_METHOD, 0),
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
        \\  "obj.m()
        \\"
    ).expectEqual(output);
}

test "snapshot decorated function output" {
    const allocator = testing.allocator;
    const version = Version.init(3, 10);

    var func_bytes: std.ArrayList(u8) = .{};
    defer func_bytes.deinit(allocator);
    const func_ops = [_]OpArg{
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
    };
    try emitOps(&func_bytes, allocator, version, &func_ops);

    const func_consts = [_]pyc.Object{.none};
    const func_code = try allocCode(allocator, "foo", &[_][]const u8{}, &func_consts, func_bytes.items, 0);
    var func_code_owned = true;
    errdefer if (func_code_owned) {
        func_code.deinit();
        allocator.destroy(func_code);
    };

    var module = pyc.Code{
        .allocator = allocator,
    };
    defer module.deinit();

    module.name = try allocator.dupe(u8, "<module>");
    module.names = try dupeStrings(allocator, &[_][]const u8{ "decorator", "foo" });

    var module_bytes: std.ArrayList(u8) = .{};
    defer module_bytes.deinit(allocator);
    const module_ops = [_]OpArg{
        .{ .op = .LOAD_NAME, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 1 },
        .{ .op = .MAKE_FUNCTION, .arg = 0 },
        .{ .op = .CALL_FUNCTION, .arg = 1 },
        .{ .op = .STORE_NAME, .arg = 1 },
        .{ .op = .LOAD_CONST, .arg = 2 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
    };
    try emitOps(&module_bytes, allocator, version, &module_ops);

    module.code = try allocator.dupe(u8, module_bytes.items);

    const consts = try allocator.alloc(pyc.Object, 3);
    consts[0] = .none;
    consts[1] = .none;
    consts[2] = .none;
    module.consts = consts;

    const func_name_const = try allocator.dupe(u8, "foo");
    var func_name_owned = true;
    errdefer if (func_name_owned) allocator.free(func_name_const);

    module.consts[0] = .{ .code = func_code };
    module.consts[1] = .{ .string = func_name_const };
    module.consts[2] = .none;
    func_code_owned = false;
    func_name_owned = false;

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    try decompile.decompileToSource(allocator, &module, version, out.writer(allocator));
    const output: []const u8 = out.items;

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]const u8
        \\  "@decorator
        \\def foo():
        \\    pass
        \\"
    ).expectEqual(output);
}
