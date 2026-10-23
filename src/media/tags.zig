//! What a recording calls itself and who made it, as tags inside the file say.

const std = @import("std");

pub const Tags = struct {

    title: Field = .{},
    artist: Field = .{},

};

/// UTF-8 text cut short to fit, so tags need no allocation.
pub const Field = struct {

    bytes: [126]u8 = undefined,
    length: u8 = 0,

    pub fn get(self: *const Field) []const u8 {

        return self.bytes[0..self.length];

    }

    /// Keeps as much of UTF-8 `text` as fits, ending on a whole character, without surrounding spaces or NULs.
    pub fn set(self: *Field, text: []const u8) void {

        const trimmed = std.mem.trim(u8, text, " \x00\t\r\n");
        var end = @min(trimmed.len, self.bytes.len);

        // Cuts before a character's continuation bytes rather than through them.
        if (end < trimmed.len) while (end > 0 and trimmed[end] & 0xc0 == 0x80) : (end -= 1) {};

        @memcpy(self.bytes[0..end], trimmed[0..end]);
        self.length = @intCast(end);

    }

    /// Keeps ISO 8859-1 `text`, as older tags store it.
    pub fn latin(self: *Field, text: []const u8) void {

        var buffer: [252]u8 = undefined;
        var length: usize = 0;

        for (text[0..@min(text.len, buffer.len / 2)]) |character| {

            length += std.unicode.utf8Encode(character, buffer[length..]) catch unreachable;

        }

        self.set(buffer[0..length]);

    }

    /// Keeps UTF-16 `text` in `endian` order, replacing what does not decode.
    pub fn wide(self: *Field, text: []const u8, endian: std.builtin.Endian) void {

        var buffer: [252]u8 = undefined;
        var length: usize = 0;
        var index: usize = 0;

        while (index + 1 < text.len and length + 4 <= buffer.len) {

            var unit: u21 = std.mem.readInt(u16, text[index..][0..2], endian);

            index += 2;

            if (unit >= 0xd800 and unit < 0xdc00 and index + 1 < text.len) {

                const low = std.mem.readInt(u16, text[index..][0..2], endian);

                if (low >= 0xdc00 and low < 0xe000) {

                    unit = 0x10000 + ((unit - 0xd800) << 10 | (low - 0xdc00));
                    index += 2;

                }

            }

            if (unit >= 0xd800 and unit < 0xe000) unit = 0xfffd;
            if (unit == 0) break;

            length += std.unicode.utf8Encode(unit, buffer[length..]) catch unreachable;

        }

        self.set(buffer[0..length]);

    }

};

test "tag fields trim, cut on character boundaries, and convert Latin-1 and UTF-16" {

    var field = Field{};

    field.set("  Song\x00\x00");
    try std.testing.expectEqualStrings("Song", field.get());

    field.set("é" ** 70);
    try std.testing.expectEqual(126, field.get().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(field.get()));

    field.set("a" ++ "é" ** 70);
    try std.testing.expectEqual(125, field.get().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(field.get()));

    field.latin("Caf\xe9");
    try std.testing.expectEqualStrings("Café", field.get());

    field.wide("\x00H\x00i\xd8\x3d\xde\x00\xdc\x00", .big);
    try std.testing.expectEqualStrings("Hi\u{1f600}\u{fffd}", field.get());

    field.wide("O\x00k\x00\x00\x00z\x00", .little);
    try std.testing.expectEqualStrings("Ok", field.get());

}
