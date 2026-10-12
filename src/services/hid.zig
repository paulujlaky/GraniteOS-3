//! What HID keyboards and pointers say about themselves and send: their interfaces, report layouts, and key usages.

const std = @import("std");

pub const Kind = enum {

    keyboard,
    mouse,

};

/// A HID interface worth reading, and its interrupt-in endpoint.
pub const Interface = struct {

    kind: Kind,
    configuration: u8,
    interface: u8,

    /// It speaks the boot protocol, so its reports have a fixed shape.
    boot: bool,

    /// Bytes in its report descriptor.
    report: u16 = 0,

    endpoint: u8 = 0,
    size: u16 = 0,
    interval: u8 = 0,

};

/// The first HID interface in configuration descriptor `bytes` that is a boot keyboard or may be a pointer, with its interrupt-in endpoint.
pub fn find(bytes: []const u8) ?Interface {

    if (bytes.len < 9) return null;

    var found: ?Interface = null;
    var at: usize = 0;

    while (at + 2 <= bytes.len) {

        const length = bytes[at];
        const kind = bytes[at + 1];

        if (length < 2 or at + length > bytes.len) return null;

        const descriptor = bytes[at..][0..length];

        at += length;

        switch (kind) {

            // An interface of class HID: a boot keyboard, or anything else, which its report descriptor may show to be a pointer.
            4 => if (length >= 9) {

                if (found != null and found.?.endpoint != 0) return found;

                const boot = descriptor[6] == 1;
                const keyboard_protocol = boot and descriptor[7] == 1;

                found = if (descriptor[5] == 3 and (keyboard_protocol or descriptor[7] != 1)) .{

                    .kind = if (keyboard_protocol) .keyboard else .mouse,
                    .configuration = bytes[5],
                    .interface = descriptor[2],
                    .boot = boot,

                } else null;

            },
            // The HID descriptor, saying how long the report descriptor is.
            0x21 => if (length >= 9) if (found) |*interface| {

                interface.report = std.mem.readInt(u16, descriptor[7..9], .little);

            },
            5 => if (length >= 7) if (found) |*interface| if (interface.endpoint == 0 and descriptor[2] & 0x80 != 0 and descriptor[3] & 3 == 3) {

                interface.endpoint = descriptor[2];
                interface.size = std.mem.readInt(u16, descriptor[4..6], .little) & 0x7ff;
                interface.interval = descriptor[6];

            },
            else => {

            },

        }

    }

    return if (found != null and found.?.endpoint != 0) found else null;

}

/// Where one value sits in a report, after any report ID byte, and the range it spans.
pub const Field = struct {

    offset: u16 = 0,
    size: u8 = 0,
    id: u8 = 0,
    minimum: i32 = 0,
    maximum: i32 = 0,
    relative: bool = true,

    /// The field's value in `report`, sign-extended when its range dips below zero.
    pub fn read(self: Field, bytes: []const u8) i32 {

        var value: u32 = 0;

        for (0..self.size) |bit| {

            const at = self.offset + bit;
            if (at / 8 >= bytes.len) break;

            value |= @as(u32, bytes[at / 8] >> @intCast(at % 8) & 1) << @intCast(bit);

        }

        if (self.minimum < 0 and self.size < 32 and value >> @intCast(self.size - 1) & 1 != 0) value |= ~@as(u32, 0) << @intCast(self.size);

        return @bitCast(value);

    }

};

/// A pointer's report: its ID, if it has several, and where its first three buttons, movement, and wheel sit.
pub const Layout = struct {

    id: u8 = 0,
    buttons: Field = .{},
    x: Field = .{},
    y: Field = .{},
    wheel: Field = .{},

};

