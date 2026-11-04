//! Alphanumeric connect codes.
//! The code is 4 base-36 characters of the TCP port plus 8 secret characters.

const std = @import("std");

pub const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
pub const port_digits = 4;
pub const secret_len = 8;
pub const raw_len = port_digits + secret_len;

pub const Session = struct {
    port: u16,
    secret: [secret_len]u8,
};

pub fn writeRaw(session: Session, out: *[raw_len]u8) void {
    var n: u32 = session.port;
    var i: usize = port_digits;
    while (i > 0) {
        i -= 1;
        out[i] = alphabet[n % 36];
        n /= 36;
    }
    @memcpy(out[port_digits..], &session.secret);
}

pub fn writePretty(session: Session, out: *[raw_len + 1]u8) void {
    var raw: [raw_len]u8 = undefined;
    writeRaw(session, &raw);
    @memcpy(out[0..port_digits], raw[0..port_digits]);
    out[port_digits] = '-';
    @memcpy(out[port_digits + 1 ..], raw[port_digits..]);
}

pub fn parse(text: []const u8) !Session {
    var raw: [raw_len]u8 = undefined;
    var n: usize = 0;
    for (text) |ch| {
        if (ch == '-' or ch == ' ') continue;
        if (n >= raw.len) return error.BadCode;
        raw[n] = std.ascii.toUpper(ch);
        if (std.mem.indexOfScalar(u8, alphabet, raw[n]) == null) return error.BadCode;
        n += 1;
    }
    if (n != raw.len) return error.BadCode;

    var port: u32 = 0;
    for (raw[0..port_digits]) |ch| {
        const digit = std.mem.indexOfScalar(u8, alphabet, ch).?;
        port = port * 36 + @as(u32, @intCast(digit));
    }
    if (port == 0 or port > std.math.maxInt(u16)) return error.BadCode;

    var session = Session{
        .port = @intCast(port),
        .secret = undefined,
    };
    @memcpy(&session.secret, raw[port_digits..]);
    return session;
}

test "port roundtrip" {
    const ports = [_]u16{ 1, 36, 80, 2222, 65535 };
    for (ports) |port| {
        const session = Session{ .port = port, .secret = "ABCDEFGH".* };
        var raw: [raw_len]u8 = undefined;
        var pretty: [raw_len + 1]u8 = undefined;
        writeRaw(session, &raw);
        writePretty(session, &pretty);
        const from_raw = try parse(&raw);
        const from_pretty = try parse(&pretty);
        try std.testing.expectEqual(port, from_raw.port);
        try std.testing.expectEqual(port, from_pretty.port);
        try std.testing.expectEqualStrings(&session.secret, &from_raw.secret);
        try std.testing.expectEqualStrings(&session.secret, &from_pretty.secret);
    }
    const from_lower = try parse("0001-abcdefgh");
    try std.testing.expectEqual(@as(u16, 1), from_lower.port);
    try std.testing.expectEqualStrings("ABCDEFGH", &from_lower.secret);
}

test "reject bad codes" {
    try std.testing.expectError(error.BadCode, parse(""));
    try std.testing.expectError(error.BadCode, parse("0000-ABCDEFGH"));
    try std.testing.expectError(error.BadCode, parse("ZZZZABCDEFGH"));
    try std.testing.expectError(error.BadCode, parse("00AB-ABCDE FG"));
    try std.testing.expectError(error.BadCode, parse("00AB-ABCDEFG!"));
}
