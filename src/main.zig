//! Share a shell between two terminals.
//!
//! Terminal A runs `host`, which opens a port and prints an alphanumeric
//! connect code. Terminal B runs `join` with that code and becomes the shell.

const std = @import("std");
const code = @import("toggle_surf");

const c = std.c;
const posix = std.posix;

const max_payload: usize = 4096;
const kind_data: u8 = 1;
const kind_winsize: u8 = 2;
const kind_close: u8 = 3;
const detach_byte: u8 = 0x1d; // Ctrl-]

const TIOCSWINSZ: usize = if (@hasDecl(c.T, "IOCSWINSZ"))
    c.T.IOCSWINSZ
else
    ioc(0x80000000, 't', 103, @sizeOf(c.winsize));
const TIOCSCTTY: usize = if (@hasDecl(c.T, "IOCSCTTY"))
    c.T.IOCSCTTY
else
    ioc(0x20000000, 't', 97, 0);

extern "c" fn openpty(
    amaster: *c_int,
    aslave: *c_int,
    name: ?[*:0]u8,
    termp: ?*c.termios,
    winp: ?*c.winsize,
) c_int;
extern "c" fn setsid() c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn ioctl(fd: c_int, request: usize, ...) c_int;
extern "c" fn kill(pid: c.pid_t, sig: c_int) c_int;
extern "c" fn posix_spawn_file_actions_init(actions: *?*anyopaque) c_int;
extern "c" fn posix_spawn_file_actions_destroy(actions: *?*anyopaque) c_int;
extern "c" fn posix_spawn_file_actions_adddup2(actions: *?*anyopaque, from: c_int, to: c_int) c_int;
extern "c" fn posix_spawn_file_actions_addclose(actions: *?*anyopaque, fd: c_int) c_int;
extern "c" fn posix_spawnp(
    pid: *c.pid_t,
    file: [*:0]const u8,
    file_actions: *?*anyopaque,
    attrp: ?*anyopaque,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) c_int;

var session_pid = std.atomic.Value(c.pid_t).init(0);

pub fn main(init: std.process.Init) void {
    const argv = init.minimal.args.vector;
    if (argv.len >= 4 and argEq(argv[1], "--pty-exec")) {
        ptyChild(argOf(argv[2]), argOf(argv[3]));
    }
    command(init) catch |err| {
        eprint("togglesurf: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn command(init: std.process.Init) !void {
    const argv = init.minimal.args.vector;
    if (argv.len < 2) {
        usage(argOf(argv[0]));
        std.process.exit(1);
    }

    var action: ?enum { host, join, help } = null;
    var connect: ?[:0]const u8 = null;
    var host: [:0]const u8 = "127.0.0.1";
    var port: u16 = 0;
    var lan = false;
    var shell_buf: [256]u8 = undefined;
    var shell: [:0]const u8 = try defaultShell(init.environ_map, &shell_buf);

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const item = argOf(argv[i]);
        if (argEq(argv[i], "--help") or argEq(argv[i], "-h")) {
            action = .help;
        } else if (argEq(argv[i], "--lan")) {
            lan = true;
        } else if (argEq(argv[i], "--port")) {
            i += 1;
            if (i >= argv.len) return error.MissingPort;
            port = std.fmt.parseInt(u16, argOf(argv[i]), 10) catch return error.BadPort;
        } else if (argEq(argv[i], "--host")) {
            i += 1;
            if (i >= argv.len) return error.MissingHost;
            host = argOf(argv[i]);
        } else if (argEq(argv[i], "--shell")) {
            i += 1;
            if (i >= argv.len) return error.MissingShell;
            shell = argOf(argv[i]);
        } else if (std.mem.startsWith(u8, item, "--")) {
            return error.UnknownFlag;
        } else if (argEq(argv[i], "host") or argEq(argv[i], "join")) {
            if (action != null) return error.ExtraArgument;
            action = if (argEq(argv[i], "host")) .host else .join;
        } else if (connect == null) {
            connect = item;
        } else return error.ExtraArgument;
    }

    switch (action orelse .help) {
        .help => {
            usage(argOf(argv[0]));
            return;
        },
        .host => {
            if (connect != null) return error.ExtraArgument;
            if (shell.len == 0 or shell[0] != '/') return error.ShellMustBeAbsolute;
            try hostSession(init.io, argOf(argv[0]), shell, port, lan);
        },
        .join => {
            const token = connect orelse return error.MissingCode;
            try joinSession(init.io, init.environ_map, host, token);
        },
    }
}

fn usage(exe: []const u8) void {
    eprint(
        \\togglesurf — shell across two terminals
        \\
        \\  {s} host [--port N] [--lan] [--shell /absolute/path]
        \\  {s} join CODE [--host ADDR]
        \\
        \\host opens a port and prints an alphanumeric connect code.
        \\join, in the other terminal, uses that code and becomes the shell.
        \\Detach the join terminal with Ctrl-]. Ctrl-C on the host closes it.
        \\
        \\The code is the password. Without --lan the port stays on localhost.
        \\--host accepts an IPv4 or IPv6 address.
        \\
    , .{ exe, exe });
}

