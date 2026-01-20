//! Snapshot tests for boat-main regressions (3.9).

const std = @import("std");
const testing = std.testing;
const OhSnap = @import("ohsnap");

const pyc = @import("pyc.zig");
const decompile = @import("decompile.zig");
const Version = @import("opcodes.zig").Version;

fn runSnapshot(
    comptime src: std.builtin.SourceLocation,
    path: []const u8,
    comptime expected: []const u8,
) !void {
    const allocator = testing.allocator;

    var module = pyc.Module.init(allocator);
    defer module.deinit();
    try module.loadFromFile(path);

    const code = module.code orelse {
        try testing.expect(false);
        return;
    };
    const version = Version.init(@intCast(module.major_ver), @intCast(module.minor_ver));

    var output: std.ArrayList(u8) = .{};
    defer output.deinit(allocator);
    try decompile.decompileToSource(allocator, code, version, output.writer(allocator));

    const oh = OhSnap{};
    try oh.snap(src, expected).expectEqual(output.items);
}

test "snapshot loop guard 3.9" {
    try runSnapshot(@src(), "test/corpus/loop_guard.3.9.pyc",
        \\[]u8
        \\  "import sys
        \\class Bdb:
        \\    def _set_stopinfo(self, *args, **kwargs):
        \\        pass
        \\    def set_continue(self):
        \\        self._set_stopinfo(self.botframe, None, -1)
        \\        if self.breaks:
        \\            pass
        \\        else:
        \\            sys.settrace(None)
        \\            frame = sys._getframe().f_back
        \\            while frame and frame is not self.botframe:
        \\                del frame.f_trace
        \\                frame = frame.f_back
        \\def del_subscr(d):
        \\    del d['x']
        \\"
    );
}

test "snapshot relative import 3.9" {
    try runSnapshot(@src(), "test/corpus/relative_import.3.9.pyc",
        \\[]u8
        \\  "from . import foo
        \\from .bar import baz
        \\from ..pkg import qux
        \\"
    );
}

test "snapshot import from group 3.9" {
    try runSnapshot(@src(), "test/corpus/import_from_group.3.9.pyc",
        \\[]u8
        \\  "from pkg import a, b as c, d
        \\from . import local_a, local_b as lb
        \\from ..parent import x, y as yy
        \\from mod import *
        \\"
    );
}

test "snapshot import dotted 3.9" {
    try runSnapshot(@src(), "test/corpus/import_dotted.3.9.pyc",
        \\[]u8
        \\  "import a.b
        \\import a.b as c
        \\"
    );
}

test "snapshot future docstring 3.9" {
    try runSnapshot(@src(), "test/corpus/future_docstring.3.9.pyc",
        \\[]u8
        \\  "'Docstring for future import test.'
        \\from __future__ import annotations
        \\value = 1
        \\"
    );
}

test "snapshot module if prelude 3.9" {
    try runSnapshot(@src(), "test/corpus/module_if_prelude.3.9.pyc",
        \\[]u8
        \\  "x = 1
        \\y = 2
        \\if x:
        \\    y = 3
        \\else:
        \\    y = 4
        \\"
    );
}

test "snapshot if attr prelude 3.9" {
    try runSnapshot(@src(), "test/corpus/if_attr_prelude.3.9.pyc",
        \\[]u8
        \\  "import sys
        \\sys.prefix = sys._MEIPASS
        \\if sys.prefix:
        \\    pass
        \\"
    );
}

test "snapshot loop if chain 3.9" {
    try runSnapshot(@src(), "test/corpus/loop_if_chain.3.9.pyc",
        \\[]u8
        \\  "import os
        \\import time
        \\cmd_kill = False
        \\cmd_shutdown = False
        \\cmd_reboot = False
        \\if __name__ == '__main__':
        \\    while True:
        \\        if cmd_kill:
        \\            print('kill')
        \\            os._exit(os.EX_OK)
        \\        if cmd_shutdown:
        \\            try:
        \\                print('bye')
        \\            except Exception:
        \\                print('without bye')
        \\            time.sleep(10)
        \\            os.system('shutdown now')
        \\        else:
        \\            time.sleep(1)
        \\        if cmd_reboot:
        \\            time.sleep(10)
        \\            os.system('reboot')
        \\"
    );
}

test "snapshot loop guard continue 3.9" {
    try runSnapshot(@src(), "test/corpus/loop_guard_continue.3.9.pyc",
        \\[]u8
        \\  "def f(entries):
        \\    for entry in entries:
        \\        if not entry:
        \\            continue
        \\        if entry.endswith('.egg'):
        \\            entries.append(entry)
        \\"
    );
}

