//! Function signature extraction and annotations.

const std = @import("std");
const ast = @import("ast.zig");
const pyc = @import("pyc.zig");

/// Annotation for a function parameter or return type.
pub const Annotation = struct {
    name: []const u8, // Parameter name or "return" for return type
    value: *ast.Expr, // Annotation expression
};

/// Extract function signature from a code object.
/// Returns an Arguments structure suitable for AST function definition.
pub fn extractFunctionSignature(
    allocator: std.mem.Allocator,
    code: *const pyc.Code,
    defaults: []const *ast.Expr,
    kw_defaults: []const ?*ast.Expr,
    annotations: []const Annotation,
) !*ast.Arguments {
    const args = try allocator.create(ast.Arguments);
    errdefer allocator.destroy(args);

    // Helper to find annotation for a parameter name
    const findAnnotation = struct {
        fn find(anns: []const Annotation, name: []const u8) ?*ast.Expr {
            for (anns) |ann| {
                if (std.mem.eql(u8, ann.name, name)) {
                    return ann.value;
                }
            }
            return null;
        }
    }.find;

    // Calculate argument positions
    const argcount = code.argcount;
    const posonlyargcount = code.posonlyargcount;
    const kwonlyargcount = code.kwonlyargcount;

    // Position-only args: varnames[0..posonlyargcount]
    var posonly_args: []ast.Arg = &.{};
    if (posonlyargcount > 0 and code.varnames.len >= posonlyargcount) {
        posonly_args = try allocator.alloc(ast.Arg, posonlyargcount);
        for (code.varnames[0..posonlyargcount], 0..) |name, i| {
            posonly_args[i] = .{ .arg = name, .annotation = findAnnotation(annotations, name), .type_comment = null };
        }
    }

    // Regular args: varnames[posonlyargcount..argcount]
    var regular_args: []ast.Arg = &.{};
    const regular_start = posonlyargcount;
    const regular_end = argcount;
    if (regular_end > regular_start and code.varnames.len >= regular_end) {
        regular_args = try allocator.alloc(ast.Arg, regular_end - regular_start);
        for (code.varnames[regular_start..regular_end], 0..) |name, i| {
            regular_args[i] = .{ .arg = name, .annotation = findAnnotation(annotations, name), .type_comment = null };
        }
    }

    // Keyword-only args: after argcount
    var kwonly_args: []ast.Arg = &.{};
    const kwonly_start = argcount;
    const kwonly_end = argcount + kwonlyargcount;
    if (kwonlyargcount > 0 and code.varnames.len >= kwonly_end) {
        kwonly_args = try allocator.alloc(ast.Arg, kwonlyargcount);
        for (code.varnames[kwonly_start..kwonly_end], 0..) |name, i| {
            kwonly_args[i] = .{ .arg = name, .annotation = findAnnotation(annotations, name), .type_comment = null };
        }
    }

    // *args and **kwargs follow positional and keyword-only args in varnames
    var next_arg_idx: usize = @intCast(argcount + kwonlyargcount);
    var vararg: ?ast.Arg = null;
    if ((code.flags & pyc.Code.CO_VARARGS) != 0) {
        if (next_arg_idx < code.varnames.len) {
            const name = code.varnames[next_arg_idx];
            vararg = .{
                .arg = name,
                .annotation = findAnnotation(annotations, name),
                .type_comment = null,
            };
            next_arg_idx += 1;
        }
    }

    var kwarg: ?ast.Arg = null;
    if ((code.flags & pyc.Code.CO_VARKEYWORDS) != 0) {
        if (next_arg_idx < code.varnames.len) {
            const name = code.varnames[next_arg_idx];
            kwarg = .{
                .arg = name,
                .annotation = findAnnotation(annotations, name),
                .type_comment = null,
            };
        }
    }

    args.* = .{
        .posonlyargs = posonly_args,
        .args = regular_args,
        .vararg = vararg,
        .kwonlyargs = kwonly_args,
        .kw_defaults = kw_defaults,
        .kwarg = kwarg,
        .defaults = defaults,
    };

    return args;
}