fn hostSession(
    io: std.Io,
    exe: [:0]const u8,
    shell: [:0]const u8,
    requested_port: u16,
    lan: bool,
) !void {
    ignoreSigPipe();
    installHostSignals();

    var listener = Listener{ .io = io };
    try listener.bind(requested_port, lan);
    defer listener.close();

    const bound_port = listener.port();
    var secret: [code.secret_len]u8 = undefined;
    try fillSecret(io, &secret);
    const session = code.Session{ .port = bound_port, .secret = secret };
    var pretty: [code.raw_len + 1]u8 = undefined;
    code.writePretty(session, &pretty);

    for (listener.servers[0..listener.count]) |server| {
        var shown: [128]u8 = undefined;
        eprint("listening on {s}\n", .{formatAddress(server.socket.address, &shown)});
    }
    eprint("CONNECT {s}\n", .{pretty});
    eprint("\nother terminal:\n  {s} join {s}\n", .{ exe, pretty });
    if (lan) {
        eprint("from another machine, add --host <IPv4-or-IPv6>\n", .{});
        eprint("the connect code is the password for the shell\n", .{});
    }
    eprint("\nwaiting for the other terminal...\n", .{});

    while (true) {
        const stream = try listener.accept();
        defer stream.close(io);
        setNoDelay(stream.socket.handle);

        var rows: u16 = 24;
        var cols: u16 = 80;
        var term_buf: [32]u8 = undefined;
        const term = handshake(stream.socket.handle, &secret, &rows, &cols, &term_buf) catch |err| {
            eprint("connection dropped before auth ({s})\n", .{@errorName(err)});
            continue;
        } orelse {
            eprint("rejected a connection\n", .{});
            continue;
        };

        listener.close();
        eprint("peer connected — the shell is in the other terminal\n", .{});
        try serveShell(exe, shell, stream.socket.handle, rows, cols, term);
        eprint("session closed\n", .{});
        return;
    }
}

