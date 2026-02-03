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
const tu = @import("test_utils.zig");

const Allocator = std.mem.Allocator;
const Version = opcodes.Version;
const Opcode = opcodes.Opcode;
const Instruction = decoder.Instruction;
const OpArg = tu.OpArg;

test "snapshot list comprehension" {
    const allocator = testing.allocator;
    const version = Version.init(3, 14);

    const varnames = try tu.dupeStrings(allocator, &[_][]const u8{ "b", "y" });
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
        tu.inst(.LOAD_FAST_BORROW, 0),
        tu.inst(.GET_ITER, 0),
        tu.inst(.LOAD_FAST_AND_CLEAR, 1),
        tu.inst(.SWAP, 2),
        tu.inst(.BUILD_LIST, 0),
        tu.inst(.SWAP, 2),
        tu.inst(.FOR_ITER, 0),
        tu.inst(.STORE_FAST_LOAD_FAST, 0x11),
        tu.inst(.LIST_APPEND, 2),
        tu.inst(.END_FOR, 0),
        tu.inst(.POP_ITER, 0),
        tu.inst(.SWAP, 2),
        tu.inst(.STORE_FAST, 1),
    };

    var sim = try tu.simulateExpr(allocator, &code, version, &insts);
    defer sim.arena.deinit();
    const expr = sim.expr;

    const output = try tu.renderExprWithNewline(allocator, expr);
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

    const varnames = try tu.dupeStrings(allocator, &[_][]const u8{ "b", "y" });
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
        tu.inst(.LOAD_FAST_BORROW, 0),
        tu.inst(.GET_ITER, 0),
        tu.inst(.LOAD_FAST_AND_CLEAR, 1),
        tu.inst(.SWAP, 2),
        tu.inst(.BUILD_LIST, 0),
        tu.inst(.SWAP, 2),
        tu.inst(.FOR_ITER, 0),
        tu.inst(.STORE_FAST_LOAD_FAST, 0x11),
        tu.inst(.TO_BOOL, 0),
        tu.inst(.POP_JUMP_IF_FALSE, 0),
        tu.inst(.LOAD_FAST_BORROW, 1),
        tu.inst(.LIST_APPEND, 2),
        tu.inst(.END_FOR, 0),
        tu.inst(.POP_ITER, 0),
        tu.inst(.SWAP, 2),
        tu.inst(.STORE_FAST, 1),
    };

    var sim = try tu.simulateExpr(allocator, &code, version, &insts);
    defer sim.arena.deinit();
    const expr = sim.expr;

    const output = try tu.renderExprWithNewline(allocator, expr);
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

    const varnames = try tu.dupeStrings(allocator, &[_][]const u8{ "b", "y" });
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
        tu.inst(.LOAD_FAST_BORROW, 0),
        tu.inst(.GET_ITER, 0),
        tu.inst(.LOAD_FAST_AND_CLEAR, 1),
        tu.inst(.SWAP, 2),
        tu.inst(.BUILD_LIST, 0),
        tu.inst(.SWAP, 2),
        tu.inst(.FOR_ITER, 0),
        tu.inst(.STORE_FAST_LOAD_FAST, 0x11),
        tu.inst(.POP_JUMP_IF_NOT_NONE, 0),
        tu.inst(.LOAD_FAST_BORROW, 1),
        tu.inst(.LIST_APPEND, 2),
        tu.inst(.END_FOR, 0),
        tu.inst(.POP_ITER, 0),
        tu.inst(.SWAP, 2),
        tu.inst(.STORE_FAST, 1),
    };

    var sim = try tu.simulateExpr(allocator, &code, version, &insts);
    defer sim.arena.deinit();
    const expr = sim.expr;

    const output = try tu.renderExprWithNewline(allocator, expr);
    defer allocator.free(output);

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]const u8
        \\  "[y for y in b if y is None]
        \\"
    ).expectEqual(output);
}

