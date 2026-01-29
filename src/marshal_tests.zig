const std = @import("std");
const pyc = @import("pyc.zig");
const testing = std.testing;

// TYPE_NONE
test "marshal TYPE_NONE" {
    const data = [_]u8{'N'};
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.none, std.meta.activeTag(obj));
}

// TYPE_TRUE
test "marshal TYPE_TRUE" {
    const data = [_]u8{'T'};
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.true_val, std.meta.activeTag(obj));
}

// TYPE_FALSE
test "marshal TYPE_FALSE" {
    const data = [_]u8{'F'};
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.false_val, std.meta.activeTag(obj));
}

// TYPE_ELLIPSIS
test "marshal TYPE_ELLIPSIS" {
    const data = [_]u8{'.'};
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.ellipsis, std.meta.activeTag(obj));
}

// TYPE_STOPITER
test "marshal TYPE_STOPITER" {
    const data = [_]u8{'S'};
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.stop_iteration, std.meta.activeTag(obj));
}

// TYPE_INT positive
test "marshal TYPE_INT positive" {
    const val: i32 = 42;
    const val_bytes = @as([4]u8, @bitCast(val));
    const data = [_]u8{ 'i', val_bytes[0], val_bytes[1], val_bytes[2], val_bytes[3] };
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.int, std.meta.activeTag(obj));
    try testing.expectEqual(pyc.Int.small, std.meta.activeTag(obj.int));
    try testing.expectEqual(@as(i64, 42), obj.int.small);
}

// TYPE_INT negative
test "marshal TYPE_INT negative" {
    const val: i32 = -999;
    const val_bytes = @as([4]u8, @bitCast(val));
    const data = [_]u8{ 'i', val_bytes[0], val_bytes[1], val_bytes[2], val_bytes[3] };
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.int, std.meta.activeTag(obj));
    try testing.expectEqual(pyc.Int.small, std.meta.activeTag(obj.int));
    try testing.expectEqual(@as(i64, -999), obj.int.small);
}

// TYPE_INT64 positive
test "marshal TYPE_INT64 positive" {
    const val: i64 = 1234567890123;
    const val_bytes = @as([8]u8, @bitCast(val));
    const data = [_]u8{ 'I', val_bytes[0], val_bytes[1], val_bytes[2], val_bytes[3], val_bytes[4], val_bytes[5], val_bytes[6], val_bytes[7] };
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.int, std.meta.activeTag(obj));
    try testing.expectEqual(pyc.Int.small, std.meta.activeTag(obj.int));
    try testing.expectEqual(@as(i64, 1234567890123), obj.int.small);
}

// TYPE_INT64 negative
test "marshal TYPE_INT64 negative" {
    const val: i64 = -9876543210987;
    const val_bytes = @as([8]u8, @bitCast(val));
    const data = [_]u8{ 'I', val_bytes[0], val_bytes[1], val_bytes[2], val_bytes[3], val_bytes[4], val_bytes[5], val_bytes[6], val_bytes[7] };
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.int, std.meta.activeTag(obj));
    try testing.expectEqual(pyc.Int.small, std.meta.activeTag(obj.int));
    try testing.expectEqual(@as(i64, -9876543210987), obj.int.small);
}

// TYPE_BINARY_FLOAT
test "marshal TYPE_BINARY_FLOAT" {
    const val: f64 = 3.14159;
    const val_bytes = @as([8]u8, @bitCast(val));
    const data = [_]u8{ 'g', val_bytes[0], val_bytes[1], val_bytes[2], val_bytes[3], val_bytes[4], val_bytes[5], val_bytes[6], val_bytes[7] };
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.float, std.meta.activeTag(obj));
    try testing.expectApproxEqAbs(3.14159, obj.float, 0.00001);
}

// TYPE_FLOAT (text-based)
test "marshal TYPE_FLOAT text" {
    const text = "2.71828";
    const data = [_]u8{ 'f', text.len } ++ text.*;
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.float, std.meta.activeTag(obj));
    try testing.expectApproxEqAbs(2.71828, obj.float, 0.00001);
}