fn serveShell(
    exe: [:0]const u8,
    shell: [:0]const u8,
    sock: posix.fd_t,
    rows: u16,
    cols: u16,
    term: [:0]const u8,
) !void {
    var ws = c.winsize{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
    var master: c_int = -1;
    var slave: c_int = -1;
    if (openpty(&master, &slave, null, null, &ws) != 0) return error.OpenPty;
    defer {
        if (master >= 0) _ = c.close(master);
    }
    const held = c.dup(slave);
    _ = c.close(slave);
    if (held < 0) return error.Dup;
    // Drop the parent's copy once the child has the slave. Leaving it open
    // keeps the pty alive after the shell exits, so the host never sees EOF.
    var parent_slave: c_int = held;
    errdefer {
        if (parent_slave >= 0) _ = c.close(parent_slave);
    }

    const pid = try spawnShell(exe, shell, term, master, parent_slave);
    _ = c.close(parent_slave);
    parent_slave = -1;
    session_pid.store(pid, .release);
    defer stopChild();
    try relayHost(sock, master, pid);
}

fn spawnShell(
    exe: [:0]const u8,
    shell: [:0]const u8,
    term: [:0]const u8,
    master: c_int,
    slave: c_int,
) !c.pid_t {
    var actions: ?*anyopaque = null;
    if (posix_spawn_file_actions_init(&actions) != 0) return error.SpawnFailed;
    defer _ = posix_spawn_file_actions_destroy(&actions);

    if (posix_spawn_file_actions_adddup2(&actions, slave, 0) != 0) return error.SpawnFailed;
    if (posix_spawn_file_actions_adddup2(&actions, slave, 1) != 0) return error.SpawnFailed;
    if (posix_spawn_file_actions_adddup2(&actions, slave, 2) != 0) return error.SpawnFailed;
    if (slave > 2 and posix_spawn_file_actions_addclose(&actions, slave) != 0) return error.SpawnFailed;
    if (posix_spawn_file_actions_addclose(&actions, master) != 0) return error.SpawnFailed;

    const argv = [_:null]?[*:0]const u8{
        exe.ptr,
        "--pty-exec",
        shell.ptr,
        term.ptr,
    };
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(c.environ);
    var pid: c.pid_t = 0;
    const rc = posix_spawnp(&pid, exe.ptr, &actions, null, &argv, envp);
    if (rc != 0) {
        eprint("could not start the shell (posix_spawn {d})\n", .{rc});
        return error.SpawnFailed;
    }
    return pid;
}

fn ptyChild(shell: [:0]const u8, term: [:0]const u8) noreturn {
    _ = setsid();
    _ = ioctl(0, TIOCSCTTY, @as(c_int, 0));
    _ = setenv("TERM", term.ptr, 1);
    const argv = [_:null]?[*:0]const u8{ shell.ptr, "-l" };
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(c.environ);
    _ = c.execve(shell.ptr, &argv, envp);
    const msg = "togglesurf: shell failed to start\r\n";
    _ = c.write(2, msg, msg.len);
    c._exit(127);
}

fn joinSession(
    io: std.Io,
    env: *std.process.Environ.Map,
    host: []const u8,
    token: []const u8,
) !void {
    ignoreSigPipe();
    const session = code.parse(token) catch {
        eprint("connect code is not valid\n", .{});
        std.process.exit(1);
    };
    const addr = std.Io.net.IpAddress.resolve(io, stripBrackets(host), session.port) catch {
        eprint("host must be an IPv4 or IPv6 address\n", .{});
        std.process.exit(1);
    };
    const stream = addr.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch |err| {
        if (err == error.ConnectionRefused) {
            var shown: [128]u8 = undefined;
            eprint("nothing is listening on {s}\n", .{formatAddress(addr, &shown)});
            eprint("start togglesurf host in the other terminal first\n", .{});
            std.process.exit(1);
        }
        return err;
    };
    defer stream.close(io);
    setNoDelay(stream.socket.handle);

    const tty = c.isatty(0) != 0;
    var rows: u16 = 24;
    var cols: u16 = 80;
    if (tty) {
        const ws = getWinsize(0);
        rows = ws.row;
        cols = ws.col;
    }
    var term_buf: [32]u8 = undefined;
    const term = sanitizeTerm(env.get("TERM") orelse "xterm-256color", &term_buf);

    var hello: [128]u8 = undefined;
    const line = std.fmt.bufPrint(
        &hello,
        "SURF1 {s} {d} {d} {s}\n",
        .{ session.secret[0..], rows, cols, term },
    ) catch return error.LineTooLong;
    try writeAll(stream.socket.handle, line);

    var reply_buf: [16]u8 = undefined;
    const reply = try readLine(stream.socket.handle, &reply_buf);
    if (!std.mem.eql(u8, reply, "OK")) {
        eprint("the other terminal rejected this connect code\n", .{});
        std.process.exit(1);
    }

    if (tty) {
        var shown: [128]u8 = undefined;
        eprint("connected to {s}\n", .{formatAddress(addr, &shown)});
        eprint("this terminal is the shell. detach with Ctrl-]\n", .{});
    }
    try relayClient(stream.socket.handle, tty, rows, cols);
}

fn handshake(
    sock: posix.fd_t,
    secret: *const [code.secret_len]u8,
    rows: *u16,
    cols: *u16,
    term_buf: *[32]u8,
) !?[:0]const u8 {
    var buf: [128]u8 = undefined;
    const line = readLine(sock, &buf) catch return null;
    var rest: []const u8 = line;
    const magic = nextToken(&rest) orelse {
        try writeAll(sock, "NO\n");
        return null;
    };
    const got_secret = nextToken(&rest) orelse {
        try writeAll(sock, "NO\n");
        return null;
    };
    const row_text = nextToken(&rest) orelse {
        try writeAll(sock, "NO\n");
        return null;
    };
    const col_text = nextToken(&rest) orelse {
        try writeAll(sock, "NO\n");
        return null;
    };
    const term_text = nextToken(&rest) orelse {
        try writeAll(sock, "NO\n");
        return null;
    };
    if (!std.mem.eql(u8, magic, "SURF1") or !secretMatches(got_secret, secret)) {
        try writeAll(sock, "NO\n");
        return null;
    }
    rows.* = std.fmt.parseInt(u16, row_text, 10) catch 24;
    cols.* = std.fmt.parseInt(u16, col_text, 10) catch 80;
    if (rows.* == 0) rows.* = 24;
    if (cols.* == 0) cols.* = 80;
    try writeAll(sock, "OK\n");
    return sanitizeTerm(term_text, term_buf);
}

fn relayHost(sock: posix.fd_t, master: c_int, child: c.pid_t) !void {
    var pending: [8192]u8 = undefined;
    var pending_len: usize = 0;
    var chunk: [max_payload]u8 = undefined;

    while (true) {
        var fds = [_]posix.pollfd{
            .{ .fd = master, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = sock, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = try posix.poll(&fds, -1);

        if (isReady(fds[0].revents)) {
            const got = readSome(master, &chunk) catch return error.PtyRead;
            if (got == null) {
                writeFrame(sock, kind_close, &.{}) catch {};
                return;
            }
            try writeFrame(sock, kind_data, got.?);
        }

        if (isReady(fds[1].revents)) {
            const space = pending[pending_len..];
            if (space.len == 0) return error.BadFrame;
            const got = try readSome(sock, space);
            if (got == null) return;
            pending_len += got.?.len;
            while (try pullFrame(pending[0..pending_len])) |frame| {
                switch (frame.kind) {
                    kind_data => try writeAll(master, frame.payload),
                    kind_winsize => {
                        if (frame.payload.len != 4) return error.BadFrame;
                        const win_rows = readU16(frame.payload[0..2]);
                        const win_cols = readU16(frame.payload[2..4]);
                        setWinsize(master, win_rows, win_cols);
                        _ = kill(child, @intFromEnum(c.SIG.WINCH));
                    },
                    kind_close => return,
                    else => return error.BadFrame,
                }
                const total = 3 + frame.payload.len;
                consume(&pending, &pending_len, total);
            }
        }
    }
}

fn relayClient(sock: posix.fd_t, tty: bool, rows_init: u16, cols_init: u16) !void {
    const previous = if (tty) posix.tcgetattr(0) catch null else null;
    if (previous) |term| {
        var raw = term;
        makeRaw(&raw);
        posix.tcsetattr(0, .NOW, raw) catch {};
    }
    defer if (previous) |term| {
        posix.tcsetattr(0, .NOW, term) catch {};
    };

    var rows = rows_init;
    var cols = cols_init;
    var pending: [8192]u8 = undefined;
    var pending_len: usize = 0;
    var chunk: [max_payload]u8 = undefined;
    var stdin_open = true;

    while (true) {
        var fds = [_]posix.pollfd{
            .{ .fd = if (stdin_open) @as(posix.fd_t, 0) else -1, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = sock, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = try posix.poll(&fds, if (tty) 200 else -1);

        if (tty) {
            const ws = getWinsize(0);
            if (ws.row != rows or ws.col != cols) {
                rows = ws.row;
                cols = ws.col;
                var body: [4]u8 = undefined;
                writeU16(body[0..2], rows);
                writeU16(body[2..4], cols);
                try writeFrame(sock, kind_winsize, &body);
            }
        }

        if (stdin_open and isReady(fds[0].revents)) {
            const got = try readSome(0, &chunk);
            if (got == null) {
                stdin_open = false;
                // Deliver end-of-file to the remote shell, then keep its output.
                writeDataFrames(sock, "\x04") catch {};
                continue;
            }
            if (try sendInput(sock, got.?)) return;
        }

        if (isReady(fds[1].revents)) {
            const space = pending[pending_len..];
            if (space.len == 0) return error.BadFrame;
            const got = try readSome(sock, space);
            if (got == null) return;
            pending_len += got.?.len;
            while (try pullFrame(pending[0..pending_len])) |frame| {
                switch (frame.kind) {
                    kind_data => try writeAll(1, frame.payload),
                    kind_close => return,
                    kind_winsize => {},
                    else => return error.BadFrame,
                }
                consume(&pending, &pending_len, 3 + frame.payload.len);
            }
        }
    }
}

fn sendInput(sock: posix.fd_t, bytes: []const u8) !bool {
    if (std.mem.indexOfScalar(u8, bytes, detach_byte)) |at| {
        if (at > 0) try writeDataFrames(sock, bytes[0..at]);
        try writeFrame(sock, kind_close, &.{});
        return true;
    }
    try writeDataFrames(sock, bytes);
    return false;
}

const Frame = struct {
    kind: u8,
    payload: []const u8,
};

fn pullFrame(buf: []const u8) !?Frame {
    if (buf.len < 3) return null;
    const size = readU16(buf[1..3]);
    if (size > max_payload) return error.BadFrame;
    const total = 3 + @as(usize, size);
    if (buf.len < total) return null;
    return .{ .kind = buf[0], .payload = buf[3..total] };
}

fn consume(buf: []u8, len: *usize, total: usize) void {
    const rest = len.* - total;
    std.mem.copyForwards(u8, buf[0..rest], buf[total..][0..rest]);
    len.* = rest;
}

fn writeDataFrames(sock: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = @min(max_payload, bytes.len - off);
        try writeFrame(sock, kind_data, bytes[off..][0..n]);
        off += n;
    }
}

fn writeFrame(fd: posix.fd_t, kind: u8, payload: []const u8) !void {
    var hdr: [3]u8 = undefined;
    hdr[0] = kind;
    writeU16(hdr[1..3], @intCast(payload.len));
    try writeAll(fd, &hdr);
    try writeAll(fd, payload);
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .big);
}

fn writeU16(bytes: []u8, value: u16) void {
    std.mem.writeInt(u16, bytes[0..2], value, .big);
}

fn readLine(fd: posix.fd_t, buf: []u8) ![]u8 {
    var n: usize = 0;
    while (n < buf.len) {
        var byte: [1]u8 = undefined;
        const got = try readSome(fd, &byte);
        if (got == null) return error.EndOfStream;
        if (byte[0] == '\n') return buf[0..n];
        if (byte[0] != '\r') {
            buf[n] = byte[0];
            n += 1;
        }
    }
    return error.LineTooLong;
}

/// Null means the stream closed. PTY masters return EIO when the slave goes away.
fn readSome(fd: posix.fd_t, buf: []u8) !?[]u8 {
    while (true) {
        const n = c.read(fd, buf.ptr, buf.len);
        if (n < 0) {
            switch (posix.errno(n)) {
                .INTR => continue,
                .IO, .PIPE => return null,
                else => return error.ReadFailed,
            }
        }
        if (n == 0) return null;
        return buf[0..@intCast(n)];
    }
}

fn writeAll(fd: posix.fd_t, buf: []const u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = c.write(fd, buf[off..].ptr, buf.len - off);
        if (n < 0) {
            switch (posix.errno(n)) {
                .INTR => continue,
                .PIPE, .IO => return error.BrokenPipe,
                else => return error.WriteFailed,
            }
        }
        if (n == 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

fn fillSecret(io: std.Io, out: *[code.secret_len]u8) !void {
    var i: usize = 0;
    var block: [32]u8 = undefined;
    while (i < out.len) {
        io.randomSecure(&block) catch io.random(&block);
        for (block) |byte| {
            if (byte >= 252) continue;
            out[i] = code.alphabet[byte % 36];
            i += 1;
            if (i == out.len) return;
        }
    }
}

fn secretMatches(got: []const u8, expect: *const [code.secret_len]u8) bool {
    if (got.len != expect.len) return false;
    var diff: u8 = 0;
    for (got, expect) |a, b| diff |= std.ascii.toUpper(a) ^ b;
    return diff == 0;
}

fn sanitizeTerm(src: []const u8, buf: *[32]u8) [:0]const u8 {
    const fallback = "xterm-256color";
    var use_fallback = src.len == 0 or src.len >= buf.len;
    if (!use_fallback) {
        for (src) |ch| {
            const ok = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.';
            if (!ok) {
                use_fallback = true;
                break;
            }
        }
    }
    const chosen = if (use_fallback) fallback else src;
    @memcpy(buf[0..chosen.len], chosen);
    buf[chosen.len] = 0;
    return buf[0..chosen.len :0];
}

fn defaultShell(env: *std.process.Environ.Map, buf: *[256]u8) ![:0]const u8 {
    const from_env = env.get("SHELL") orelse "/bin/sh";
    if (from_env.len == 0 or from_env.len + 1 > buf.len or from_env[0] != '/') {
        const fallback = "/bin/sh";
        @memcpy(buf[0..fallback.len], fallback);
        buf[fallback.len] = 0;
        return buf[0..fallback.len :0];
    }
    @memcpy(buf[0..from_env.len], from_env);
    buf[from_env.len] = 0;
    return buf[0..from_env.len :0];
}

fn nextToken(rest: *[]const u8) ?[]const u8 {
    const src = rest.*;
    var i: usize = 0;
    while (i < src.len and src[i] == ' ') i += 1;
    if (i >= src.len) return null;
    const start = i;
    while (i < src.len and src[i] != ' ') i += 1;
    rest.* = src[i..];
    return src[start..i];
}

fn setNoDelay(fd: posix.fd_t) void {
    const one: c_int = 1;
    posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&one)) catch {};
}

fn getWinsize(fd: c_int) c.winsize {
    var ws = c.winsize{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    _ = ioctl(fd, c.T.IOCGWINSZ, &ws);
    if (ws.row == 0) ws.row = 24;
    if (ws.col == 0) ws.col = 80;
    return ws;
}

fn setWinsize(fd: c_int, rows: u16, cols: u16) void {
    var ws = c.winsize{
        .row = if (rows == 0) 24 else rows,
        .col = if (cols == 0) 80 else cols,
        .xpixel = 0,
        .ypixel = 0,
    };
    _ = ioctl(fd, TIOCSWINSZ, &ws);
}

fn makeRaw(term: *c.termios) void {
    term.iflag.IGNBRK = false;
    term.iflag.BRKINT = false;
    term.iflag.PARMRK = false;
    term.iflag.ISTRIP = false;
    term.iflag.INLCR = false;
    term.iflag.IGNCR = false;
    term.iflag.ICRNL = false;
    term.iflag.IXON = false;
    term.oflag.OPOST = false;
    term.lflag.ECHO = false;
    term.lflag.ECHONL = false;
    term.lflag.ICANON = false;
    term.lflag.ISIG = false;
    term.lflag.IEXTEN = false;
    term.cflag.CSIZE = .CS8;
    term.cflag.PARENB = false;
    term.cc[@intFromEnum(posix.V.MIN)] = 1;
    term.cc[@intFromEnum(posix.V.TIME)] = 0;
}

fn isReady(events: i16) bool {
    const bits: u16 = @bitCast(events);
    const mask: u16 = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR;
    return bits & mask != 0;
}

fn ignoreSigPipe() void {
    var act = c.Sigaction{
        .handler = .{ .handler = c.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.PIPE, &act, null);
}

fn installHostSignals() void {
    var act = c.Sigaction{
        .handler = .{ .handler = onHostSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.INT, &act, null);
    posix.sigaction(.TERM, &act, null);
}

fn onHostSignal(_: c.SIG) callconv(.c) void {
    const pid = session_pid.load(.acquire);
    if (pid > 0) _ = kill(-pid, @intFromEnum(c.SIG.HUP));
    c._exit(1);
}

fn stopChild() void {
    const pid = session_pid.swap(0, .acq_rel);
    if (pid <= 0) return;
    _ = kill(-pid, @intFromEnum(c.SIG.HUP));
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
}

fn stripBrackets(host: []const u8) []const u8 {
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') return host[1 .. host.len - 1];
    return host;
}

fn formatAddress(addr: std.Io.net.IpAddress, buf: []u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    addr.format(&writer) catch return "";
    return writer.buffered();
}

const Listener = struct {
    servers: [2]std.Io.net.Server = undefined,
    count: usize = 0,
    io: std.Io,

    fn bind(self: *Listener, requested_port: u16, lan: bool) !void {
        const v6: std.Io.net.IpAddress = .{ .ip6 = if (lan)
            std.Io.net.Ip6Address.unspecified(requested_port)
        else
            std.Io.net.Ip6Address.loopback(requested_port) };
        const v4: std.Io.net.IpAddress = .{ .ip4 = if (lan)
            std.Io.net.Ip4Address.unspecified(requested_port)
        else
            std.Io.net.Ip4Address.loopback(requested_port) };

        // IPv6 first. On dual-stack systems this also covers IPv4, and the
        // following IPv4 bind then fails with AddressInUse, which is fine.
        self.tryAdd(v6) catch |err| switch (err) {
            error.AddressFamilyUnsupported, error.AddressUnavailable, error.ProtocolUnsupportedBySystem => {},
            else => return err,
        };
        var v4_addr = v4;
        if (self.count > 0) v4_addr.setPort(self.port());
        self.tryAdd(v4_addr) catch |err| switch (err) {
            error.AddressInUse, error.AddressFamilyUnsupported, error.AddressUnavailable => {},
            else => return err,
        };
        if (self.count == 0) return error.AddressUnavailable;
    }

    fn tryAdd(self: *Listener, addr: std.Io.net.IpAddress) !void {
        self.servers[self.count] = try addr.listen(self.io, .{ .reuse_address = true });
        self.count += 1;
    }

    fn port(self: *const Listener) u16 {
        return self.servers[0].socket.address.getPort();
    }

    fn accept(self: *Listener) !std.Io.net.Stream {
        while (true) {
            var fds: [2]posix.pollfd = undefined;
            for (self.servers[0..self.count], 0..) |server, i| {
                fds[i] = .{ .fd = server.socket.handle, .events = posix.POLL.IN, .revents = 0 };
            }
            _ = try posix.poll(fds[0..self.count], -1);
            for (fds[0..self.count], 0..) |pfd, i| {
                if (!isReady(pfd.revents)) continue;
                return self.servers[i].accept(self.io) catch |err| switch (err) {
                    error.WouldBlock, error.ConnectionAborted => continue,
                    else => return err,
                };
            }
        }
    }

    fn close(self: *Listener) void {
        for (self.servers[0..self.count]) |*server| server.deinit(self.io);
        self.count = 0;
    }
};

fn ioc(inout: usize, group: usize, num: usize, len: usize) usize {
    const parm_mask: usize = 0x1fff;
    return inout | ((len & parm_mask) << 16) | (group << 8) | num;
}

fn argOf(p: [*:0]const u8) [:0]const u8 {
    return std.mem.sliceTo(p, 0);
}

fn argEq(p: [*:0]const u8, text: []const u8) bool {
    return std.mem.eql(u8, argOf(p), text);
}

fn eprint(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "togglesurf: message too long\n";
    writeAll(2, msg) catch {};
}