test "snapshot loop guard try continue 3.9" {
    try runSnapshot(@src(), "test/corpus/loop_guard_try_continue.3.9.pyc",
        \\[]u8
        \\  "import time
        \\def f(sock):
        \\    while True:
        \\        try:
        \\            data = sock.recv(1024)
        \\            if not data:
        \\                continue
        \\            sock.send(data)
        \\        except Exception as e:
        \\            print(e)
        \\            time.sleep(1)
        \\"
    );
}

test "snapshot loop or condition 3.9" {
    try runSnapshot(@src(), "test/corpus/loop_or_condition.3.9.pyc",
        \\[]u8
        \\  "def f(mods, package):
        \\    for mod in mods:
        \\        if mod == package or mod.startswith(f'{package}.'):
        \\            mods.append(mod)
        \\"
    );
}

test "snapshot loop if not 3.9" {
    try runSnapshot(@src(), "test/corpus/loop_if_not.3.9.pyc",
        \\[]u8
        \\  "def f(items):
        \\    out = []
        \\    for x in items:
        \\        if not is_valid(x):
        \\            out.append(x)
        \\        else:
        \\            out.append(x + 1)
        \\    return out
        \\"
    );
}

test "snapshot loop guard return 3.9" {
    try runSnapshot(@src(), "test/corpus/loop_guard_return.3.9.pyc",
        \\[]u8
        \\  "def f(data):
        \\    out = []
        \\    i = 0
        \\    while True:
        \\        if data[i] == 0:
        \\            out.append(i)
        \\            return out
        \\        out.append(data[i])
        \\        i = i + 1
        \\"
    );
}

test "snapshot class metaclass 3.9" {
    try runSnapshot(@src(), "test/corpus/class_metaclass.3.9.pyc",
        \\[]u8
        \\  "class Meta(type):
        \\    pass
        \\class Foo(metaclass=Meta):
        \\    value = 1
        \\"
    );
}

test "snapshot class method annotations 3.9" {
    try runSnapshot(@src(), "test/corpus/class_method_annotations.3.9.pyc",
        \\[]u8
        \\  "from typing import List
        \\class C:
        \\    def f(self, x: int) -> List[int]:
        \\        pass
        \\"
    );
}

test "snapshot bool or call 3.9" {
    try runSnapshot(@src(), "test/corpus/bool_or_call.3.9.pyc",
        \\[]u8
        \\  "def f(parameters = None):
        \\    x = 1
        \\    return dict(a=parameters or {})
        \\"
    );
}

test "snapshot bytes constants 3.9" {
    try runSnapshot(@src(), "test/corpus/bytes_constants.3.9.pyc",
        \\[]u8
        \\  "def f():
        \\    return (b'\xff\xe0', b'Exif\x00\x00', b'abc')
        \\"
    );
}

test "snapshot aug assign targets 3.9" {
    try runSnapshot(@src(), "test/corpus/aug_assign_targets.3.9.pyc",
        \\[]u8
        \\  "class C:
        \\    def __init__(self):
        \\        self.items = []
        \\    def add(self, value):
        \\        self.items += [value]
        \\def add_video(codecs, codec):
        \\    codecs['video'] += [codec]
        \\"
    );
}

test "snapshot loop header body 3.9" {
    try runSnapshot(@src(), "test/corpus/while_header_body.3.9.pyc",
        \\[]u8
        \\  "class Reader:
        \\    def __init__(self, fp):
        \\        self.fp = fp
        \\    def read(self):
        \\        text = ''
        \\        while True:
        \\            data = self.fp.readline()
        \\            text = text + data
        \\            if not data.strip():
        \\                break
        \\        return text
        \\"
    );
}

test "snapshot for unpack target 3.9" {
    try runSnapshot(@src(), "test/corpus/for_unpack_target.3.9.pyc",
        \\[]u8
        \\  "def build(items, prefix):
        \\    out = []
        \\    for entry_name, entry_data in items:
        \\        name_component = entry_name[len(prefix):]
        \\        out.append((name_component, entry_data))
        \\    for head, *rest in items:
        \\        out.append((head, rest))
        \\    return out
        \\"
    );
}

test "snapshot with body if return 3.9" {
    try runSnapshot(@src(), "test/corpus/with_body_if_return.3.9.pyc",
        \\[]u8
        \\  "import threading
        \\_lock = threading.RLock()
        \\_val = None
        \\def get_val(x):
        \\    global _val
        \\    with _lock:
        \\        if _val is None:
        \\            _val = x
        \\        return _val
        \\"
    );
}