// TYPE_BINARY_COMPLEX
test "marshal TYPE_BINARY_COMPLEX" {
    const real: f64 = 1.5;
    const imag: f64 = 2.5;
    const real_bytes = @as([8]u8, @bitCast(real));
    const imag_bytes = @as([8]u8, @bitCast(imag));
    const data = [_]u8{
        'y',
        real_bytes[0],
        real_bytes[1],
        real_bytes[2],
        real_bytes[3],
        real_bytes[4],
        real_bytes[5],
        real_bytes[6],
        real_bytes[7],
        imag_bytes[0],
        imag_bytes[1],
        imag_bytes[2],
        imag_bytes[3],
        imag_bytes[4],
        imag_bytes[5],
        imag_bytes[6],
        imag_bytes[7],
    };
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.complex, std.meta.activeTag(obj));
    try testing.expectApproxEqAbs(1.5, obj.complex.real, 0.00001);
    try testing.expectApproxEqAbs(2.5, obj.complex.imag, 0.00001);
}

// TYPE_COMPLEX (text-based)
test "marshal TYPE_COMPLEX text" {
    const real_text = "1.0";
    const imag_text = "2.0";
    const data = [_]u8{ 'x', real_text.len } ++ real_text.* ++ [_]u8{imag_text.len} ++ imag_text.*;
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.complex, std.meta.activeTag(obj));
    try testing.expectApproxEqAbs(1.0, obj.complex.real, 0.00001);
    try testing.expectApproxEqAbs(2.0, obj.complex.imag, 0.00001);
}

// TYPE_STRING
test "marshal TYPE_STRING" {
    const str = "hello";
    const len_bytes = @as([4]u8, @bitCast(@as(u32, str.len)));
    const data = [_]u8{ 's', len_bytes[0], len_bytes[1], len_bytes[2], len_bytes[3] } ++ str.*;
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.string, std.meta.activeTag(obj));
    try testing.expectEqualStrings("hello", obj.string);
}

// TYPE_ASCII
test "marshal TYPE_ASCII" {
    const str = "world";
    const len_bytes = @as([4]u8, @bitCast(@as(u32, str.len)));
    const data = [_]u8{ 'a', len_bytes[0], len_bytes[1], len_bytes[2], len_bytes[3] } ++ str.*;
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.string, std.meta.activeTag(obj));
    try testing.expectEqualStrings("world", obj.string);
}

// TYPE_SHORT_ASCII
test "marshal TYPE_SHORT_ASCII" {
    const str = "foo";
    const data = [_]u8{ 'z', str.len } ++ str.*;
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.string, std.meta.activeTag(obj));
    try testing.expectEqualStrings("foo", obj.string);
}

// TYPE_INTERNED
test "marshal TYPE_INTERNED" {
    const str = "bar";
    const len_bytes = @as([4]u8, @bitCast(@as(u32, str.len)));
    const data = [_]u8{ 't', len_bytes[0], len_bytes[1], len_bytes[2], len_bytes[3] } ++ str.*;
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.string, std.meta.activeTag(obj));
    try testing.expectEqualStrings("bar", obj.string);
    try testing.expectEqual(@as(usize, 1), mod.interns.items.len);
    try testing.expectEqualStrings("bar", mod.interns.items[0]);
}

// TYPE_ASCII_INTERNED
test "marshal TYPE_ASCII_INTERNED" {
    const str = "baz";
    const len_bytes = @as([4]u8, @bitCast(@as(u32, str.len)));
    const data = [_]u8{ 'A', len_bytes[0], len_bytes[1], len_bytes[2], len_bytes[3] } ++ str.*;
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.string, std.meta.activeTag(obj));
    try testing.expectEqualStrings("baz", obj.string);
    try testing.expectEqual(@as(usize, 1), mod.interns.items.len);
    try testing.expectEqualStrings("baz", mod.interns.items[0]);
}

// TYPE_SHORT_ASCII_INTERNED
test "marshal TYPE_SHORT_ASCII_INTERNED" {
    const str = "qux";
    const data = [_]u8{ 'Z', str.len } ++ str.*;
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.string, std.meta.activeTag(obj));
    try testing.expectEqualStrings("qux", obj.string);
    try testing.expectEqual(@as(usize, 1), mod.interns.items.len);
    try testing.expectEqualStrings("qux", mod.interns.items[0]);
}

