//! WAVE files: PCM from 8 to 32 bits, 32- and 64-bit floats, and A-law or µ-law, with any number of channels folded to
//! stereo.

const std = @import("std");

const speakers = @import("speakers.zig");

const Source = @import("source.zig").Source;
const Tags = @import("tags.zig").Tags;

pub const Error = @import("source.zig").Error;

/// How each sample is stored.
const Encoding = enum {

    unsigned8,
    signed16,
    signed24,
    signed32,
    float32,
    float64,
    alaw,
    mulaw,

    fn size(self: Encoding) u8 {

        return switch (self) {

            .unsigned8, .alaw, .mulaw => 1,
            .signed16 => 2,
            .signed24 => 3,
            .signed32, .float32 => 4,
            .float64 => 8,

        };

    }

};

const format_pcm = 1;
const format_float = 3;
const format_alaw = 6;
const format_mulaw = 7;
const format_extensible = 0xfffe;

pub const Decoder = struct {

    rate: u32,
    channels: u8,
    frames: ?u64,
    tags: Tags = .{},

    source: *Source,
    encoding: Encoding,

    /// Channels as stored, and the bytes of one frame of them.
    stored: u8,
    block: u16,
    downmix: speakers.Downmix,

    /// Where the samples start in the file, how many frames they hold, and the next frame to read.
    start: u64,
    count: u64,
    at: u64 = 0,

    pub fn open(allocator: std.mem.Allocator, source: *Source) Error!Decoder {

        _ = allocator;

        const riff = try source.take(12);

        if (!std.mem.eql(u8, riff[0..4], "RIFF") or !std.mem.eql(u8, riff[8..12], "WAVE")) return error.Invalid;

        var format: ?Format = null;
        var tags = Tags{};

        while (true) {

            const chunk = try source.take(8);
            const size = std.mem.readInt(u32, chunk[4..8], .little);
            const padded = @as(u64, size) + (size & 1);

            if (std.mem.eql(u8, chunk[0..4], "data")) {

                const found = format orelse return error.Invalid;
                const start = source.offset();

                // Writers that never came back to fill in the length leave it zero or all ones.
                const length = if (size == 0 or size == 0xffffffff) source.left() else @min(size, source.left());

                var decoder = Decoder{

                    .rate = found.rate,
                    .channels = @min(found.channels, 2),
                    .frames = length / found.block,

                    .source = source,
                    .encoding = found.encoding,

                    .stored = found.channels,
                    .block = found.block,
                    .downmix = speakers.Downmix.init(found.channels, found.mask),

                    .start = start,
                    .count = length / found.block,

                };

                // Tags often follow the samples, so a look past them finds those too.
                if (start + padded < source.size) {

                    try source.seek(start + padded);
                    tags = trailing(source, tags) catch tags;
                    try source.seek(start);

                }

                decoder.tags = tags;

                return decoder;

            }

            if (std.mem.eql(u8, chunk[0..4], "fmt ")) {

                if (size < 16 or size > 1024) return error.Invalid;

                format = try Format.parse(try source.take(size));
                try source.skip(size & 1);

            } else if (std.mem.eql(u8, chunk[0..4], "LIST") and size <= 65536) {

                info(try source.take(size), &tags);
                try source.skip(size & 1);

            } else {

                try source.skip(padded);

            }

            if (source.left() < 8) return error.Invalid;

        }

    }

    pub fn deinit(self: *Decoder, allocator: std.mem.Allocator) void {

        _ = self;
        _ = allocator;

    }

    /// Up to `out.len / channels` frames of interleaved samples; zero at the end.
    pub fn read(self: *Decoder, out: []f32) Error!usize {

        const wanted: usize = @intCast(@min(out.len / self.channels, self.count - self.at));
        var done: usize = 0;

        while (done < wanted) {

            const bytes = try self.source.ahead((wanted - done) * self.block);
            const frames = @min(bytes.len / self.block, wanted - done);

            // The file ended partway through what its header promised.
            if (frames == 0) {

                self.count = self.at;
                break;

            }

            self.convert(bytes[0 .. frames * self.block], out[done * self.channels ..][0 .. frames * self.channels]);
            try self.source.skip(frames * self.block);
            done += frames;
            self.at += frames;

        }

        return done;

    }

    /// Moves to frame `frame`, or the end, exactly.
    pub fn seek(self: *Decoder, frame: u64) Error!u64 {

        self.at = @min(frame, self.count);
        try self.source.seek(self.start + self.at * self.block);

        return self.at;

    }

    fn convert(self: *const Decoder, bytes: []const u8, out: []f32) void {

        switch (self.encoding) {

            inline else => |encoding| {

                const size = comptime encoding.size();

                if (self.stored <= 2) {

                    for (out, 0..) |*sample, index| sample.* = level(encoding, bytes[index * size ..][0..size]);
                    return;

                }

                var values: [speakers.most]f32 = undefined;

                for (0..bytes.len / self.block) |frame| {

                    const stored = bytes[frame * self.block ..][0..self.block];

                    for (values[0..self.stored], 0..) |*value, channel| value.* = level(encoding, stored[channel * size ..][0..size]);
                    out[frame * 2 ..][0..2].* = self.downmix.fold(values[0..self.stored]);

                }

            },

        }

    }

};

