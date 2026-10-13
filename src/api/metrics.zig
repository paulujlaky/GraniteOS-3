//! Roughly where this computer is, as the metrics service last worked out from its public address; apps granted `network`
//! may ask, such as Weather for its current location.

const std = @import("std");

const api = @import("root.zig");

const protocol = api.protocol;

/// A place by name and coordinates; each name is padded with NULs, read with `text`.
pub const Place = extern struct {

    latitude: f64 = 0,
    longitude: f64 = 0,

    city: [48]u8 = @splat(0),
    region: [48]u8 = @splat(0),
    country: [48]u8 = @splat(0),

    /// The IANA time zone, such as `America/Chicago`.
    zone: [40]u8 = @splat(0),

};

/// A name of a `Place`, without its padding.
pub fn text(field: []const u8) []const u8 {

    return field[0 .. std.mem.indexOfScalar(u8, field, 0) orelse field.len];

}

/// Writes `value` into a name of a `Place`, cut short at a character's edge when it is too long.
pub fn fill(field: []u8, value: []const u8) void {

    var length = @min(value.len, field.len);

    while (length > 0 and length < value.len and value[length] & 0xc0 == 0x80) length -= 1;

    @memset(field, 0);
    @memcpy(field[0..length], value[0..length]);

}

var endpoint: u64 = 0;

/// Where this computer is; `error.Busy` while the service is still finding out, and `error.Missing` when it could not.
pub fn place() api.ServiceError!Place {

    var result = Place{};

    _ = try api.query(&endpoint, .metrics, protocol.pack(.locate, 0), std.mem.asBytes(&result));

    return result;

}