test "snapshot inline list comprehension py2" {
    const allocator = testing.allocator;
    const version = Version.init(2, 7);

    const loop_head_offset: u32 = 7;
    const loop_exit_offset: u32 = 22;
    const for_next_offset: u32 = 10;
    const for_delta: u32 = loop_exit_offset - for_next_offset;

    const ops = [_]OpArg{
        .{ .op = .BUILD_LIST, .arg = 0 },
        .{ .op = .LOAD_NAME, .arg = 0 },
        .{ .op = .GET_ITER, .arg = 0 },
        .{ .op = .FOR_ITER, .arg = for_delta },
        .{ .op = .STORE_NAME, .arg = 1 },
        .{ .op = .LOAD_NAME, .arg = 1 },
        .{ .op = .LIST_APPEND, .arg = 2 },
        .{ .op = .JUMP_ABSOLUTE, .arg = loop_head_offset },
        .{ .op = .PRINT_ITEM, .arg = 0 },
        .{ .op = .PRINT_NEWLINE, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
    };

    const bytecode = try tu.emitOpsOwned(allocator, version, &ops);
    const consts = [_]pyc.Object{.none};

    const code = try tu.allocCodeWithNames(
        allocator,
        "<module>",
        &.{},
        &[_][]const u8{ "XXX", "i" },
        &consts,
        bytecode,
        0,
    );
    defer {
        code.deinit();
        allocator.destroy(code);
    }

    const output = try tu.renderModule(allocator, code, version);
    defer allocator.free(output);

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]const u8
        \\  "print [i for i in XXX]
        \\"
    ).expectEqual(output);
}

test "snapshot set comprehension" {
    const allocator = testing.allocator;
    const version = Version.init(3, 14);

    const varnames = try tu.dupeStrings(allocator, &[_][]const u8{ "b", "y" });
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
        tu.inst(.LOAD_FAST_BORROW, 0),
        tu.inst(.GET_ITER, 0),
        tu.inst(.LOAD_FAST_AND_CLEAR, 1),
        tu.inst(.SWAP, 2),
        tu.inst(.BUILD_SET, 0),
        tu.inst(.SWAP, 2),
        tu.inst(.FOR_ITER, 0),
        tu.inst(.STORE_FAST_LOAD_FAST, 0x11),
        tu.inst(.SET_ADD, 2),
        tu.inst(.END_FOR, 0),
        tu.inst(.POP_ITER, 0),
        tu.inst(.SWAP, 2),
        tu.inst(.STORE_FAST, 1),
    };

    var sim = try tu.simulateExpr(allocator, &code, version, &insts);
    defer sim.arena.deinit();
    const expr = sim.expr;

    const output = try tu.renderExprWithNewline(allocator, expr);
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

    const varnames = try tu.dupeStrings(allocator, &[_][]const u8{ "b", "y" });
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
        tu.inst(.LOAD_FAST_BORROW, 0),
        tu.inst(.GET_ITER, 0),
        tu.inst(.LOAD_FAST_AND_CLEAR, 1),
        tu.inst(.SWAP, 2),
        tu.inst(.BUILD_MAP, 0),
        tu.inst(.SWAP, 2),
        tu.inst(.FOR_ITER, 0),
        tu.inst(.STORE_FAST_LOAD_FAST, 0x11),
        tu.inst(.LOAD_FAST_BORROW, 1),
        tu.inst(.MAP_ADD, 2),
        tu.inst(.END_FOR, 0),
        tu.inst(.POP_ITER, 0),
        tu.inst(.SWAP, 2),
        tu.inst(.STORE_FAST, 1),
    };

    var sim = try tu.simulateExpr(allocator, &code, version, &insts);
    defer sim.arena.deinit();
    const expr = sim.expr;

    const output = try tu.renderExprWithNewline(allocator, expr);
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

    const gen_consts = [_]pyc.Object{.none};
    const gen_code = try tu.allocCodeFromOps(
        allocator,
        version,
        "<genexpr>",
        &[_][]const u8{ ".0", "y" },
        &gen_consts,
        &gen_ops,
        1,
    );

    const outer_consts = try allocator.alloc(pyc.Object, 1);
    outer_consts[0] = .{ .code = gen_code };

    const varnames = try tu.dupeStrings(allocator, &[_][]const u8{"b"});
    const name = try allocator.dupe(u8, "genexpr_outer");

    var outer_code = pyc.Code{
        .allocator = allocator,
        .varnames = varnames,
        .consts = outer_consts,
        .name = name,
    };
    defer outer_code.deinit();

    const insts = [_]Instruction{
        tu.inst(.LOAD_CONST, 0),
        tu.inst(.MAKE_FUNCTION, 0),
        tu.inst(.LOAD_FAST_BORROW, 0),
        tu.inst(.GET_ITER, 0),
        tu.inst(.CALL, 0),
    };

    var sim = try tu.simulateExpr(allocator, &outer_code, version, &insts);
    defer sim.arena.deinit();
    const expr = sim.expr;

    const output = try tu.renderExprWithNewline(allocator, expr);
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

    const lambda_ops = [_]OpArg{
        .{ .op = .RESUME, .arg = 0 },
        .{ .op = .LOAD_FAST, .arg = 0 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
    };

    const lambda_consts = [_]pyc.Object{};
    const lambda_code = try tu.allocCodeFromOps(
        allocator,
        version,
        "<lambda>",
        &[_][]const u8{"x"},
        &lambda_consts,
        &lambda_ops,
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
        tu.inst(.LOAD_CONST, 0),
        tu.inst(.MAKE_FUNCTION, 0),
    };

    var sim = try tu.simulateExpr(allocator, &outer_code, version, &insts);
    defer sim.arena.deinit();
    const expr = sim.expr;

    const output = try tu.renderExprWithNewline(allocator, expr);
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

    const names = try tu.dupeStrings(allocator, &[_][]const u8{ "a", "b" });
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
        tu.inst(.LOAD_NAME, 0),
        tu.inst(.LOAD_NAME, 1),
        tu.inst(.BUILD_LIST_UNPACK, 2),
    };

    var sim = try tu.simulateExpr(allocator, &code, version, &insts);
    defer sim.arena.deinit();
    const expr = sim.expr;

    const output = try tu.renderExprWithNewline(allocator, expr);
    defer allocator.free(output);

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]const u8
        \\  "[*a, *b]
        \\"
    ).expectEqual(output);
}