/// What the `fmt ` chunk says.
const Format = struct {

    encoding: Encoding,
    channels: u8,
    rate: u32,
    block: u16,
    mask: u32 = 0,

    fn parse(body: []const u8) Error!Format {

        var tag = std.mem.readInt(u16, body[0..2], .little);
        const channels = std.mem.readInt(u16, body[2..4], .little);
        const rate = std.mem.readInt(u32, body[4..8], .little);
        const block = std.mem.readInt(u16, body[12..14], .little);
        const bits = std.mem.readInt(u16, body[14..16], .little);
        var mask: u32 = 0;

        if (tag == format_extensible) {

            if (body.len < 40) return error.Invalid;

            mask = std.mem.readInt(u32, body[20..24], .little);
            tag = std.mem.readInt(u16, body[24..26], .little);

        }

        if (channels == 0 or rate == 0 or block == 0) return error.Invalid;
        if (channels > speakers.most or rate < 1000 or rate > 768000) return error.Unsupported;

        // Samples may sit in wider containers than their bits need, as 20 bits in 3 bytes.
        const container = block / channels;

        if (container * channels != block or bits > @as(u32, container) * 8 or bits == 0) return error.Invalid;

        const encoding: Encoding = switch (tag) {

            format_pcm => switch (container) {

                1 => .unsigned8,
                2 => .signed16,
                3 => .signed24,
                4 => .signed32,
                else => return error.Unsupported,

            },
            format_float => switch (container) {

                4 => .float32,
                8 => .float64,
                else => return error.Unsupported,

            },
            format_alaw => if (container == 1) .alaw else return error.Unsupported,
            format_mulaw => if (container == 1) .mulaw else return error.Unsupported,
            else => return error.Unsupported,

        };

        return .{

            .encoding = encoding,
            .channels = @intCast(channels),
            .rate = rate,
            .block = block,
            .mask = mask,

        };

    }

};

/// One sample at full scale ±1.
inline fn level(comptime encoding: Encoding, bytes: *const [encoding.size()]u8) f32 {

    return switch (encoding) {

        .unsigned8 => (@as(f32, @floatFromInt(bytes[0])) - 128) / 128,
        .signed16 => @as(f32, @floatFromInt(std.mem.readInt(i16, bytes, .little))) / 32768,
        .signed24 => @as(f32, @floatFromInt(std.mem.readInt(i24, bytes, .little))) / 8388608,
        .signed32 => @as(f32, @floatFromInt(std.mem.readInt(i32, bytes, .little))) / 2147483648,
        .float32 => @bitCast(std.mem.readInt(u32, bytes, .little)),
        .float64 => @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, bytes, .little)))),
        .alaw => companded[0][bytes[0]],
        .mulaw => companded[1][bytes[0]],

    };

}

/// G.711's A-law and µ-law bytes expanded, each at full scale ±1.
const companded = table: {

    var result: [2][256]f32 = undefined;

    for (0..256) |index| {

        const a = index ^ 0x55;
        const exponent = (a >> 4) & 7;
        const mantissa = a & 15;
        const magnitude: f32 = if (exponent == 0) mantissa * 16 + 8 else (mantissa * 16 + 0x108) << (exponent - 1);

        result[0][index] = (if (a & 0x80 != 0) magnitude else -magnitude) / 32768;

        const u = ~index & 0xff;
        const linear: f32 = (((u & 15) << 3) + 0x84 << ((u >> 4) & 7)) - 0x84;

        result[1][index] = (if (u & 0x80 != 0) -linear else linear) / 32768;

    }

    break :table result;

};

/// Reads the chunks after the samples for a `LIST` of tags.
fn trailing(source: *Source, found: Tags) Error!Tags {

    var tags = found;

    for (0..16) |_| {

        if (source.left() < 8) break;

        const chunk = try source.take(8);
        const size = std.mem.readInt(u32, chunk[4..8], .little);

        if (std.mem.eql(u8, chunk[0..4], "LIST") and size <= 65536) {

            info(try source.take(size), &tags);
            break;

        }

        try source.skip(@as(u64, size) + (size & 1));

    }

    return tags;

}