test "snapshot if return fallthrough 3.9" {
    try runSnapshot(@src(), "test/corpus/if_return_fallthrough.3.9.pyc",
        \\[]u8
        \\  "def f(x):
        \\    if x:
        \\        return 1
        \\    else:
        \\        return 2
        \\"
    );
}

test "snapshot if return else fallthrough 3.9" {
    try runSnapshot(@src(), "test/corpus/if_else_return_fallthrough.3.9.pyc",
        \\[]u8
        \\  "def f(x):
        \\    if x:
        \\        y = 1
        \\    else:
        \\        return 2
        \\    return y
        \\"
    );
}

test "snapshot if prelude then if 3.9" {
    try runSnapshot(@src(), "test/corpus/if_prelude_then_if.3.9.pyc",
        \\[]u8
        \\  "def f(data):
        \\    if len(data) < 1:
        \\        raise ValueError('short')
        \\    x = data[0]
        \\    if x:
        \\        return 1
        \\    else:
        \\        return 2
        \\"
    );
}

test "snapshot try import 3.9" {
    try runSnapshot(@src(), "test/corpus/try_import.3.9.pyc",
        \\[]u8
        \\  "try:
        \\    import zlib
        \\except ImportError as err:
        \\    zlib = None
        \\    err = None
        \\else:
        \\    zlib = zlib
        \\"
    );
}

test "snapshot try except return 3.9" {
    try runSnapshot(@src(), "test/corpus/try_except_return.3.9.pyc",
        \\[]u8
        \\  "def f():
        \\    try:
        \\        x()
        \\    except Exception:
        \\        y()
        \\"
    );
}

test "snapshot class private names 3.9" {
    try runSnapshot(@src(), "test/corpus/class_private_names.3.9.pyc",
        \\[]u8
        \\  "class C:
        \\    def __setstate(self):
        \\        pass
        \\    def f(self, __x):
        \\        __y = __x
        \\        return self.__y
        \\"
    );
}

test "snapshot loop try 3.9" {
    try runSnapshot(@src(), "test/corpus/loop_try.3.9.pyc",
        \\[]u8
        \\  "import time
        \\def run_bot(bot):
        \\    while True:
        \\        try:
        \\            bot.infinity_polling()
        \\        except Exception:
        \\            print('Bot polling error')
        \\            time.sleep(5)
        \\"
    );
}

test "snapshot try return cleanup 3.9" {
    try runSnapshot(@src(), "test/corpus/try_return_cleanup.3.9.pyc",
        \\[]u8
        \\  "def pick(items):
        \\    for item in items:
        \\        try:
        \\            return item
        \\        except Exception:
        \\            pass
        \\"
    );
}

test "snapshot try or 3.9" {
    try runSnapshot(@src(), "test/corpus/try_or.3.9.pyc",
        \\[]u8
        \\  "def f(a, b):
        \\    try:
        \\        if a == 1 or b == 2:
        \\            raise Exception('bad')
        \\        x = a + b
        \\        return x
        \\    except Exception as e:
        \\        print(e)
        \\"
    );
}

test "snapshot merge segments 3.9" {
    try runSnapshot(@src(), "test/corpus/merge_segments.3.9.pyc",
        \\[]u8
        \\  "def merge_segments(segments, exif = b''):
        \\    if segments[1][0:2] == b'\xff\xe0' and segments[2][0:2] == b'\xff\xe1' and segments[2][4:10] == b'Exif\x00\x00':
        \\        if exif:
        \\            segments[2] = exif
        \\            segments.pop(1)
        \\        elif exif is None:
        \\            segments.pop(2)
        \\        else:
        \\            segments.pop(1)
        \\    elif segments[1][0:2] == b'\xff\xe0':
        \\        if exif:
        \\            segments[1] = exif
        \\    elif segments[1][0:2] == b'\xff\xe1':
        \\        if segments[1][4:10] == b'Exif\x00\x00':
        \\            if exif:
        \\                segments[1] = exif
        \\            elif exif is None:
        \\                segments.pop(1)
        \\    return b''.join(segments)
        \\"
    );
}

test "snapshot guard or 3.9" {
    try runSnapshot(@src(), "test/corpus/guard_or.3.9.pyc",
        \\[]u8
        \\  "def guard(a, b):
        \\    if not (a or b):
        \\        raise ValueError('x')
        \\    return (a, b)
        \\"
    );
}

test "snapshot chained compare 3.9" {
    try runSnapshot(@src(), "test/corpus/chained_compare.3.9.pyc",
        \\[]u8
        \\  "def f(time_s):
        \\    if 0 < time_s < 2000:
        \\        y = time_s
        \\    else:
        \\        print('Error set time slice')
        \\"
    );
}