test "snapshot list extend const tuple" {
    const allocator = testing.allocator;
    const version = Version.init(3, 10);

    const name = try allocator.dupe(u8, "list_extend_const_tuple");
    defer allocator.free(name);

    var tuple_items = [_]pyc.Object{
        .{ .int = pyc.Int.fromI64(1) },
        .{ .int = pyc.Int.fromI64(2) },
    };
    var consts = [_]pyc.Object{
        .{ .tuple = tuple_items[0..] },
    };

    var code = pyc.Code{
        .allocator = allocator,
        .consts = &consts,
        .name = name,
    };

    const insts = [_]Instruction{
        tu.inst(.BUILD_LIST, 0),
        tu.inst(.LOAD_CONST, 0),
        tu.inst(.LIST_EXTEND, 1),
    };

    var sim = try tu.simulateExpr(allocator, &code, version, &insts);
    defer sim.arena.deinit();
    const expr = sim.expr;

    const output = try tu.renderExprWithNewline(allocator, expr);
    defer allocator.free(output);

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]const u8
        \\  "[1, 2]
        \\"
    ).expectEqual(output);
}

test "snapshot call with keywords" {
    const allocator = testing.allocator;
    const version = Version.init(3, 10);

    const names = try tu.dupeStrings(allocator, &[_][]const u8{"f"});
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
        tu.inst(.LOAD_NAME, 0),
        tu.inst(.LOAD_CONST, 0),
        tu.inst(.LOAD_CONST, 1),
        tu.inst(.LOAD_CONST, 2),
        tu.inst(.CALL_FUNCTION_KW, 2),
    };

    var sim = try tu.simulateExpr(allocator, &code, version, &insts);
    defer sim.arena.deinit();
    const expr = sim.expr;

    const output = try tu.renderExprWithNewline(allocator, expr);
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

    const names = try tu.dupeStrings(allocator, &[_][]const u8{ "obj", "m" });
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
        tu.inst(.LOAD_NAME, 0),
        tu.inst(.LOAD_METHOD, 1),
        tu.inst(.CALL_METHOD, 0),
    };

    var sim = try tu.simulateExpr(allocator, &code, version, &insts);
    defer sim.arena.deinit();
    const expr = sim.expr;

    const output = try tu.renderExprWithNewline(allocator, expr);
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

    const func_ops = [_]OpArg{
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
    };

    const func_consts = [_]pyc.Object{.none};
    const func_code = try tu.allocCodeFromOps(
        allocator,
        version,
        "foo",
        &[_][]const u8{},
        &func_consts,
        &func_ops,
        0,
    );

    var module = pyc.Code{
        .allocator = allocator,
    };
    defer module.deinit();

    module.name = try allocator.dupe(u8, "<module>");
    module.names = try tu.dupeStrings(allocator, &[_][]const u8{ "decorator", "foo" });

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
    module.code = try tu.emitOpsOwned(allocator, version, &module_ops);

    const consts = try allocator.alloc(pyc.Object, 3);
    consts[0] = .none;
    consts[1] = .none;
    consts[2] = .none;
    module.consts = consts;

    module.consts[0] = .{ .code = func_code };
    module.consts[1] = .{ .string = try allocator.dupe(u8, "foo") };
    module.consts[2] = .none;

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