/// Takes the title and artist from a `LIST` chunk of `INFO` entries.
fn info(body: []const u8, tags: *Tags) void {

    if (body.len < 4 or !std.mem.eql(u8, body[0..4], "INFO")) return;

    var position: usize = 4;

    while (position + 8 <= body.len) {

        const id = body[position..][0..4];
        const size = std.mem.readInt(u32, body[position + 4 ..][0..4], .little);
        const text = body[position + 8 ..][0..@min(size, body.len - position - 8)];

        if (std.mem.eql(u8, id, "INAM")) tags.title.set(text);
        if (std.mem.eql(u8, id, "IART")) tags.artist.set(text);

        position += 8 + @as(usize, size) + (size & 1);

    }

}

/// A WAVE file of `samples`' bytes after a `fmt ` chunk made of `format`, with `before` and `after` chunks around them.
fn fixture(allocator: std.mem.Allocator, format: []const u8, samples: []const u8, before: []const u8, after: []const u8) ![]u8 {

    var bytes: std.ArrayList(u8) = .empty;

    errdefer bytes.deinit(allocator);

    try bytes.appendSlice(allocator, "RIFF\x00\x00\x00\x00WAVEfmt ");
    try bytes.appendSlice(allocator, &std.mem.toBytes(@as(u32, @intCast(format.len))));
    try bytes.appendSlice(allocator, format);
    try bytes.appendSlice(allocator, before);
    try bytes.appendSlice(allocator, "data");
    try bytes.appendSlice(allocator, &std.mem.toBytes(@as(u32, @intCast(samples.len))));
    try bytes.appendSlice(allocator, samples);
    if (samples.len & 1 != 0) try bytes.append(allocator, 0);
    try bytes.appendSlice(allocator, after);

    std.mem.writeInt(u32, bytes.items[4..8], @intCast(bytes.items.len - 8), .little);

    return bytes.toOwnedSlice(allocator);

}

fn header(tag: u16, channels: u16, rate: u32, container: u16, bits: u16) [16]u8 {

    var result: [16]u8 = undefined;

    std.mem.writeInt(u16, result[0..2], tag, .little);
    std.mem.writeInt(u16, result[2..4], channels, .little);
    std.mem.writeInt(u32, result[4..8], rate, .little);
    std.mem.writeInt(u32, result[8..12], rate * channels * container, .little);
    std.mem.writeInt(u16, result[12..14], channels * container, .little);
    std.mem.writeInt(u16, result[14..16], bits, .little);

    return result;

}

test "wave files decode every sample encoding at full scale" {

    const allocator = std.testing.allocator;

    const cases = [_]struct { [16]u8, []const u8, [2]f32 }{

        .{ header(format_pcm, 1, 8000, 1, 8), &.{ 0, 255 }, .{ -1, 127.0 / 128.0 } },
        .{ header(format_pcm, 2, 44100, 2, 16), &.{ 0x00, 0x80, 0xff, 0x7f }, .{ -1, 32767.0 / 32768.0 } },
        .{ header(format_pcm, 1, 48000, 3, 20), &.{ 0x00, 0x00, 0xc0, 0x00, 0x00, 0x40 }, .{ -0.5, 0.5 } },
        .{ header(format_pcm, 1, 96000, 4, 32), &.{ 0, 0, 0, 0x80, 0, 0, 0, 0x40 }, .{ -1, 0.5 } },
        .{ header(format_float, 1, 48000, 4, 32), &(std.mem.toBytes(@as(f32, 0.25)) ++ std.mem.toBytes(@as(f32, -0.75))), .{ 0.25, -0.75 } },
        .{ header(format_float, 1, 48000, 8, 64), &(std.mem.toBytes(@as(f64, -0.125)) ++ std.mem.toBytes(@as(f64, 1))), .{ -0.125, 1 } },
        .{ header(format_mulaw, 1, 8000, 1, 8), &.{ 0x00, 0xff }, .{ -32124.0 / 32768.0, 0 } },
        .{ header(format_alaw, 1, 8000, 1, 8), &.{ 0xd5, 0x2a }, .{ 8.0 / 32768.0, -32256.0 / 32768.0 } },

    };

    for (cases) |case| {

        const format, const samples, const expected = case;
        const bytes = try fixture(allocator, &format, samples, "", "");

        defer allocator.free(bytes);

        var source = Source.fixed(bytes);
        var decoder = try Decoder.open(allocator, &source);
        var out: [4]f32 = undefined;

        defer decoder.deinit(allocator);

        try std.testing.expectEqual(std.mem.readInt(u32, format[4..8], .little), decoder.rate);
        try std.testing.expectEqual(2 / decoder.channels, decoder.frames);
        try std.testing.expectEqual(2, try decoder.read(&out) * decoder.channels);
        try std.testing.expectEqualSlices(f32, &expected, out[0..2]);
        try std.testing.expectEqual(0, try decoder.read(&out));

    }

}