/// Reads a HID report descriptor for the first report with X and Y; null when it has none.
pub fn layout(bytes: []const u8) ?Layout {

    var result = Layout{};
    var page: u32 = 0;
    var minimum: i32 = 0;
    var maximum: i32 = 0;
    var size: u32 = 0;
    var count: u32 = 0;
    var id: u8 = 0;
    var offsets: [256]u16 = @splat(0);
    var usages: [16]u32 = undefined;
    var used: usize = 0;
    var range = [2]u32{ 0, 0 };
    var at: usize = 0;

    while (at < bytes.len) {

        const prefix = bytes[at];

        // Long items carry nothing a pointer needs.
        if (prefix == 0xfe) {

            at += 3 + if (at + 1 < bytes.len) bytes[at + 1] else 0;
            continue;

        }

        const length: usize = switch (prefix & 3) {

            3 => 4,
            else => |short_length| short_length,

        };

        if (at + 1 + length > bytes.len) break;

        var value: u32 = 0;

        for (0..length) |index| value |= @as(u32, bytes[at + 1 + index]) << @intCast(index * 8);

        const signed: i32 = switch (length) {

            1 => @as(i8, @bitCast(@as(u8, @truncate(value)))),
            2 => @as(i16, @bitCast(@as(u16, @truncate(value)))),
            else => @bitCast(value),

        };

        at += 1 + length;

        switch (prefix >> 2 & 3) {

            // Global items: the usage page, the logical range, field sizes, and report IDs.
            1 => switch (prefix >> 4) {

                0 => page = value,
                1 => minimum = signed,
                2 => maximum = if (minimum >= 0 and length < 4) @intCast(value) else signed,
                7 => size = value,
                8 => id = @truncate(value),
                9 => count = value,
                else => {

                },

            },
            // Local items: usages, one by one or as a range.
            2 => switch (prefix >> 4) {

                0 => if (used < usages.len) {

                    usages[used] = if (length == 4) value else page << 16 | value;
                    used += 1;

                },
                1 => range[0] = page << 16 | value,
                2 => range[1] = page << 16 | value,
                else => {

                },

            },
            // Main items: inputs take fields from the report; every main item ends the local ones.
            0 => {

                if (prefix >> 4 == 8 and size <= 32) {

                    const constant = value & 1 != 0;

                    for (0..count) |index| {

                        const usage = if (used != 0) usages[@min(index, used - 1)] else if (range[1] >= range[0] and range[1] != 0) range[0] + @as(u32, @intCast(index)) else 0;

                        const field = Field{

                            .offset = offsets[id] + @as(u16, @intCast(index * size)),
                            .size = @intCast(size),
                            .id = id,

                            .minimum = minimum,
                            .maximum = maximum,

                            .relative = value & 4 != 0,

                        };

                        if (constant or result.x.size != 0 and id != result.x.id) continue;

                        switch (usage) {

                            0x10030 => result.x = field,
                            0x10031 => result.y = field,
                            0x10038 => result.wheel = field,

                            // Buttons count from one; up to three are kept, as one field of a bit each.
                            0x90001...0x90003 => if (result.buttons.size == 0 or result.buttons.id != id) {

                                if (usage == 0x90001) {

                                    result.buttons = field;
                                    result.buttons.size = @intCast(@min(count - index, 3));

                                }

                            },
                            else => {

                            },

                        }

                    }

                    offsets[id] +%= @intCast(size * count);

                }

                used = 0;
                range = .{ 0, 0 };

            },
            else => {

            },

        }

    }

    if (result.x.size == 0 or result.y.size == 0 or result.y.id != result.x.id) return null;
    if (result.buttons.id != result.x.id) result.buttons = .{};
    if (result.wheel.id != result.x.id) result.wheel = .{};

    result.id = result.x.id;

    return result;

}

/// Left control, shift, alt, and GUI, then the right ones, as boot reports order their bits.
pub const modifiers = [8]u16{ 0x1d, 0x2a, 0x38, 0x15b, 0x11d, 0x36, 0x138, 0x15c };

/// The set-1 scancode of HID keyboard usage `usage`, with 0x100 for an 0xe0 prefix; zero for keys GraniteOS has no use for.
pub fn translate(usage: u8) u16 {

    const letters = [26]u8{ 0x1e, 0x30, 0x2e, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, 0x32, 0x31, 0x18, 0x19, 0x10, 0x13, 0x1f, 0x14, 0x16, 0x2f, 0x11, 0x2d, 0x15, 0x2c };
    const punctuation = [_]u8{ 0x1c, 0x01, 0x0e, 0x0f, 0x39, 0x0c, 0x0d, 0x1a, 0x1b, 0x2b, 0x2b, 0x27, 0x28, 0x29, 0x33, 0x34, 0x35, 0x3a };

    return switch (usage) {

        0x04...0x1d => letters[usage - 0x04],
        0x1e...0x27 => usage - 0x1e + 0x02,
        0x28...0x39 => punctuation[usage - 0x28],
        0x3a...0x43 => usage - 0x3a + 0x3b,
        0x44 => 0x57,
        0x45 => 0x58,
        0x49 => 0x152,
        0x4a => 0x147,
        0x4b => 0x149,
        0x4c => 0x153,
        0x4d => 0x14f,
        0x4e => 0x151,
        0x4f => 0x14d,
        0x50 => 0x14b,
        0x51 => 0x150,
        0x52 => 0x148,
        0x54 => 0x135,
        0x55 => 0x37,
        0x58 => 0x11c,
        else => 0,

    };

}