// TYPE_UNICODE
test "marshal TYPE_UNICODE" {
    const str = "café";
    const len_bytes = @as([4]u8, @bitCast(@as(u32, str.len)));
    const data = [_]u8{ 'u', len_bytes[0], len_bytes[1], len_bytes[2], len_bytes[3] } ++ str.*;
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.string, std.meta.activeTag(obj));
    try testing.expectEqualStrings("café", obj.string);
}

// TYPE_TUPLE empty
test "marshal TYPE_TUPLE empty" {
    const count_bytes = @as([4]u8, @bitCast(@as(u32, 0)));
    const data = [_]u8{ '(', count_bytes[0], count_bytes[1], count_bytes[2], count_bytes[3] };
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.tuple, std.meta.activeTag(obj));
    try testing.expectEqual(@as(usize, 0), obj.tuple.len);
}

// TYPE_TUPLE with items
test "marshal TYPE_TUPLE with items" {
    const count_bytes = @as([4]u8, @bitCast(@as(u32, 2)));
    const data = [_]u8{ '(', count_bytes[0], count_bytes[1], count_bytes[2], count_bytes[3], 'N', 'T' };
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.tuple, std.meta.activeTag(obj));
    try testing.expectEqual(@as(usize, 2), obj.tuple.len);
    try testing.expectEqual(pyc.Object.none, std.meta.activeTag(obj.tuple[0]));
    try testing.expectEqual(pyc.Object.true_val, std.meta.activeTag(obj.tuple[1]));
}

// TYPE_SMALL_TUPLE
test "marshal TYPE_SMALL_TUPLE" {
    const data = [_]u8{ ')', 3, 'F', 'T', 'N' };
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.tuple, std.meta.activeTag(obj));
    try testing.expectEqual(@as(usize, 3), obj.tuple.len);
    try testing.expectEqual(pyc.Object.false_val, std.meta.activeTag(obj.tuple[0]));
    try testing.expectEqual(pyc.Object.true_val, std.meta.activeTag(obj.tuple[1]));
    try testing.expectEqual(pyc.Object.none, std.meta.activeTag(obj.tuple[2]));
}

// TYPE_LIST empty
test "marshal TYPE_LIST empty" {
    const count_bytes = @as([4]u8, @bitCast(@as(u32, 0)));
    const data = [_]u8{ '[', count_bytes[0], count_bytes[1], count_bytes[2], count_bytes[3] };
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.list, std.meta.activeTag(obj));
    try testing.expectEqual(@as(usize, 0), obj.list.len);
}

// TYPE_LIST with items
test "marshal TYPE_LIST with items" {
    const count_bytes = @as([4]u8, @bitCast(@as(u32, 2)));
    const data = [_]u8{ '[', count_bytes[0], count_bytes[1], count_bytes[2], count_bytes[3], 'T', 'F' };
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.list, std.meta.activeTag(obj));
    try testing.expectEqual(@as(usize, 2), obj.list.len);
    try testing.expectEqual(pyc.Object.true_val, std.meta.activeTag(obj.list[0]));
    try testing.expectEqual(pyc.Object.false_val, std.meta.activeTag(obj.list[1]));
}

// TYPE_SET empty
test "marshal TYPE_SET empty" {
    const count_bytes = @as([4]u8, @bitCast(@as(u32, 0)));
    const data = [_]u8{ '<', count_bytes[0], count_bytes[1], count_bytes[2], count_bytes[3] };
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.set, std.meta.activeTag(obj));
    try testing.expectEqual(@as(usize, 0), obj.set.len);
}

// TYPE_SET with items
test "marshal TYPE_SET with items" {
    const count_bytes = @as([4]u8, @bitCast(@as(u32, 1)));
    const data = [_]u8{ '<', count_bytes[0], count_bytes[1], count_bytes[2], count_bytes[3], 'N' };
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.set, std.meta.activeTag(obj));
    try testing.expectEqual(@as(usize, 1), obj.set.len);
    try testing.expectEqual(pyc.Object.none, std.meta.activeTag(obj.set[0]));
}