test "wave tags come from lists before or after the samples, and odd chunks keep their padding" {

    const allocator = std.testing.allocator;
    const format = header(format_pcm, 1, 8000, 1, 8);
    const tags = "LIST\x1e\x00\x00\x00INFOINAM\x05\x00\x00\x00Song\x00\x00IART\x03\x00\x00\x00Me\x00\x00";
    const odd = "junk\x03\x00\x00\x00abc\x00";

    for ([_][2][]const u8{ .{ tags ++ odd, "" }, .{ odd, tags }, .{ "", odd ++ tags } }) |around| {

        const bytes = try fixture(allocator, &format, &.{ 128, 192, 64 }, around[0], around[1]);

        defer allocator.free(bytes);

        var source = Source.fixed(bytes);
        var decoder = try Decoder.open(allocator, &source);
        var out: [8]f32 = undefined;

        try std.testing.expectEqualStrings("Song", decoder.tags.title.get());
        try std.testing.expectEqualStrings("Me", decoder.tags.artist.get());
        try std.testing.expectEqual(3, try decoder.read(&out));
        try std.testing.expectEqualSlices(f32, &.{ 0, 0.5, -0.5 }, out[0..3]);

    }

}

test "wave files with many channels fold to stereo, seek exactly, and read the same through small refills" {

    const allocator = std.testing.allocator;
    var format: [40]u8 = @splat(0);

    format[0..16].* = header(format_extensible, 6, 48000, 2, 16);
    std.mem.writeInt(u16, format[16..18], 22, .little);
    std.mem.writeInt(u32, format[20..24], 0x3f, .little);
    std.mem.writeInt(u16, format[24..26], format_pcm, .little);

    var samples: [6 * 2 * 500]u8 = undefined;

    for (0..500) |frame| {

        for (0..6) |channel| std.mem.writeInt(i16, samples[(frame * 6 + channel) * 2 ..][0..2], @intCast(frame * 6 + channel), .little);

    }

    const bytes = try fixture(allocator, &format, &samples, "", "");

    defer allocator.free(bytes);

    var whole = Source.fixed(bytes);
    var file = @import("source.zig").Chunked{

        .bytes = bytes,
        .piece = 77,

    };

    var buffer: [256]u8 = undefined;
    var chunked = file.source(&buffer);
    var first = try Decoder.open(allocator, &whole);
    var second = try Decoder.open(allocator, &chunked);

    try std.testing.expectEqual(2, first.channels);
    try std.testing.expectEqual(500, first.frames);

    var expected: [1000]f32 = undefined;
    var actual: [1000]f32 = undefined;

    try std.testing.expectEqual(500, try first.read(&expected));

    var done: usize = 0;

    while (done < 500) done += try second.read(actual[done * 2 ..][0..@min(26, 1000 - done * 2)]);

    try std.testing.expectEqualSlices(f32, &expected, &actual);

    const surround = speakers.Downmix.init(6, 0x3f);
    const values = [_]f32{ 1200, 1201, 1202, 1203, 1204, 1205 };

    try std.testing.expectEqual(200, try first.seek(200));
    try std.testing.expectEqual(1, try first.read(actual[0..3]));
    try std.testing.expectApproxEqAbs(surround.fold(&values)[0] / 32768, actual[0], 1e-6);
    try std.testing.expectEqual(500, try first.seek(9000));
    try std.testing.expectEqual(0, try first.read(&actual));

}

test "wave files that end early or break the format fail cleanly" {

    const allocator = std.testing.allocator;
    const format = header(format_pcm, 2, 8000, 2, 16);
    const bytes = try fixture(allocator, &format, &(.{0x11} ** 400), "", "");

    defer allocator.free(bytes);

    var out: [400]f32 = undefined;
    var source = Source.fixed(bytes[0 .. bytes.len - 101]);
    var decoder = try Decoder.open(allocator, &source);

    try std.testing.expectEqual(74, decoder.frames);
    try std.testing.expectEqual(74, try decoder.read(&out));

    var lies = try allocator.dupe(u8, bytes);

    defer allocator.free(lies);

    std.mem.writeInt(u32, lies[40..44], 0xffffffff, .little);
    source = Source.fixed(lies);
    try std.testing.expectEqual(100, (try Decoder.open(allocator, &source)).frames);

    var prng = std.Random.DefaultPrng.init(7);

    for (0..2000) |_| {

        @memcpy(lies, bytes);

        for (0..4) |_| lies[prng.random().uintLessThan(usize, 48)] = prng.random().int(u8);

        source = Source.fixed(lies[0..prng.random().uintLessThan(usize, lies.len)]);

        var broken = Decoder.open(allocator, &source) catch continue;

        while (try broken.read(&out) != 0) {

        }

    }

}
