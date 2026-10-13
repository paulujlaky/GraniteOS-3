//! DNS queries for a name's IPv4 address, and reading the answer, as RFC 1035 lays them out.

const std = @import("std");

const wire = @import("wire.zig");

pub const port = 53;

pub const Answer = union(enum) {

    /// The address, and the seconds it may be kept.
    found: struct { address: u32, ttl: u32 },

    /// The name does not exist, or has no IPv4 address.
    missing,

    /// The server could not answer.
    failed,

};

/// Writes a recursive query for `name`'s A record to `out`; returns its length, or null for a name DNS cannot carry.
pub fn query(out: []u8, id: u16, name: []const u8) ?usize {

    const trimmed = if (name.len != 0 and name[name.len - 1] == '.') name[0 .. name.len - 1] else name;
    if (trimmed.len == 0 or trimmed.len > 253 or out.len < 12 + trimmed.len + 6) return null;

    @memset(out[0..12], 0);
    wire.put(u16, out[0..2], id);
    wire.put(u16, out[2..4], 0x0100);
    wire.put(u16, out[4..6], 1);

    var at: usize = 12;
    var labels = std.mem.splitScalar(u8, trimmed, '.');

    while (labels.next()) |label| {

        if (label.len == 0 or label.len > 63) return null;

        out[at] = @intCast(label.len);
        @memcpy(out[at + 1 ..][0..label.len], label);
        at += 1 + label.len;

    }

    out[at] = 0;
    wire.put(u16, out[at + 1 ..][0..2], 1);
    wire.put(u16, out[at + 3 ..][0..2], 1);

    return at + 5;

}

/// Reads the reply to query `id`, or null when it is not one.
pub fn parse(message: []const u8, id: u16) ?Answer {

    if (message.len < 12 or wire.be(u16, message[0..2]) != id or message[2] & 0x80 == 0) return null;

    const code = message[3] & 0xf;

    if (code == 3) return .missing;
    if (code != 0) return .failed;

    var at: usize = 12;

    for (0..wire.be(u16, message[4..6])) |_| at = (skip(message, at) orelse return .failed) + 4;

    for (0..wire.be(u16, message[6..8])) |_| {

        at = skip(message, at) orelse return .failed;
        if (at + 10 > message.len) return .failed;

        const kind = wire.be(u16, message[at..][0..2]);
        const class = wire.be(u16, message[at + 2 ..][0..2]);
        const ttl = wire.be(u32, message[at + 4 ..][0..4]);
        const length = wire.be(u16, message[at + 8 ..][0..2]);

        at += 10;
        if (at + length > message.len) return .failed;

        // Aliases come first; the A record among them answers for the name asked.
        if (kind == 1 and class == 1 and length == 4) return .{

            .found = .{

                .address = wire.be(u32, message[at..][0..4]),
                .ttl = ttl,

            },

        };

        at += length;

    }

    return .missing;

}

/// The offset just past the name at `at`, which may end in a pointer to an earlier one.
fn skip(message: []const u8, start: usize) ?usize {

    var at = start;

    while (at < message.len) {

        const length = message[at];

        if (length == 0) return at + 1;
        if (length & 0xc0 == 0xc0) return if (at + 2 <= message.len) at + 2 else null;

        at += 1 + @as(usize, length);

    }

    return null;

}
