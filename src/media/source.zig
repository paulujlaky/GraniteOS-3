//! A file's bytes as decoders read through them: a window held in memory and refilled from wherever the file lives, so a
//! long recording plays without being loaded whole.

const std = @import("std");

/// What goes wrong decoding: bytes that break the format, a valid feature not handled, no memory, or a failed read.
pub const Error = error{ Invalid, Unsupported, OutOfMemory, Unreadable };

pub const Source = struct {

    /// Reads up to `buffer.len` bytes at `offset` of the file, fewer only at its end.
    pub const Read = *const fn (context: *anyopaque, offset: u64, buffer: []u8) error{Unreadable}!usize;

    /// The file's length in bytes.
    size: u64,

    /// Memory the window lives in, and the bytes of the file it holds now.
    buffer: []u8,
    window: []const u8,

    /// Where `window` starts in the file, and how far into it reading has come.
    start: u64 = 0,
    at: usize = 0,

    context: ?*anyopaque = null,
    reader: ?Read = null,

    /// The whole file, already in memory.
    pub fn fixed(bytes: []const u8) Source {

        return .{

            .size = bytes.len,
            .buffer = &.{},
            .window = bytes,

        };

    }

    /// A file of `size` bytes read through `reader` into `buffer`, whose length bounds what one peek can see.
    pub fn init(buffer: []u8, size: u64, context: *anyopaque, reader: Read) Source {

        return .{

            .size = size,
            .buffer = buffer,
            .window = buffer[0..0],

            .context = context,
            .reader = reader,

        };

    }

    /// Where reading has reached in the file.
    pub fn offset(self: *const Source) u64 {

        return self.start + self.at;

    }

    /// Bytes from where reading is to the end of the file.
    pub fn left(self: *const Source) u64 {

        return self.size -| self.offset();

    }

    /// At least `count` bytes from where reading is, or all that are left when the file ends sooner; more may follow.
    pub fn peek(self: *Source, count: usize) Error![]const u8 {

        if (self.window.len - self.at < count) try self.fill(count);

        return self.window[self.at..];

    }

    /// As many of the next `count` bytes as the window holds at most, or the rest of the file; more may follow.
    pub fn ahead(self: *Source, count: usize) Error![]const u8 {

        return self.peek(if (self.reader == null) count else @min(count, self.buffer.len));

    }

    /// Exactly `count` bytes, moving past them; a file ending first is invalid.
    pub fn take(self: *Source, count: usize) Error![]const u8 {

        const bytes = try self.peek(count);

        if (bytes.len < count) return error.Invalid;
        self.at += count;

        return bytes[0..count];

    }

    pub fn byte(self: *Source) Error!u8 {

        return (try self.take(1))[0];

    }

    pub fn int(self: *Source, comptime T: type, endian: std.builtin.Endian) Error!T {

        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], endian);

    }

    /// Moves reading on by `count` bytes, which may lie past the window or the end of the file.
    pub fn skip(self: *Source, count: u64) Error!void {

        if (count <= self.window.len - self.at) {

            self.at += @intCast(count);

        } else {

            try self.seek(self.offset() +| count);

        }

    }

    /// Moves reading to `target`, held to the end of the file.
    pub fn seek(self: *Source, target: u64) Error!void {

        const place = @min(target, self.size);

        if (place >= self.start and place - self.start <= self.window.len) {

            self.at = @intCast(place - self.start);
            return;

        }

        self.start = place;
        self.window = self.buffer[0..0];
        self.at = 0;

    }

    /// Keeps the unread bytes and reads on until `count` are held or the file ends.
    fn fill(self: *Source, count: usize) Error!void {

        const reader = self.reader orelse return;

        if (count > self.buffer.len) return error.Unsupported;

        const kept = self.window.len - self.at;

        std.mem.copyForwards(u8, self.buffer[0..kept], self.window[self.at..]);
        self.start += self.at;
        self.at = 0;

        var length = kept;

        while (length < count and self.start + length < self.size) {

            const got = try reader(self.context.?, self.start + length, self.buffer[length..]);

            if (got == 0) break;
            length += got;

        }

        self.window = self.buffer[0..length];

    }

};

/// A file in memory read through `buffer` in small pieces, so tests see the same refills a real file would cause.
pub const Chunked = struct {

    bytes: []const u8,

    /// The most one read returns.
    piece: usize,

    pub fn source(self: *Chunked, buffer: []u8) Source {

        return Source.init(buffer, self.bytes.len, self, read);

    }

    fn read(context: *anyopaque, offset: u64, buffer: []u8) error{Unreadable}!usize {

        const self: *Chunked = @ptrCast(@alignCast(context));

        if (offset >= self.bytes.len) return 0;

        const count = @min(buffer.len, self.piece, self.bytes.len - offset);

        @memcpy(buffer[0..count], self.bytes[@intCast(offset)..][0..count]);

        return count;

    }

};

test "sources peek, take, skip, and seek across refills as a fixed source would" {

    var bytes: [1000]u8 = undefined;

    for (&bytes, 0..) |*value, index| value.* = @truncate(index * 7);

    var file = Chunked{

        .bytes = &bytes,
        .piece = 37,

    };

    var buffer: [64]u8 = undefined;
    var chunked = file.source(&buffer);
    var whole = Source.fixed(&bytes);

    for ([_]*Source{ &chunked, &whole }) |source| {

        try std.testing.expectEqualSlices(u8, bytes[0..10], (try source.take(10)));
        try std.testing.expect((try source.peek(50)).len >= 50);
        try std.testing.expectEqual(bytes[10], try source.byte());
        try std.testing.expectEqual(std.mem.readInt(u32, bytes[11..15], .big), try source.int(u32, .big));

        try source.skip(500);
        try std.testing.expectEqual(515, source.offset());
        try std.testing.expectEqual(bytes[515], try source.byte());

        try source.seek(20);
        try std.testing.expectEqualSlices(u8, bytes[20..60], try source.take(40));
        try std.testing.expect((try source.ahead(5000)).len >= 64);

        try source.seek(990);
        try std.testing.expectEqual(10, (try source.peek(40)).len);
        try std.testing.expectError(error.Invalid, source.take(11));
        try std.testing.expectEqual(10, source.left());

        try source.skip(1 << 40);
        try std.testing.expectEqual(0, (try source.peek(1)).len);

    }

    try std.testing.expectError(error.Unsupported, chunked.peek(65));

}