test "snapshot ternary expression output" {
    const allocator = testing.allocator;
    const version = Version.init(3, 10);

    var module = pyc.Code{
        .allocator = allocator,
    };
    defer module.deinit();

    module.name = try allocator.dupe(u8, "<module>");
    module.names = try tu.dupeStrings(allocator, &[_][]const u8{ "a", "x" });

    const consts = try allocator.alloc(pyc.Object, 3);
    consts[0] = .{ .int = pyc.Int.fromI64(1) };
    consts[1] = .{ .int = pyc.Int.fromI64(2) };
    consts[2] = .none;
    module.consts = consts;

    // Ternary: x = 1 if a else 2
    // For Python 3.10, jump args are instruction offsets (multiplied by 2 for byte offset)
    // Offset 0: LOAD_NAME a
    // Offset 2: POP_JUMP_IF_FALSE 4 (jump to instruction 4 = byte offset 8)
    // Offset 4: LOAD_CONST 1 (true value)
    // Offset 6: JUMP_FORWARD 1 (jump forward 1 instruction = to byte offset 10)
    // Offset 8: LOAD_CONST 2 (false value)
    // Offset 10: STORE_NAME x (merge point)
    const module_ops = [_]OpArg{
        .{ .op = .LOAD_NAME, .arg = 0 },
        .{ .op = .POP_JUMP_IF_FALSE, .arg = 4 },
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .JUMP_FORWARD, .arg = 1 },
        .{ .op = .LOAD_CONST, .arg = 1 },
        .{ .op = .STORE_NAME, .arg = 1 },
        .{ .op = .LOAD_CONST, .arg = 2 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
    };
    module.code = try tu.emitOpsOwned(allocator, version, &module_ops);

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    try decompile.decompileToSource(allocator, &module, version, out.writer(allocator));
    const output: []const u8 = out.items;

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]const u8
        \\  "x = 1 if a else 2
        \\"
    ).expectEqual(output);
}

