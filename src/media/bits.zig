//! Bit fields read most significant bit first, as MPEG and FLAC store them.

const std = @import("std");

/// Reads past the end give zero bits and still count, so a decoder checks `overrun` once rather than every field.
pub const Bits = struct {

    bytes: []const u8,

    /// Bits read so far.
    position: usize = 0,

    pub fn init(bytes: []const u8) Bits {

        return .{

            .bytes = bytes,

        };

    }

    /// The next `count` bits, up to 32, without moving past them.
    pub fn peek(self: *const Bits, count: u6) u32 {

        std.debug.assert(count <= 32);

        if (count == 0) return 0;

        const index = self.position >> 3;
        var word: u64 = 0;

        if (index + 8 <= self.bytes.len) {

            word = std.mem.readInt(u64, self.bytes[index..][0..8], .big);

        } else {

            for (0..8) |offset| word = word << 8 | if (index + offset < self.bytes.len) self.bytes[index + offset] else 0;

        }

        const shift: u6 = @intCast(self.position & 7);

        return @truncate(word << shift >> @intCast(64 - @as(u7, count)));

    }

    pub fn read(self: *Bits, count: u6) u32 {

        const value = self.peek(count);

        self.position += count;

        return value;

    }

    /// `count` bits as a two's complement number.
    pub fn signed(self: *Bits, count: u6) i32 {

        if (count == 0) return 0;

        const value: i64 = self.read(count);
        const sign = @as(i64, 1) << @intCast(count - 1);

        return @intCast((value ^ sign) - sign);

    }

    pub fn bit(self: *Bits) bool {

        return self.read(1) != 0;

    }

    pub fn skip(self: *Bits, count: usize) void {

        self.position += count;

    }

    /// Zero bits before the next one set, moving past that one too; null when more than `limit` come first.
    pub fn unary(self: *Bits, limit: u32) ?u32 {

        var zeros: u32 = 0;

        while (zeros <= limit) {

            const word = self.peek(32);

            if (word != 0) {

                const run: u6 = @intCast(@clz(word));

                self.position += run + 1;

                return if (zeros + run <= limit) zeros + run else null;

            }

            if (self.overrun()) return null;

            self.position += 32;
            zeros += 32;

        }

        return null;

    }

    /// Moves on to the next whole byte.
    pub fn alignByte(self: *Bits) void {

        self.position = std.mem.alignForward(usize, self.position, 8);

    }

    /// Bits not yet read; zero once past the end.
    pub fn left(self: *const Bits) usize {

        return (self.bytes.len * 8) -| self.position;

    }

    /// Whole bytes read, counting a partly read one.
    pub fn consumed(self: *const Bits) usize {

        return std.math.divCeil(usize, self.position, 8) catch unreachable;

    }

    /// Whether reading went past the last byte.
    pub fn overrun(self: *const Bits) bool {

        return self.position > self.bytes.len * 8;

    }

};

test "bit fields read across bytes, sign extend, count unary runs, and read zeros past the end" {

    var bits = Bits.init(&.{ 0b1011_0011, 0b0000_0000, 0b0000_0001, 0xff, 0x80 });

    try std.testing.expectEqual(0b101, bits.read(3));
    try std.testing.expectEqual(-4, bits.signed(3));
    try std.testing.expectEqual(0b11, bits.peek(2));
    try std.testing.expect(bits.bit());
    try std.testing.expect(bits.bit());
    try std.testing.expectEqual(15, bits.unary(100));
    try std.testing.expectEqual(0xff8, bits.read(12));
    try std.testing.expectEqual(4, bits.left());
    try std.testing.expectEqual(5, bits.consumed());

    bits.alignByte();
    try std.testing.expect(!bits.overrun());
    try std.testing.expectEqual(0, bits.read(32));
    try std.testing.expect(bits.overrun());
    try std.testing.expectEqual(null, bits.unary(1000));

    var long = Bits.init(&(.{0} ** 9 ++ .{1}));

    try std.testing.expectEqual(79, long.unary(100));
    try std.testing.expectEqual(80, long.position);

    long.position = 0;
    try std.testing.expectEqual(null, long.unary(40));

    var wide = Bits.init(&.{ 0x12, 0x34, 0x56, 0x78, 0x9a });

    wide.skip(4);
    try std.testing.expectEqual(0x23456789, wide.read(32));

    var full = Bits.init(&.{ 0x80, 0, 0, 0 });

    try std.testing.expectEqual(std.math.minInt(i32), full.signed(32));

}
