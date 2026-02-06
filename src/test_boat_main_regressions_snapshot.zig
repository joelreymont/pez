//! Snapshot tests for boat-main regressions (3.9).

const std = @import("std");
const testing = std.testing;
const OhSnap = @import("ohsnap");

const tu = @import("test_utils.zig");

fn runSnapshot(
    comptime src: std.builtin.SourceLocation,
    path: []const u8,
    comptime expected: []const u8,
) !void {
    return runSnapshotWithAlign(src, path, expected, false);
}

fn runSnapshotWithAlign(
    comptime src: std.builtin.SourceLocation,
    path: []const u8,
    comptime expected: []const u8,
    align_defs: bool,
) !void {
    const allocator = testing.allocator;
    const output = try tu.renderPycFile(allocator, path, align_defs);
    defer allocator.free(output);

    const oh = OhSnap{};
    try oh.snap(src, expected).expectEqual(output);
}

fn runSnapshotAligned(
    comptime src: std.builtin.SourceLocation,
    path: []const u8,
    comptime expected: []const u8,
) !void {
    return runSnapshotWithAlign(src, path, expected, true);
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

test "snapshot loop guard ret 3.9" {
    try runSnapshot(@src(), "test/corpus/loop_guard_ret.3.9.pyc",
        \\[]u8
        \\  "import sys
        \\class Bdb:
        \\    def _set_stopinfo(self, *args, **kwargs):
        \\        pass
        \\    def set_continue(self):
        \\        self._set_stopinfo(self.botframe, None, -1)
        \\        if self.breaks:
        \\            return None
        \\        sys.settrace(None)
        \\        frame = sys._getframe().f_back
        \\        while frame and frame is not self.botframe:
        \\            del frame.f_trace
        \\            frame = frame.f_back
        \\"
    );
}

test "snapshot loop chain compare 3.9" {
    try runSnapshot(@src(), "test/corpus/loop_chain_compare.3.9.pyc",
        \\[]u8
        \\  "def loop_chain_compare(segments):
        \\    while b'\xff\xe0' <= segments[1][0:2] <= b'\xff\xef':
        \\        segments.pop(1)
        \\    return b''.join(segments)
        \\"
    );
}

test "snapshot lambda ifexp return 3.9" {
    try runSnapshot(@src(), "test/corpus/lambda_ifexp_return.3.9.pyc",
        \\[]u8
        \\  "def make():
        \\    return object()
        \\def build(session):
        \\    return (lambda: session if session else make())()
        \\"
    );
}
test "snapshot loop del prelude 3.9" {
    try runSnapshot(@src(), "test/corpus/loop_del_prelude.3.9.pyc",
        \\[]u8
        \\  "flag = True
        \\dbm = 0
        \\for dim in (1, 2):
        \\    dbm += dim
        \\del dbm
        \\del dim
        \\if flag:
        \\    pass
        \\"
    );
}

test "snapshot loop guard while 3.9" {
    try runSnapshot(@src(), "test/corpus/guard_loop_while.3.9.pyc",
        \\[]u8
        \\  "def guard_loop(it):
        \\    lines = []
        \\    while True:
        \\        while len(lines) < 4:
        \\            lines.append(next(it, 'X'))
        \\        s = ''.join([line[0] for line in lines])
        \\        if s.startswith('X'):
        \\            return None
        \\        yield s
        \\"
    );
}

test "snapshot try except loop scope 3.9" {
    try runSnapshot(@src(), "test/corpus/try_except_loop_scope.3.9.pyc",
        \\[]u8
        \\  "def pax_generic(pax_headers, encoding):
        \\    binary = False
        \\    for keyword, value in pax_headers.items():
        \\        try:
        \\            value.encode('utf-8', 'strict')
        \\        except UnicodeEncodeError:
        \\            binary = True
        \\    records = b''
        \\    if binary:
        \\        records += b"""21 hdrcharset=BINARY
        \\"""
        \\    return records
        \\"
    );
}

test "snapshot if merge nested 3.9" {
    try runSnapshot(@src(), "test/corpus/if_merge_nested.3.9.pyc",
        \\[]u8
        \\  "def merge_if_nested(x):
        \\    if isinstance(x, float):
        \\        if x > 0:
        \\            x = int(x)
        \\        else:
        \\            x = int(-x)
        \\    else:
        \\        x = x
        \\    return x
        \\"
    );
}

test "snapshot if guard prelude 3.9" {
    try runSnapshot(@src(), "test/corpus/if_guard_prelude.3.9.pyc",
        \\[]u8
        \\  "def if_guard_prelude(obj):
        \\    if not obj:
        \\        if obj is None:
        \\            return None
        \\        return 0
        \\    n = len(obj)
        \\    if n <= 3:
        \\        return n
        \\    return n + 1
        \\"
    );
}

test "snapshot pickle additems 3.9" {
    try runSnapshot(@src(), "test/corpus/pickle_additems.3.9.pyc",
        \\[]u8
        \\  "def load_additems(items, set_obj):
        \\    if isinstance(set_obj, set):
        \\        set_obj.update(items)
        \\    else:
        \\        add = set_obj.add
        \\        for item in items:
        \\            add(item)
        \\"
    );
}

test "snapshot if or not 3.9" {
    try runSnapshot(@src(), "test/corpus/if_or_not.3.9.pyc",
        \\[]u8
        \\  "import logging
        \\def warn(logger_level = logging.ERROR):
        \\    if not logger_level or logger_level < logging.INFO:
        \\        warning = 'W'
        \\    else:
        \\        warning = ''
        \\    return warning
        \\"
    );
}

test "snapshot if term raise 3.9" {
    try runSnapshot(@src(), "test/corpus/if_term_raise.3.9.pyc",
        \\[]u8
        \\  "import types
        \\def set_cb(obj, cb):
        \\    if isinstance(cb, types.FunctionType) or cb is None:
        \\        obj.cb = cb
        \\    else:
        \\        raise RuntimeError('cb must be None or function')
        \\"
    );
}

test "snapshot if raise else fallthrough 3.9" {
    try runSnapshot(@src(), "test/corpus/if_raise_else_fallthrough.3.9.pyc",
        \\[]u8
        \\  "def f(match):
        \\    if not match:
        \\        raise ValueError('x')
        \\    a = 1
        \\    b = 2
        \\"
    );
}

test "snapshot optparse add_option 3.9" {
    try runSnapshot(@src(), "test/corpus/optparse_add_option.3.9.pyc",
        \\[]u8
        \\  "class Option:
        \\    pass
        \\class Container:
        \\    option_class = Option
        \\    def add_option(self, *args, **kwargs):
        \\        if isinstance(args[0], str):
        \\            option = self.option_class(*args, **kwargs)
        \\        elif len(args) == 1 and not kwargs:
        \\            option = args[0]
        \\            if not isinstance(option, Option):
        \\                raise TypeError('%r' % option)
        \\        else:
        \\            raise TypeError('invalid arguments')
        \\        return option
        \\"
    );
}

test "snapshot elif tail 3.9" {
    try runSnapshot(@src(), "test/corpus/elif_tail.3.9.pyc",
        \\[]u8
        \\  "import io
        \\import socket
        \\from pathlib import Path
        \\def elif_tail(obj, file):
        \\    obj._split = False
        \\    obj._needs_close = False
        \\    if file is None:
        \\        obj._fileoutput = None
        \\    else:
        \\        if isinstance(file, str) or isinstance(file, Path):
        \\            obj._fileoutput = open(file, 'wb')
        \\            obj._needs_close = True
        \\        elif isinstance(file, io.BufferedIOBase):
        \\            obj._fileoutput = file
        \\        else:
        \\            raise RuntimeError('bad')
        \\        if hasattr(obj._fileoutput, 'raw') and isinstance(obj._fileoutput.raw, socket.SocketIO):
        \\            if obj._fileoutput.raw._sock.type == socket.SocketKind.SOCK_DGRAM:
        \\                obj._split = True
        \\"
    );
}

test "snapshot elif and not 3.9" {
    try runSnapshot(@src(), "test/corpus/elif_and_not.3.9.pyc",
        \\[]u8
        \\  "class Option:
        \\    pass
        \\def option_class(*args, **kwargs):
        \\    _ = args
        \\    _ = kwargs
        \\    return Option()
        \\class C:
        \\    option_class = option_class
        \\    def add(self, *args, **kwargs):
        \\        if isinstance(args[0], str):
        \\            option = self.option_class(*args, **kwargs)
        \\        elif len(args) == 1 and not kwargs:
        \\            option = args[0]
        \\            if not isinstance(option, Option):
        \\                raise TypeError('not an Option instance: %r' % option)
        \\        else:
        \\            raise TypeError('invalid arguments')
        \\        return option
        \\"
    );
}

test "snapshot if ret raise and 3.9" {
    try runSnapshot(@src(), "test/corpus/if_ret_raise_and.3.9.pyc",
        \\[]u8
        \\  "def if_ret_raise_and(a, x):
        \\    i = 0
        \\    if i != len(a) and a[i] == x:
        \\        return i
        \\    raise ValueError
        \\"
    );
}

test "snapshot and chain or 3.9" {
    try runSnapshot(@src(), "test/corpus/and_chain_or.3.9.pyc",
        \\[]u8
        \\  "class Breakpoint:
        \\    bplist = {}
        \\def canonic(x):
        \\    return x
        \\def and_chain_or(breaks, filename, lineno):
        \\    filename = canonic(filename)
        \\    return filename in breaks and lineno in breaks[filename] and Breakpoint.bplist[filename, lineno] or []
        \\"
    );
}

test "snapshot while not call 3.9" {
    try runSnapshot(@src(), "test/corpus/while_not_call.3.9.pyc",
        \\[]u8
        \\  "def while_not_call(ev):
        \\    out = []
        \\    while not ev.wait(0):
        \\        out.append(1)
        \\    return out
        \\"
    );
}

test "snapshot loop exit reaches header 3.9" {
    try runSnapshot(@src(), "test/corpus/loop_exit_reaches_header.3.9.pyc",
        \\[]u8
        \\  "def loop_exit_reaches_header(xs):
        \\    changed = True
        \\    while True:
        \\        changed = False
        \\        for x in xs:
        \\            if x == 0:
        \\                changed = True
        \\        if changed:
        \\            continue
        \\        return None
        \\"
    );
}

test "snapshot setup annotations prelude 3.9" {
    try runSnapshot(@src(), "test/corpus/setup_annotations_prelude.3.9.pyc",
        \\[]u8
        \\  "x: int
        \\import math
        \\xs = [1, 2, 3]
        \\for y in xs:
        \\    x = y + math.ceil(0.2)
        \\"
    );
}

test "snapshot try finally return 3.9" {
    try runSnapshot(@src(), "test/corpus/try_finally_return.3.9.pyc",
        \\[]u8
        \\  "def side_effect() -> None:
        \\    pass
        \\def try_finally_return(x):
        \\    try:
        \\        return x + 1
        \\    finally:
        \\        if x:
        \\            side_effect()
        \\"
    );
}

test "snapshot try finally ret simple 3.9" {
    try runSnapshot(@src(), "test/corpus/try_finally_ret_simple.3.9.pyc",
        \\[]u8
        \\  "def side_effect() -> None:
        \\    pass
        \\def try_finally_ret_simple(x):
        \\    try:
        \\        return x + 1
        \\    finally:
        \\        side_effect()
        \\"
    );
}

test "snapshot loop merge break 3.9" {
    try runSnapshot(@src(), "test/corpus/loop_merge_break.3.9.pyc",
        \\[]u8
        \\  "def loop_merge_break(xs):
        \\    for x in xs:
        \\        if x:
        \\            y = 1
        \\        else:
        \\            y = 2
        \\        break
        \\    else:
        \\        raise ValueError('empty')
        \\    return y
        \\"
    );
}

test "snapshot while in for 3.9" {
    try runSnapshot(@src(), "test/corpus/loop_while_in_for.3.9.pyc",
        \\[]u8
        \\  "def loop_while_in_for(items):
        \\    out = []
        \\    for name, values in items.items():
        \\        while values:
        \\            out.append(values.pop(0))
        \\    return out
        \\"
    );
}

test "snapshot for body listcomp 3.9" {
    try runSnapshot(@src(), "test/corpus/for_body_listcomp.3.9.pyc",
        \\[]u8
        \\  "import re
        \\def for_body_listcomp(actions, s):
        \\    result = []
        \\    for i in range(len(actions), 0, -1):
        \\        actions_slice = actions[:i]
        \\        pattern = ''.join([str(x) for x in actions_slice])
        \\        match = re.match(pattern, s)
        \\        if match is not None:
        \\            result.extend([len(x) for x in match.groups()])
        \\            break
        \\    return result
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

test "snapshot import star follow 3.9" {
    try runSnapshot(@src(), "test/corpus/import_star_follow.3.9.pyc",
        \\[]u8
        \\  "from mod import *
        \\from mod import a
        \\"
    );
}

test "snapshot import star elif 3.9" {
    try runSnapshot(@src(), "test/corpus/import_star_elif.3.9.pyc",
        \\[]u8
        \\  "from mod import *
        \\import sys
        \\if sys.platform == 'cli':
        \\    from mod2 import Serial
        \\else:
        \\    import os
        \\    if os.name == 'nt':
        \\        from mod3 import Serial
        \\    elif os.name == 'posix':
        \\        from mod4 import Serial
        \\    else:
        \\        raise ImportError('no impl')
        \\"
    );
}

test "snapshot for else break 3.9" {
    try runSnapshot(@src(), "test/corpus/for_else_break.3.9.pyc",
        \\[]u8
        \\  "def find_pkg(pkgs):
        \\    for pkg in pkgs:
        \\        try:
        \\            if pkg == 'ok':
        \\                break
        \\        except ImportError:
        \\            pass
        \\    else:
        \\        raise ValueError('no pkg')
        \\    return pkg
        \\"
    );
}

test "snapshot for break cleanup 3.9" {
    try runSnapshot(@src(), "test/corpus/for_break_cleanup.3.9.pyc",
        \\[]u8
        \\  "def f(parameters):
        \\    for codec in parameters.codecs:
        \\        if codec:
        \\            break
        \\"
    );
}

test "snapshot for prelude 3.9" {
    try runSnapshot(@src(), "test/corpus/for_prelude.3.9.pyc",
        \\[]u8
        \\  "def xor_bytes(data, pad):
        \\    xpad = pad
        \\    xdata = data[0:2]
        \\    for i in range(2, len(data)):
        \\        xdata += bytes([data[i] ^ xpad[i - 2]])
        \\    return xdata
        \\"
    );
}

test "snapshot for prelude kw map 3.9" {
    try runSnapshot(@src(), "test/corpus/for_prelude_kw_map.3.9.pyc",
        \\[]u8
        \\  "def g(x, **kw):
        \\    return True
        \\def f(iterable, flag = None):
        \\    kw = {'k': flag if flag is not None else True}
        \\    for item in iterable:
        \\        if g(*(item,), **kw):
        \\            yield item
        \\"
    );
}

test "snapshot for prelude nested 3.9" {
    try runSnapshot(@src(), "test/corpus/for_prelude_nested.3.9.pyc",
        \\[]u8
        \\  "def f(rows):
        \\    out = []
        \\    for row in rows:
        \\        cw = 10
        \\        names = (cw + i for i in row)
        \\        out.append(list(names))
        \\        for j in range(3):
        \\            out.append(cw + j)
        \\    return out
        \\"
    );
}

test "snapshot try finally nested 3.9" {
    try runSnapshot(@src(), "test/corpus/try_finally_nested.3.9.pyc",
        \\[]u8
        \\  "def f(arg):
        \\    try:
        \\        try:
        \\            if arg:
        \\                raise KeyboardInterrupt()
        \\        except KeyboardInterrupt:
        \\            pass
        \\    finally:
        \\        arg = False
        \\        prompt = 'ok'
        \\"
    );
}

test "snapshot try loop continue 3.9" {
    try runSnapshot(@src(), "test/corpus/loop_try_continue.3.9.pyc",
        \\[]u8
        \\  "import time
        \\def loop_try(msg):
        \\    for i in range(0, 5):
        \\        try:
        \\            print(msg)
        \\            break
        \\        except:
        \\            time.sleep(1)
        \\def tail_if(x):
        \\    if x == 1:
        \\        return None
        \\    elif x == 2:
        \\        return None
        \\    else:
        \\        try:
        \\            foo()
        \\        except Exception as e:
        \\            bar()
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

test "snapshot module global store 3.9" {
    try runSnapshot(@src(), "test/corpus/module_global_store.3.9.pyc",
        \\[]u8
        \\  "global x, y
        \\x = None
        \\y = None
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

test "snapshot ternary attr prelude 3.9" {
    try runSnapshotAligned(@src(), "test/corpus/ternary_attr_prelude.3.9.pyc",
        \\[]u8
        \\  "import asyncio
        \\RETRY_MAX = 3
        \\
        \\
        \\
        \\class Transaction:
        \\    def __init__(self, request, addr, protocol, retransmissions = None):
        \\        self.__addr = addr
        \\        self.__future = asyncio.Future()
        \\        self.__request = request
        \\        self.__protocol = protocol
        \\        self.__timeout_handle = None
        \\        self.__tries = 0
        \\        self.__timeout_delay = 1
        \\        self.__tries_max = 1 + (retransmissions if retransmissions is not None else RETRY_MAX)
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

test "snapshot loop guard cont body 3.9" {
    try runSnapshot(@src(), "test/corpus/loop_guard_cont_body.3.9.pyc",
        \\[]u8
        \\  "import time
        \\def f(flag, sock):
        \\    while True:
        \\        while flag():
        \\            time.sleep(30)
        \\        try:
        \\            sock.recv(1)
        \\        except Exception:
        \\            return None
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
        \\            continue
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

test "snapshot if or chain 3.9" {
    try runSnapshot(@src(), "test/corpus/if_or_chain.3.9.pyc",
        \\[]u8
        \\  "def f(a, b, c):
        \\    if a == '' or b == '' or c == '':
        \\        raise Exception('x')
        \\"
    );
}

test "snapshot if or term 3.9" {
    try runSnapshot(@src(), "test/corpus/if_or_term.3.9.pyc",
        \\[]u8
        \\  "def f(a, b):
        \\    if a or b:
        \\        return 1
        \\    x = 2
        \\    return x
        \\"
    );
}

test "snapshot or chain compare 3.9" {
    try runSnapshot(@src(), "test/corpus/ishex.3.9.pyc",
        \\[]u8
        \\  "def ishex(c):
        \\    assert isinstance(c, bytes)
        \\    return b'0' <= c <= b'9' or b'a' <= c <= b'f' or b'A' <= c <= b'F'
        \\"
    );
}

test "snapshot if elif else raise 3.9" {
    try runSnapshot(@src(), "test/corpus/if_elif_else_raise.3.9.pyc",
        \\[]u8
        \\  "def f(protocol):
        \\    if protocol == 4:
        \\        return 'v4'
        \\    if protocol == 6:
        \\        return 'v6'
        \\    raise ValueError('unknown protocol')
        \\"
    );
}

test "snapshot guard return 3.9" {
    try runSnapshot(@src(), "test/corpus/guard_return.3.9.pyc",
        \\[]u8
        \\  "def guard_return(x):
        \\    if not x:
        \\        return None
        \\    return 1
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
        \\    while data[i] != 0:
        \\        out.append(data[i])
        \\        i += 1
        \\    out.append(i)
        \\    return out
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

test "snapshot class if merge 3.9" {
    try runSnapshot(@src(), "test/corpus/class_if_merge.3.9.pyc",
        \\[]u8
        \\  "nt = True
        \\supports_symlinks = False
        \\class C:
        \\    if nt:
        \\        if supports_symlinks:
        \\            symlink = 1
        \\        else:
        \\            symlink = 2
        \\    else:
        \\        symlink = 3
        \\    utime = 4
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

test "snapshot and or chain 3.9" {
    try runSnapshot(@src(), "test/corpus/and_or_chain.3.9.pyc",
        \\[]u8
        \\  "def switch_role(self, ice_controlling):
        \\    self.log('Switching to %s role', ice_controlling and 'controlling' or 'controlled')
        \\"
    );
}

test "snapshot and or paren 3.9" {
    try runSnapshot(@src(), "test/corpus/and_or_paren.3.9.pyc",
        \\[]u8
        \\  "def f(a, b, c):
        \\    return a and (b or c)
        \\"
    );
}

test "snapshot doctest eq 3.9" {
    try runSnapshot(@src(), "test/corpus/doctest_eq.3.9.pyc",
        \\[]u8
        \\  "class Example:
        \\    def __init__(self, source, want, lineno, indent, options, exc_msg):
        \\        self.source = source
        \\        self.want = want
        \\        self.lineno = lineno
        \\        self.indent = indent
        \\        self.options = options
        \\        self.exc_msg = exc_msg
        \\    def __eq__(self, other):
        \\        if type(self) is not type(other):
        \\            return NotImplemented
        \\        elif self.source == other.source and self.want == other.want:
        \\            return self.lineno == other.lineno and self.indent == other.indent and self.options == other.options and self.exc_msg == other.exc_msg
        \\        return False
        \\"
    );
}

test "snapshot if else tail 3.9" {
    try runSnapshot(@src(), "test/corpus/if_else_tail.3.9.pyc",
        \\[]u8
        \\  "global logfp
        \\logfp = None
        \\def dolog(*args):
        \\    pass
        \\def nolog(*args):
        \\    pass
        \\def initlog(*args):
        \\    global log
        \\    if logfp:
        \\        log = dolog
        \\    else:
        \\        log = nolog
        \\    log(*args)
        \\"
    );
}

test "snapshot if exp binop 3.9" {
    try runSnapshot(@src(), "test/corpus/if_exp_binop.3.9.pyc",
        \\[]u8
        \\  "def f(a, b, c):
        \\    return a + (b if c else '')
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

test "snapshot float integral 3.9" {
    try runSnapshot(@src(), "test/corpus/float_integral.3.9.pyc",
        \\[]u8
        \\  "x = 10000000.0
        \\y = int(10000000.0)
        \\"
    );
}

test "snapshot set update 3.9" {
    try runSnapshot(@src(), "test/corpus/set_update.3.9.pyc",
        \\[]u8
        \\  "S = {'d', 'l', 'j', 'n', 'k', 'c', 'm', 'b', 'h', 'g', 'a', 'f', 'o', 'e', 'i'}
        \\"
    );
}

test "snapshot lambda boolop 3.9" {
    try runSnapshot(@src(), "test/corpus/lambda_boolop.3.9.pyc",
        \\[]u8
        \\  "f = lambda x: x.endswith('_codec') is False and x not in {'a', 'b', 'c'}
        \\"
    );
}

test "snapshot lambda defaults 3.9" {
    try runSnapshot(@src(), "test/corpus/lambda_defaults.3.9.pyc",
        \\[]u8
        \\  "f = lambda d = b'': d
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
        \\  "global _val
        \\import threading
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

test "snapshot with if else return 3.9" {
    try runSnapshot(@src(), "test/corpus/with_if_else_return.3.9.pyc",
        \\[]u8
        \\  "import threading
        \\_lock = threading.RLock()
        \\def f(x):
        \\    with _lock:
        \\        if x:
        \\            x = x + 1
        \\    return x
        \\"
    );
}

test "snapshot if return fallthrough 3.9" {
    try runSnapshot(@src(), "test/corpus/if_return_fallthrough.3.9.pyc",
        \\[]u8
        \\  "def f(x):
        \\    if x:
        \\        return 1
        \\    return 2
        \\"
    );
}

test "snapshot if return elif fallthrough 3.9" {
    try runSnapshot(@src(), "test/corpus/if_return_elif_fallthrough.3.9.pyc",
        \\[]u8
        \\  "def f(returncode, timeout):
        \\    if returncode is not None:
        \\        return returncode
        \\    elif timeout is not None:
        \\        a = 1
        \\    else:
        \\        b = 2
        \\    return returncode
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
        \\    return 2
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

test "snapshot try import multi 3.9" {
    try runSnapshot(@src(), "test/corpus/try_import_multi.3.9.pyc",
        \\[]u8
        \\  "try:
        \\    from mod import a as b, c as d
        \\except ImportError:
        \\    pass
        \\"
    );
}

test "snapshot try import star 3.9" {
    try runSnapshot(@src(), "test/corpus/try_import_star.3.9.pyc",
        \\[]u8
        \\  "try:
        \\    from mod import *
        \\except ImportError:
        \\    from mod2 import *
        \\"
    );
}

test "snapshot try except else after 3.9" {
    try runSnapshot(@src(), "test/corpus/try_except_else_after.3.9.pyc",
        \\[]u8
        \\  "try:
        \\    import _hashlib as _hashopenssl
        \\except ImportError:
        \\    _hashopenssl = None
        \\    _openssl_md_meths = None
        \\    from _operator import _compare_digest as compare_digest
        \\else:
        \\    _openssl_md_meths = frozenset(_hashopenssl.openssl_md_meth_names)
        \\    compare_digest = _hashopenssl.compare_digest
        \\import hashlib as _hashlib
        \\"
    );
}

test "snapshot try bool and 3.9" {
    try runSnapshot(@src(), "test/corpus/try_bool_and.3.9.pyc",
        \\[]u8
        \\  "def f(a, b):
        \\    try:
        \\        return a and b
        \\    except Exception:
        \\        return False
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

test "snapshot try except raise 3.9" {
    try runSnapshot(@src(), "test/corpus/try_except_raise.3.9.pyc",
        \\[]u8
        \\  "def try_except_raise(do):
        \\    try:
        \\        do()
        \\    except Exception:
        \\        print('err')
        \\        raise
        \\"
    );
}

test "snapshot try except raise after 3.9" {
    try runSnapshot(@src(), "test/corpus/try_except_raise_after.3.9.pyc",
        \\[]u8
        \\  "def try_except_raise_after(do):
        \\    try:
        \\        do()
        \\    except Exception:
        \\        raise RuntimeError('boom')
        \\    print('ok')
        \\"
    );
}

test "snapshot except with fallback 3.9" {
    try runSnapshot(@src(), "test/corpus/except_with_fallback.3.9.pyc",
        \\[]u8
        \\  "import json
        \\def load_config():
        \\    try:
        \\        with open('config.json', 'r') as f:
        \\            data = json.load(f)
        \\    except:
        \\        with open('config.bin', 'rb') as f:
        \\            data = json.loads(f.read().decode('utf-8'))
        \\    return data
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

test "snapshot try if after try 3.9" {
    try runSnapshot(@src(), "test/corpus/try_if_after_try.3.9.pyc",
        \\[]u8
        \\  "def upload_file(file, url, retries, delay):
        \\    for attempt in range(retries):
        \\        try:
        \\            files = {'file': file}
        \\            response = requests.post(url, files=files)
        \\            if response.status_code == 200:
        \\                print('File uploaded successfully')
        \\                return True
        \\            print(f'Failed to upload file: {response.status_code} - {response.text}')
        \\        except requests.RequestException as e:
        \\            print(f'Request failed: {e}')
        \\        time.sleep(delay)
        \\    print('All attempts failed')
        \\    return False
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
        \\    elif segments[1][0:2] == b'\xff\xe1' and segments[1][4:10] == b'Exif\x00\x00':
        \\        if exif:
        \\            segments[1] = exif
        \\        elif exif is None:
        \\            segments.pop(1)
        \\    return b''.join(segments)
        \\"
    );
}

test "snapshot guard or 3.9" {
    try runSnapshot(@src(), "test/corpus/guard_or.3.9.pyc",
        \\[]u8
        \\  "def guard(a, b):
        \\    if not a and not b:
        \\        raise ValueError('x')
        \\    return (a, b)
        \\"
    );
}

test "snapshot guard in return 3.9" {
    try runSnapshot(@src(), "test/corpus/guard_in_return.3.9.pyc",
        \\[]u8
        \\  "def guard_in_return(item, seq):
        \\    if item in seq:
        \\        return item
        \\    raise KeyError(item)
        \\"
    );
}

test "snapshot while head return 3.9" {
    try runSnapshot(@src(), "test/corpus/while_head_return.3.9.pyc",
        \\[]u8
        \\  "def while_head_return(fields, sparse, buf, read, tell):
        \\    while len(sparse) < fields * 2:
        \\        if b"""
\\""" not in buf:
        \\            buf += read()
        \\        n, buf = buf.split(b"""
\\""", 1)
        \\        sparse.append(int(n))
        \\    pos = tell()
        \\    return (pos, list(zip(sparse[::2], sparse[1::2])))
        \\"
    );
}

test "snapshot guard or return 3.9" {
    try runSnapshotAligned(@src(), "test/corpus/if_guard_or_return.3.9.pyc",
        \\[]u8
        \\  "import os
        \\
        \\
        \\def f(importer):
        \\    if importer.path is None or not os.path.isdir(importer.path):
        \\        return None
        \\    return 1
        \\"
    );
}

test "snapshot guard raise 3.9" {
    try runSnapshot(@src(), "test/corpus/if_guard_raise.3.9.pyc",
        \\[]u8
        \\  "def f(x):
        \\    if x is None:
        \\        raise ValueError('x')
        \\    return x
        \\"
    );
}

test "snapshot if else guard merge 3.9" {
    try runSnapshot(@src(), "test/corpus/if_else_guard_merge.3.9.pyc",
        \\[]u8
        \\  "def if_else_guard_merge(x):
        \\    if x:
        \\        a = 1
        \\    else:
        \\        a = 2
        \\        if a < 0:
        \\            raise ValueError('bad')
        \\    b = 3
        \\    return a + b
        \\"
    );
}

test "snapshot try for else handler 3.9" {
    try runSnapshot(@src(), "test/corpus/try_for_else_handler.3.9.pyc",
        \\[]u8
        \\  "cache = {}
        \\hooks = []
        \\def get_importer(path_item):
        \\    try:
        \\        importer = cache[path_item]
        \\    except KeyError:
        \\        for hook in hooks:
        \\            try:
        \\                importer = hook(path_item)
        \\                cache.setdefault(path_item, importer)
        \\                break
        \\            except ImportError:
        \\                pass
        \\        else:
        \\            importer = None
        \\    return importer
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

test "snapshot chained compare and 3.9" {
    try runSnapshot(@src(), "test/corpus/chained_compare_and.3.9.pyc",
        \\[]u8
        \\  "def f(limit, _read):
        \\    if limit is not None and 0 <= limit <= _read:
        \\        return True
        \\    return False
        \\"
    );
}

test "snapshot loop tail guard 3.9" {
    try runSnapshotAligned(@src(), "test/corpus/loop_tail_guard.3.9.pyc",
        \\[]u8
        \\  "from typing import List
        \\
        \\def scan(vals: List[int]) -> int:
        \\    pos = 0
        \\    while pos < len(vals):
        \\        v = vals[pos]
        \\        if v == 0:
        \\            if v != vals[0]:
        \\                raise ValueError('bad0')
        \\        elif v == 1:
        \\            if v != vals[1]:
        \\                raise ValueError('bad1')
        \\        pos += 1
        \\    return pos
        \\"
    );
}

test "snapshot try if merge 3.9" {
    try runSnapshotAligned(@src(), "test/corpus/try_if_merge.3.9.pyc",
        \\[]u8
        \\  "def g():
        \\    pass
        \\
        \\
        \\def f(flag, other):
        \\    if flag:
        \\        x = 1
        \\    elif other:
        \\        try:
        \\            g()
        \\        except ValueError:
        \\            return None
        \\        else:
        \\            x = 2
        \\    return x
        \\"
    );
}

test "snapshot loop for prelude 3.9" {
    try runSnapshotAligned(@src(), "test/corpus/loop_for_prelude.3.9.pyc",
        \\[]u8
        \\  "import asyncio
        \\
        \\
        \\async def loop_for_prelude(obj):
        \\    while True:
        \\        await asyncio.sleep(0.1)
        \\        for item in obj.items():
        \\            pass
        \\"
    );
}

test "snapshot kwonly defaults 3.9" {
    try runSnapshot(@src(), "test/corpus/kwonly_defaults.3.9.pyc",
        \\[]u8
        \\  "class C:
        \\    def __init__(self, *args, max_length = None, **kwargs):
        \\        pass
        \\"
    );
}

test "snapshot loop try break 3.9" {
    try runSnapshot(@src(), "test/corpus/loop_try_break.3.9.pyc",
        \\[]u8
        \\  "def read(fp, decomp, trailing_error):
        \\    data = None
        \\    while True:
        \\        rawblock = fp.read(4)
        \\        if not rawblock:
        \\            break
        \\        try:
        \\            data = decomp.decompress(rawblock, 1)
        \\        except trailing_error:
        \\            break
        \\        if data:
        \\            break
        \\    return data
        \\"
    );
}

test "snapshot loop break guard 3.9" {
    try runSnapshotAligned(@src(), "test/corpus/loop_break_guard.3.9.pyc",
        \\[]u8
        \\  "class _Base:
        \\    pass
        \\
        \\class Generic:
        \\    pass
        \\
        \\
        \\def f(bases, i):
        \\    for b in bases[i + 1:]:
        \\        if isinstance(b, _Base) or issubclass(b, Generic):
        \\            break
        \\"
    );
}

test "snapshot or break guard 3.9" {
    try runSnapshot(@src(), "test/corpus/or_break_guard.3.9.pyc",
        \\[]u8
        \\  "def or_break_guard(timeout, val, buf):
        \\    i = 0
        \\    while i < 1:
        \\        i += 1
        \\        if timeout.expired() or val is not None and val > 0 and not buf:
        \\            break
        \\"
    );
}

test "snapshot if or else platform 3.9" {
    try runSnapshot(@src(), "test/corpus/if_or_else_platform.3.9.pyc",
        \\[]u8
        \\  "import platform
        \\if platform.system() == 'Darwin' or 'BSD' in platform.system():
        \\    x = 1
        \\else:
        \\    x = 2
        \\"
    );
}

test "snapshot rot2 pair 3.9" {
    try runSnapshot(@src(), "test/corpus/rot2_pair.3.9.pyc",
        \\[]u8
        \\  "def rot2_pair(args):
        \\    optstring, args = (args[0], args[1:])
        \\    optarg, optstring = (optstring, '')
        \\    return (optarg, optstring, args)
        \\"
    );
}

test "snapshot async try except finally cleanup 3.9" {
    try runSnapshot(@src(), "test/corpus/async_try_except_finally_cleanup.3.9.pyc",
        \\[]u8
        \\  "import asyncio
        \\async def async_try_except_finally_cleanup(name, queries, future, timeout):
        \\    try:
        \\        return await asyncio.wait_for(future, timeout=timeout)
        \\    except asyncio.TimeoutError:
        \\        return None
        \\    finally:
        \\        if name in queries:
        \\            queries[name].discard(future)
        \\            if not queries[name]:
        \\                del queries[name]
        \\"
    );
}

test "snapshot telebot annotations getattr 3.9" {
    try runSnapshot(@src(), "test/corpus/telebot_annotations_getattr.3.9.pyc",
        \\[]u8
        \\  "from __future__ import annotations
        \\from typing import Dict, List
        \\class ChatMemberUpdated:
        \\    @property
        \\    def difference(self) -> Dict[str, List]:
        \\        return {}
        \\class InaccessibleMessage:
        \\    @staticmethod
        \\    def __universal_deprecation(property_name):
        \\        return property_name
        \\    def __getattr__(self, item):
        \\        if item in ('message_thread_id', 'from_user', 'reply_to_message'):
        \\            return self.__universal_deprecation(item)
        \\        raise AttributeError(f'"{self.__class__.__name__}" object has no attribute "{item}"')
        \\"
    );
}

test "snapshot glob flow 3.9" {
    try runSnapshot(@src(), "test/corpus/glob_flow.3.9.pyc",
        \\[]u8
        \\  "def iglob_like(pathname, recursive = False):
        \\    it = iter((0,))
        \\    if recursive and pathname:
        \\        s = next(it)
        \\        assert not s
        \\    return it
        \\def _ishidden(path):
        \\    return path[0] == '.'
        \\def rlistdir_like(names):
        \\    for x in names:
        \\        if not _ishidden(x):
        \\            yield x
        \\            path = x
        \\            for y in rlistdir_like(path):
        \\                yield y
        \\"
    );
}

test "snapshot dictcomp conditional value 3.9" {
    try runSnapshot(@src(), "test/corpus/dictcomp_conditional_value.3.9.pyc",
        \\[]u8
        \\  "def f(d):
        \\    return {x: y.__dict__ if hasattr(y, '__dict__') else y for x, y in d.items()}
        \\def g(new, old):
        \\    out = {}
        \\    for key in new:
        \\        if key == 'user':
        \\            continue
        \\        if new[key] != old[key]:
        \\            out[key] = [old[key], new[key]]
        \\    return out
        \\"
    );
}
