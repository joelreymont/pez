const std = @import("std");

pub fn unmangleClassName(
    allocator: std.mem.Allocator,
    class_name: ?[]const u8,
    name: []const u8,
) ![]const u8 {
    const cls_name = class_name orelse return name;
    var idx: usize = 0;
    while (idx < cls_name.len and cls_name[idx] == '_') : (idx += 1) {}
    if (idx == cls_name.len) return name;
    const stripped = cls_name[idx..];
    const prefix_len = 1 + stripped.len + 2;
    if (name.len <= prefix_len) return name;
    if (name[0] != '_') return name;
    if (!std.mem.eql(u8, name[1 .. 1 + stripped.len], stripped)) return name;
    if (name[1 + stripped.len] != '_' or name[1 + stripped.len + 1] != '_') return name;
    const rest = name[prefix_len..];
    if (rest.len == 0) return name;
    if (rest.len >= 2 and std.mem.endsWith(u8, rest, "__")) return name;
    const out = try allocator.alloc(u8, rest.len + 2);
    out[0] = '_';
    out[1] = '_';
    @memcpy(out[2..], rest);
    return out;
}
