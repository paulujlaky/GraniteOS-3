//! DHCP messages, as RFC 2131 and 2132 lay them out: what a client sends, and what it takes from a server's offer or
//! acknowledgment.

const std = @import("std");

const wire = @import("wire.zig");

pub const client = 68;
pub const server = 67;

pub const Kind = enum(u8) {

    discover = 1,
    offer = 2,
    request = 3,
    decline = 4,
    ack = 5,
    nak = 6,
    release = 7,
    _,

};

pub const Reply = struct {

    kind: Kind,
    address: u32,
    server: u32 = 0,
    mask: u32 = 0,
    router: u32 = 0,
    dns: u32 = 0,

    /// Seconds the address is leased for, and until the client should renew it.
    lease: u32 = 0,
    renew: u32 = 0,

};

const cookie = 0x63825363;

/// Writes a client message to `out`, at least 300 bytes of it; returns its length. `current` is the address the client
/// holds when renewing; `requested` and `chosen` name the offer it takes.
pub fn build(out: []u8, kind: Kind, xid: u32, mac: wire.Mac, current: u32, requested: u32, chosen: u32) usize {

    @memset(out[0..300], 0);

    out[0] = 1;
    out[1] = 1;
    out[2] = 6;
    wire.put(u32, out[4..8], xid);

    // Until it holds an address, the client asks for broadcast replies it can take without one.
    wire.put(u16, out[10..12], if (current == 0) 0x8000 else 0);
    wire.put(u32, out[12..16], current);
    out[28..34].* = mac;
    wire.put(u32, out[236..240], cookie);

    var at: usize = 240;

    at = option(out, at, 53, &.{@intFromEnum(kind)});
    if (requested != 0) at = option(out, at, 50, &bytes(requested));
    if (chosen != 0) at = option(out, at, 54, &bytes(chosen));

    // Mask, router, DNS servers, lease time, and renewal time.
    at = option(out, at, 55, &.{ 1, 3, 6, 51, 58 });
    out[at] = 255;

    return @max(at + 1, 300);

}

/// Reads a server's reply to transaction `xid` for `mac`, or null when it is not one.
pub fn parse(message: []const u8, xid: u32, mac: wire.Mac) ?Reply {

    if (message.len < 240 or message[0] != 2 or wire.be(u32, message[4..8]) != xid) return null;
    if (!std.mem.eql(u8, message[28..34], &mac) or wire.be(u32, message[236..240]) != cookie) return null;

    var reply = Reply{

        .kind = @enumFromInt(0),
        .address = wire.be(u32, message[16..20]),

    };

    var at: usize = 240;

    while (at < message.len) {

        const code = message[at];

        if (code == 255) break;

        if (code == 0) {

            at += 1;
            continue;

        }

        if (at + 2 > message.len) break;

        const length = message[at + 1];
        const value = message[at + 2 ..][0..@min(length, message.len - at - 2)];

        if (value.len == length and length >= 1 and code == 53) reply.kind = @enumFromInt(value[0]);

        if (value.len == length and length >= 4) {

            const number = wire.be(u32, value[0..4]);

            switch (code) {

                1 => reply.mask = number,
                3 => reply.router = number,
                6 => reply.dns = number,
                51 => reply.lease = number,
                54 => reply.server = number,
                58 => reply.renew = number,
                else => {

                },

            }

        }

        at += 2 + length;

    }

    if (reply.kind == @as(Kind, @enumFromInt(0))) return null;
    if (reply.renew == 0) reply.renew = reply.lease / 2;

    return reply;

}

fn option(out: []u8, at: usize, code: u8, value: []const u8) usize {

    out[at] = code;
    out[at + 1] = @intCast(value.len);
    @memcpy(out[at + 2 ..][0..value.len], value);

    return at + 2 + value.len;

}

fn bytes(address: u32) [4]u8 {

    var result: [4]u8 = undefined;

    wire.put(u32, &result, address);

    return result;

}
