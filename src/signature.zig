//! Function signature extraction and annotations.

const std = @import("std");
const ast = @import("ast.zig");
const name_mangle = @import("name_mangle.zig");
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
    class_name: ?[]const u8,
    defaults: []const *ast.Expr,
    kw_defaults: []const ?*ast.Expr,
    annotations: []const Annotation,
) !*ast.Arguments {
    const args = try allocator.create(ast.Arguments);
    errdefer allocator.destroy(args);

    // Helper to find annotation for a parameter name
    const findAnnotation = struct {
        fn find(
            alloc: std.mem.Allocator,
            cls_name: ?[]const u8,
            anns: []const Annotation,
            name: []const u8,
        ) !?*ast.Expr {
            for (anns) |ann| {
                const ann_name = try name_mangle.unmangleClassName(alloc, cls_name, ann.name);
                if (std.mem.eql(u8, ann_name, name)) {
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
            const unmangled = try name_mangle.unmangleClassName(allocator, class_name, name);
            posonly_args[i] = .{
                .arg = unmangled,
                .annotation = try findAnnotation(allocator, class_name, annotations, unmangled),
                .type_comment = null,
            };
        }
    }

    // Regular args: varnames[posonlyargcount..argcount]
    var regular_args: []ast.Arg = &.{};
    const regular_start = posonlyargcount;
    const regular_end = argcount;
    if (regular_end > regular_start and code.varnames.len >= regular_end) {
        regular_args = try allocator.alloc(ast.Arg, regular_end - regular_start);
        for (code.varnames[regular_start..regular_end], 0..) |name, i| {
            const unmangled = try name_mangle.unmangleClassName(allocator, class_name, name);
            regular_args[i] = .{
                .arg = unmangled,
                .annotation = try findAnnotation(allocator, class_name, annotations, unmangled),
                .type_comment = null,
            };
        }
    }

    // Keyword-only args: after argcount
    var kwonly_args: []ast.Arg = &.{};
    const kwonly_start = argcount;
    const kwonly_end = argcount + kwonlyargcount;
    if (kwonlyargcount > 0 and code.varnames.len >= kwonly_end) {
        kwonly_args = try allocator.alloc(ast.Arg, kwonlyargcount);
        for (code.varnames[kwonly_start..kwonly_end], 0..) |name, i| {
            const unmangled = try name_mangle.unmangleClassName(allocator, class_name, name);
            kwonly_args[i] = .{
                .arg = unmangled,
                .annotation = try findAnnotation(allocator, class_name, annotations, unmangled),
                .type_comment = null,
            };
        }
    }

    // *args and **kwargs follow positional and keyword-only args in varnames
    var next_arg_idx: usize = @intCast(argcount + kwonlyargcount);
    var vararg: ?ast.Arg = null;
    if ((code.flags & pyc.Code.CO_VARARGS) != 0) {
        if (next_arg_idx < code.varnames.len) {
            const name = code.varnames[next_arg_idx];
            const unmangled = try name_mangle.unmangleClassName(allocator, class_name, name);
            vararg = .{
                .arg = unmangled,
                .annotation = try findAnnotation(allocator, class_name, annotations, unmangled),
                .type_comment = null,
            };
            next_arg_idx += 1;
        }
    }

    var kwarg: ?ast.Arg = null;
    if ((code.flags & pyc.Code.CO_VARKEYWORDS) != 0) {
        if (next_arg_idx < code.varnames.len) {
            const name = code.varnames[next_arg_idx];
            const unmangled = try name_mangle.unmangleClassName(allocator, class_name, name);
            kwarg = .{
                .arg = unmangled,
                .annotation = try findAnnotation(allocator, class_name, annotations, unmangled),
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