// TYPE_FROZENSET empty
test "marshal TYPE_FROZENSET empty" {
    const count_bytes = @as([4]u8, @bitCast(@as(u32, 0)));
    const data = [_]u8{ '>', count_bytes[0], count_bytes[1], count_bytes[2], count_bytes[3] };
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.frozenset, std.meta.activeTag(obj));
    try testing.expectEqual(@as(usize, 0), obj.frozenset.len);
}

// TYPE_FROZENSET with items
test "marshal TYPE_FROZENSET with items" {
    const count_bytes = @as([4]u8, @bitCast(@as(u32, 2)));
    const data = [_]u8{ '>', count_bytes[0], count_bytes[1], count_bytes[2], count_bytes[3], 'T', 'F' };
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.frozenset, std.meta.activeTag(obj));
    try testing.expectEqual(@as(usize, 2), obj.frozenset.len);
    try testing.expectEqual(pyc.Object.true_val, std.meta.activeTag(obj.frozenset[0]));
    try testing.expectEqual(pyc.Object.false_val, std.meta.activeTag(obj.frozenset[1]));
}

// TYPE_DICT empty
test "marshal TYPE_DICT empty" {
    const data = [_]u8{ '{', '0' };
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.dict, std.meta.activeTag(obj));
    try testing.expectEqual(@as(usize, 0), obj.dict.len);
}

// TYPE_DICT with entries
test "marshal TYPE_DICT with entries" {
    const data = [_]u8{ '{', 'N', 'T', 'F', 'N', '0' };
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.dict, std.meta.activeTag(obj));
    try testing.expectEqual(@as(usize, 2), obj.dict.len);
    try testing.expectEqual(pyc.Object.none, std.meta.activeTag(obj.dict[0].key));
    try testing.expectEqual(pyc.Object.true_val, std.meta.activeTag(obj.dict[0].value));
    try testing.expectEqual(pyc.Object.false_val, std.meta.activeTag(obj.dict[1].key));
    try testing.expectEqual(pyc.Object.none, std.meta.activeTag(obj.dict[1].value));
}

// TYPE_REF with FLAG_REF on string
test "marshal string with FLAG_REF" {
    const str = "test";
    const len_bytes = @as([4]u8, @bitCast(@as(u32, str.len)));
    const data = [_]u8{ 's' | 0x80, len_bytes[0], len_bytes[1], len_bytes[2], len_bytes[3] } ++ str.*;
    var reader = pyc.BufferReader{ .data = &data };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 3;
    mod.minor_ver = 11;

    var obj = try mod.readAnyObject(&reader);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.string, std.meta.activeTag(obj));
    try testing.expectEqualStrings("test", obj.string);
    try testing.expectEqual(@as(usize, 1), mod.refs.items.len);
    try testing.expectEqual(pyc.Object.string, std.meta.activeTag(mod.refs.items[0]));
}

// TYPE_STRINGREF (Python 2.x)
test "marshal TYPE_STRINGREF" {
    const str = "interned";
    const len_bytes = @as([4]u8, @bitCast(@as(u32, str.len)));

    // First intern a string
    const data1 = [_]u8{ 't', len_bytes[0], len_bytes[1], len_bytes[2], len_bytes[3] } ++ str.*;
    var reader1 = pyc.BufferReader{ .data = &data1 };
    var mod: pyc.Module = undefined;
    mod.init(testing.allocator);
    defer mod.deinit();
    mod.major_ver = 2;
    mod.minor_ver = 7;

    var obj1 = try mod.readAnyObject(&reader1);
    obj1.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), mod.interns.items.len);

    // Now reference it via TYPE_STRINGREF
    const idx_bytes = @as([4]u8, @bitCast(@as(u32, 0)));
    const data2 = [_]u8{ 'R', idx_bytes[0], idx_bytes[1], idx_bytes[2], idx_bytes[3] };
    var reader2 = pyc.BufferReader{ .data = &data2 };

    var obj2 = try mod.readAnyObject(&reader2);
    defer obj2.deinit(testing.allocator);

    try testing.expectEqual(pyc.Object.string, std.meta.activeTag(obj2));
    try testing.expectEqualStrings("interned", obj2.string);
}