test "snapshot ternary boolop condition output" {
    const allocator = testing.allocator;
    const version = Version.init(3, 10);

    var module = pyc.Code{
        .allocator = allocator,
    };
    defer module.deinit();

    module.name = try allocator.dupe(u8, "<module>");
    module.names = try tu.dupeStrings(allocator, &[_][]const u8{ "a", "result" });

    const consts = try allocator.alloc(pyc.Object, 5);
    consts[0] = .{ .int = pyc.Int.fromI64(0) };
    consts[1] = .{ .int = pyc.Int.fromI64(2) };
    consts[2] = .{ .string = try allocator.dupe(u8, "yes") };
    consts[3] = .{ .string = try allocator.dupe(u8, "no") };
    consts[4] = .none;
    module.consts = consts;

    // Python 3.10: instruction offsets (byte offset = arg * 2)
    // Offsets: 0:LOAD_NAME, 2:LOAD_CONST, 4:COMPARE_OP, 6:POP_JUMP_IF_FALSE
    //          8:LOAD_NAME, 10:LOAD_CONST, 12:BINARY_MODULO, 14:LOAD_CONST, 16:COMPARE_OP, 18:POP_JUMP_IF_FALSE
    //          20:LOAD_CONST("yes"), 22:JUMP_FORWARD, 24:LOAD_CONST("no"), 26:STORE_NAME
    const module_ops = [_]OpArg{
        .{ .op = .LOAD_NAME, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .COMPARE_OP, .arg = 0 },
        .{ .op = .POP_JUMP_IF_FALSE, .arg = 12 }, // jump to instruction 12 = byte 24 (LOAD_CONST "no")
        .{ .op = .LOAD_NAME, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 1 },
        .{ .op = .BINARY_MODULO, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .COMPARE_OP, .arg = 2 },
        .{ .op = .POP_JUMP_IF_FALSE, .arg = 12 }, // jump to instruction 12 = byte 24 (LOAD_CONST "no")
        .{ .op = .LOAD_CONST, .arg = 2 },
        .{ .op = .JUMP_FORWARD, .arg = 1 }, // jump 1 instruction = to byte 26 (STORE_NAME)
        .{ .op = .LOAD_CONST, .arg = 3 },
        .{ .op = .STORE_NAME, .arg = 1 },
        .{ .op = .LOAD_CONST, .arg = 4 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
    };
    module.code = try tu.emitOpsOwned(allocator, version, &module_ops);

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    try decompile.decompileToSource(allocator, &module, version, out.writer(allocator));
    const output: []const u8 = out.items;

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]const u8
        \\  "result = 'yes' if a < 0 and a % 2 == 0 else 'no'
        \\"
    ).expectEqual(output);
}

test "snapshot python 2.7 class output" {
    const allocator = testing.allocator;
    const version = Version.init(2, 7);

    const class_ops = [_]OpArg{
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
    };
    const class_consts = [_]pyc.Object{.none};
    const class_code = try tu.allocCodeFromOps(
        allocator,
        version,
        "C",
        &[_][]const u8{},
        &class_consts,
        &class_ops,
        0,
    );

    var module = pyc.Code{
        .allocator = allocator,
    };
    defer module.deinit();

    module.name = try allocator.dupe(u8, "<module>");
    module.names = try tu.dupeStrings(allocator, &[_][]const u8{"C"});

    const consts = try allocator.alloc(pyc.Object, 3);
    consts[0] = .{ .code = class_code };
    consts[1] = .{ .string = try allocator.dupe(u8, "C") };
    consts[2] = .none;
    module.consts = consts;

    const module_ops = [_]OpArg{
        .{ .op = .LOAD_CONST, .arg = 1 },
        .{ .op = .BUILD_TUPLE, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .MAKE_FUNCTION, .arg = 0 },
        .{ .op = .CALL_FUNCTION, .arg = 0 },
        .{ .op = .BUILD_CLASS, .arg = 0 },
        .{ .op = .STORE_NAME, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 2 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
    };
    module.code = try tu.emitOpsOwned(allocator, version, &module_ops);

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    try decompile.decompileToSource(allocator, &module, version, out.writer(allocator));
    const output: []const u8 = out.items;

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]const u8
        \\  "class C:
        \\    pass
        \\"
    ).expectEqual(output);
}
