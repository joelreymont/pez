const std = @import("std");
const opcodes = @import("opcodes.zig");
const decoder = @import("decoder.zig");
const pyc = @import("pyc.zig");
const stack = @import("stack.zig");
const codegen = @import("codegen.zig");
const decompile = @import("decompile.zig");

pub const Allocator = std.mem.Allocator;
pub const Version = opcodes.Version;
pub const Opcode = opcodes.Opcode;
pub const Instruction = decoder.Instruction;

pub fn inst(op: Opcode, arg: u32) Instruction {
    return .{
        .opcode = op,
        .arg = arg,
        .offset = 0,
        .size = 2,
        .cache_entries = 0,
    };
}

pub fn renderExpr(allocator: Allocator, expr: *const stack.Expr) ![]const u8 {
    var writer = codegen.Writer.init(allocator);
    defer writer.deinit(allocator);
    try writer.writeExpr(allocator, expr);
    return writer.getOutput(allocator);
}

pub fn renderExprWithNewline(allocator: Allocator, expr: *const stack.Expr) ![]const u8 {
    const output = try renderExpr(allocator, expr);
    defer allocator.free(output);
    return std.mem.concat(allocator, u8, &[_][]const u8{ output, "\n" });
}

pub fn renderModule(allocator: Allocator, code: *const pyc.Code, version: Version) ![]const u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    try decompile.decompileToSource(allocator, code, version, out.writer(allocator));
    return out.toOwnedSlice(allocator);
}

pub fn dupeStrings(allocator: Allocator, items: []const []const u8) ![][]const u8 {
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

pub fn simulateExpr(allocator: Allocator, code: *pyc.Code, version: Version, insts: []const Instruction) !*stack.Expr {
    var sim = stack.SimContext.init(allocator, allocator, code, version);
    defer sim.deinit();

    for (insts) |item| {
        try sim.simulate(item);
    }
    return sim.stack.popExpr();
}

pub fn opcodeByte(version: Version, op: Opcode) u8 {
    const table = opcodes.getOpcodeTable(version);
    for (table, 0..) |entry, idx| {
        if (entry == op) return @intCast(idx);
    }
    @panic("opcode not in table");
}

pub fn emitOp(bytes: *std.ArrayList(u8), allocator: Allocator, version: Version, op: Opcode, arg: u32) !void {
    try bytes.append(allocator, opcodeByte(version, op));
    if (version.gte(3, 6)) {
        try bytes.append(allocator, @intCast(arg & 0xFF));

        const cache_entries = opcodes.cacheEntries(op, version);
        if (cache_entries > 0) {
            const cache_bytes = @as(usize, cache_entries) * 2;
            try bytes.appendNTimes(allocator, 0, cache_bytes);
        }
        return;
    }

    if (op.hasArg(version)) {
        try bytes.append(allocator, @intCast(arg & 0xFF));
        try bytes.append(allocator, @intCast((arg >> 8) & 0xFF));
    }
}

pub const OpArg = struct {
    op: Opcode,
    arg: u32,
};

pub fn emitOps(bytes: *std.ArrayList(u8), allocator: Allocator, version: Version, ops: []const OpArg) !void {
    for (ops) |item| {
        try emitOp(bytes, allocator, version, item.op, item.arg);
    }
}

pub fn emitOpsOwned(allocator: Allocator, version: Version, ops: []const OpArg) ![]u8 {
    var bytes: std.ArrayList(u8) = .{};
    errdefer bytes.deinit(allocator);
    try emitOps(&bytes, allocator, version, ops);
    return bytes.toOwnedSlice(allocator);
}

pub fn allocCode(
    allocator: Allocator,
    name: []const u8,
    varnames_in: []const []const u8,
    consts_in: []const pyc.Object,
    bytecode: []u8,
    argcount: u32,
) !*pyc.Code {
    const code = try allocator.create(pyc.Code);
    errdefer allocator.destroy(code);

    errdefer allocator.free(bytecode);

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

    code.* = .{
        .allocator = allocator,
        .argcount = argcount,
        .nlocals = @intCast(varnames_in.len),
        .code = bytecode,
        .consts = consts,
        .varnames = varnames,
        .name = name_copy,
    };
    return code;
}

pub fn allocCodeWithNames(
    allocator: Allocator,
    name: []const u8,
    varnames_in: []const []const u8,
    names_in: []const []const u8,
    consts_in: []const pyc.Object,
    bytecode: []u8,
    argcount: u32,
) !*pyc.Code {
    const code = try allocator.create(pyc.Code);
    errdefer allocator.destroy(code);

    errdefer allocator.free(bytecode);

    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);

    const varnames = try dupeStrings(allocator, varnames_in);
    errdefer {
        for (varnames) |v| allocator.free(v);
        allocator.free(varnames);
    }

    const names = try dupeStrings(allocator, names_in);
    errdefer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    const consts = try allocator.alloc(pyc.Object, consts_in.len);
    errdefer allocator.free(consts);
    for (consts_in, 0..) |obj, idx| {
        consts[idx] = obj;
    }

    code.* = .{
        .allocator = allocator,
        .argcount = argcount,
        .nlocals = @intCast(varnames_in.len),
        .code = bytecode,
        .consts = consts,
        .names = names,
        .varnames = varnames,
        .name = name_copy,
    };
    return code;
}

pub fn allocCodeFromOps(
    allocator: Allocator,
    version: Version,
    name: []const u8,
    varnames_in: []const []const u8,
    consts_in: []const pyc.Object,
    ops: []const OpArg,
    argcount: u32,
) !*pyc.Code {
    const bytecode = try emitOpsOwned(allocator, version, ops);
    return allocCode(allocator, name, varnames_in, consts_in, bytecode, argcount);
}
