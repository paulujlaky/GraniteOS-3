//! FLAC: lossless audio of 4 to 32 bits in up to eight channels, read a frame at a time and seeked by its seek table or by
//! bisecting the file.

const std = @import("std");

const speakers = @import("speakers.zig");

const Bits = @import("bits.zig").Bits;
const Source = @import("source.zig").Source;
const Tags = @import("tags.zig").Tags;

pub const Error = @import("source.zig").Error;

/// What STREAMINFO says of every frame.
const Stream = struct {

    smallest: u16,
    largest: u16,
    frame: u24,
    rate: u32,
    channels: u8,
    bits: u8,
    total: u64,
    signature: [16]u8,

    fn parse(body: []const u8) Error!Stream {

        if (body.len < 34) return error.Invalid;

        const packed_fields = std.mem.readInt(u64, body[10..18], .big);

        const result = Stream{

            .smallest = std.mem.readInt(u16, body[0..2], .big),
            .largest = std.mem.readInt(u16, body[2..4], .big),
            .frame = std.mem.readInt(u24, body[7..10], .big),
            .rate = @intCast(packed_fields >> 44),
            .channels = @as(u8, @intCast(packed_fields >> 41 & 7)) + 1,
            .bits = @as(u8, @intCast(packed_fields >> 36 & 31)) + 1,
            .total = packed_fields & 0xf_ffff_ffff,
            .signature = body[18..34].*,

        };

        if (result.largest < 16 or result.smallest > result.largest or result.rate == 0 or result.bits < 4) return error.Invalid;

        return result;

    }

    /// The most bytes a frame can take, when the stream does not say.
    fn ceiling(self: *const Stream) usize {

        if (self.frame != 0) return @as(usize, self.frame) + 16;

        return @as(usize, self.largest) * self.channels * (@as(usize, self.bits) + 1) / 8 + 64;

    }

};

/// A frame's header, which names its place, length, and channel layout.
const Header = struct {

    block: u32,
    assignment: u4,
    bits: u8,

    /// The frame's number, or with a variable block size its first sample's.
    number: u64,
    variable: bool,

    /// Bytes the header takes, its CRC included.
    length: usize,

    fn parse(bytes: []const u8, stream: *const Stream) ?Header {

        if (bytes.len < 6 or bytes[0] != 0xff or bytes[1] & 0xfe != 0xf8 or bytes[3] & 1 != 0) return null;

        const block_code = bytes[2] >> 4;
        const rate_code = bytes[2] & 15;
        const assignment: u4 = @intCast(bytes[3] >> 4);
        const size_code = bytes[3] >> 1 & 7;

        if (block_code == 0 or rate_code == 15 or assignment > 10 or size_code == 3) return null;

        // The number is UTF-8 coded, its first byte saying how many follow.
        const lead = bytes[4];
        const following: usize = if (lead < 0x80) 0 else if (lead >= 0xfe) 6 else @clz(~lead) - 1;

        if (following == 0 and lead >= 0x80 or following > 6) return null;

        var number: u64 = if (following == 0) lead else lead & (@as(u8, 0x3f) >> @intCast(following));
        var position: usize = 5;

        if (bytes.len < position + following + 4) return null;

        for (bytes[position..][0..following]) |byte| {

            if (byte & 0xc0 != 0x80) return null;
            number = number << 6 | (byte & 0x3f);

        }

        position += following;

        const block: u32 = switch (block_code) {

            1 => 192,
            2...5 => @as(u32, 576) << @intCast(block_code - 2),
            6 => @as(u32, bytes[position]) + 1,
            7 => @as(u32, std.mem.readInt(u16, bytes[position..][0..2], .big)) + 1,
            else => @as(u32, 256) << @intCast(block_code - 8),

        };

        position += switch (block_code) {

            6 => 1,
            7 => 2,
            else => 0,

        };

        position += switch (rate_code) {

            12 => 1,
            13, 14 => 2,
            else => 0,

        };

        const bits: u8 = switch (size_code) {

            0 => stream.bits,
            1 => 8,
            2 => 12,
            4 => 16,
            5 => 20,
            6 => 24,
            else => 32,

        };

        if (bytes.len <= position or std.hash.crc.Crc8Smbus.hash(bytes[0..position]) != bytes[position]) return null;

        return .{

            .block = block,
            .assignment = assignment,
            .bits = bits,

            .number = number,
            .variable = bytes[1] & 1 != 0,

            .length = position + 1,

        };

    }

    fn channels(self: Header) u8 {

        return if (self.assignment < 8) @as(u8, self.assignment) + 1 else 2;

    }

    /// The frame's first sample.
    fn first(self: Header, stream: *const Stream) u64 {

        if (self.variable) return self.number;

        // Every frame of a fixed block size but the last holds the same samples, and the last may hold fewer.
        return self.number *% if (stream.smallest == stream.largest) stream.largest else self.block;

    }

};

const Point = struct {

    sample: u64,
    offset: u64,

};

pub const Decoder = struct {

    rate: u32,
    channels: u8,
    frames: ?u64,
    tags: Tags = .{},

    source: *Source,
    stream: Stream,
    downmix: speakers.Downmix,

    /// Where the first frame starts, and the seek table's points.
    first: u64,
    points: []Point,

    /// Each channel's decoded samples for the frame at hand, `stream.largest` apart.
    samples: []i64,

    /// The frame at hand: its first sample, how many it holds, how many were read, and the scale of its samples.
    start: u64 = 0,
    block: u32 = 0,
    used: u32 = 0,
    scale: f32 = 1,

    pub fn open(allocator: std.mem.Allocator, source: *Source) Error!Decoder {

        try skipTag(source);

        if (!std.mem.eql(u8, try source.take(4), "fLaC")) return error.Invalid;

        var stream: ?Stream = null;
        var tags = Tags{};
        var points: []Point = &.{};

        errdefer allocator.free(points);

        while (true) {

            const head = try source.take(4);
            const kind = head[0] & 0x7f;
            const length = std.mem.readInt(u24, head[1..4], .big);

            switch (kind) {

                0 => stream = try Stream.parse(try source.take(length)),
                3 => if (points.len == 0) {

                    points = try table(allocator, source, length);

                } else {

                    try source.skip(length);

                },
                4 => if (length <= 65536) comments(try source.take(length), &tags) else try source.skip(length),
                127 => return error.Invalid,
                else => try source.skip(length),

            }

            if (head[0] & 0x80 != 0) break;

        }

        const found = stream orelse return error.Invalid;
        const samples = try allocator.alloc(i64, @as(usize, found.largest) * found.channels);

        return .{

            .rate = found.rate,
            .channels = @min(found.channels, 2),
            .frames = if (found.total == 0) null else found.total,
            .tags = tags,

            .source = source,
            .stream = found,
            .downmix = speakers.Downmix.init(found.channels, layout(found.channels)),

            .first = source.offset(),
            .points = points,

            .samples = samples,

        };

    }

    pub fn deinit(self: *Decoder, allocator: std.mem.Allocator) void {

        allocator.free(self.samples);
        allocator.free(self.points);

    }

    /// Up to `out.len / channels` frames of interleaved samples; zero at the end.
    pub fn read(self: *Decoder, out: []f32) Error!usize {

        const wanted = out.len / self.channels;
        var done: usize = 0;

        while (done < wanted) {

            if (self.used == self.block) {

                if (!try self.advance()) break;
                continue;

            }

            const count = @min(self.block - self.used, wanted - done);

            self.emit(out[done * self.channels ..][0 .. count * self.channels]);
            self.used += @intCast(count);
            done += count;

        }

        return done;

    }

    /// Moves to sample frame `frame` exactly, or the end, and returns where it landed.
    pub fn seek(self: *Decoder, frame: u64) Error!u64 {

        const target = if (self.frames) |total| @min(frame, total) else frame;
        var from = Point{

            .sample = 0,
            .offset = self.first,

        };

        for (self.points) |point| {

            if (point.sample <= target and point.offset <= self.source.size) from = .{

                .sample = point.sample,
                .offset = self.first + point.offset,

            };

        }

        // Without a nearby point, halving the bytes between finds a frame starting a little before the target.
        if (target - from.sample > 16 * @as(u64, self.stream.largest)) {

            var high = self.source.size;

            while (high - from.offset > 2 * self.stream.ceiling()) {

                const middle = from.offset + (high - from.offset) / 2;
                const found = try self.find(middle) orelse break;

                if (found.sample <= target) from = found else high = middle;

            }

        }

        try self.source.seek(from.offset);
        self.block = 0;
        self.used = 0;

        while (try self.advance()) {

            if (self.start + self.block > target) {

                self.used = @intCast(target -| self.start);
                return self.start + self.used;

            }

        }

        self.used = self.block;

        return self.start + self.block;

    }

    /// The first frame at or after byte `offset` whose header reads true.
    fn find(self: *Decoder, offset: u64) Error!?Point {

        try self.source.seek(offset);

        while (true) {

            const bytes = try self.source.ahead(self.stream.ceiling());

            if (bytes.len < 16) return null;

            var index: usize = 0;

            while (index + 16 <= bytes.len) : (index += 1) {

                const header = Header.parse(bytes[index..], &self.stream) orelse continue;

                return .{

                    .sample = header.first(&self.stream),
                    .offset = self.source.offset() + index,

                };

            }

            try self.source.skip(index);

        }

    }

    /// Decodes the next frame, stepping over any that fail their checks; false at the end.
    fn advance(self: *Decoder) Error!bool {

        while (true) {

            const bytes = try self.source.ahead(self.stream.ceiling());

            if (bytes.len < 10) return false;

            const length = self.decode(bytes) catch |err| switch (err) {

                error.Invalid => {

                    // Steps to the next byte that could start a frame.
                    const next = std.mem.indexOfScalarPos(u8, bytes, 1, 0xff) orelse bytes.len;

                    try self.source.skip(next);
                    continue;

                },
                else => return err,

            };

            try self.source.skip(length);

            return true;

        }

    }

    /// Decodes the frame `bytes` start with into `samples`, returning its length.
    fn decode(self: *Decoder, bytes: []const u8) Error!usize {

        const header = Header.parse(bytes, &self.stream) orelse return error.Invalid;
        const count = header.channels();

        if (count != self.stream.channels or header.block > self.stream.largest or header.bits > 32) return error.Invalid;

        var bits = Bits.init(bytes);

        bits.skip(header.length * 8);

        for (0..count) |channel| {

            // A side channel needs a bit more than the others to hold the difference.
            const side = switch (header.assignment) {

                8, 10 => channel == 1,
                9 => channel == 0,
                else => false,

            };

            try subframe(&bits, self.samples[channel * self.stream.largest ..][0..header.block], header.bits + @intFromBool(side));

        }

        bits.alignByte();

        const length = bits.consumed() + 2;

        if (bits.overrun() or length > bytes.len) return if (bytes.len < self.source.left()) error.Unsupported else error.Invalid;
        if (std.hash.crc.Crc16Umts.hash(bytes[0 .. length - 2]) != std.mem.readInt(u16, bytes[length - 2 ..][0..2], .big)) return error.Invalid;

        if (header.assignment >= 8) self.decorrelate(header);

        self.start = header.first(&self.stream);
        self.block = header.block;
        self.used = 0;
        self.scale = 1 / @as(f32, @floatFromInt(@as(u64, 1) << @intCast(header.bits - 1)));

        return length;

    }

    /// Recovers left and right from the frame's stereo pair.
    fn decorrelate(self: *Decoder, header: Header) void {

        const left = self.samples[0..header.block];
        const right = self.samples[self.stream.largest..][0..header.block];

        switch (header.assignment) {

            8 => for (left, right) |first, *second| {

                second.* = first -% second.*;

            },
            9 => for (left, right) |*first, second| {

                first.* +%= second;

            },
            else => for (left, right) |*first, *second| {

                const side = second.*;
                const middle = first.* << 1 | (side & 1);

                first.* = (middle +% side) >> 1;
                second.* = (middle -% side) >> 1;

            },

        }

    }

    /// Converts the frame's next samples to interleaved stereo or mono in `out`.
    fn emit(self: *const Decoder, out: []f32) void {

        const stride = self.stream.largest;
        const stored = self.stream.channels;
        const frames = out.len / self.channels;

        if (stored <= 2) {

            for (0..stored) |channel| {

                const samples = self.samples[channel * stride + self.used ..][0..frames];

                for (samples, 0..) |value, index| out[index * stored + channel] = @as(f32, @floatFromInt(value)) * self.scale;

            }

            return;

        }

        var values: [speakers.most]f32 = undefined;

        for (0..frames) |index| {

            for (values[0..stored], 0..) |*value, channel| value.* = @as(f32, @floatFromInt(self.samples[channel * stride + self.used + index])) * self.scale;
            out[index * 2 ..][0..2].* = self.downmix.fold(values[0..stored]);

        }

    }

};

/// Decodes one channel's subframe of `out.len` samples, each `size` bits wide.
fn subframe(bits: *Bits, out: []i64, size: u8) Error!void {

    if (bits.bit()) return error.Invalid;

    const kind = bits.read(6);
    var wasted: u8 = 0;

    if (bits.bit()) wasted = @intCast((bits.unary(size) orelse return error.Invalid) + 1);
    if (wasted >= size) return error.Invalid;

    const width = size - wasted;

    switch (kind) {

        0 => @memset(out, literal(bits, width)),
        1 => for (out) |*value| {

            value.* = literal(bits, width);

        },
        8...12 => {

            const order = kind - 8;

            if (order > out.len) return error.Invalid;

            for (out[0..order]) |*value| value.* = literal(bits, width);
            try residual(bits, out, order);
            fixed(out, order);

        },
        32...63 => {

            const order = kind - 31;

            if (order > out.len) return error.Invalid;

            for (out[0..order]) |*value| value.* = literal(bits, width);

            const precision = bits.read(4) + 1;
            const shift = bits.signed(5);

            if (precision == 16 or shift < 0) return error.Invalid;

            var coefficients: [32]i64 = undefined;

            for (coefficients[0..order]) |*coefficient| coefficient.* = bits.signed(@intCast(precision));
            try residual(bits, out, order);
            predict(out, coefficients[0..order], @intCast(shift));

        },
        else => return error.Invalid,

    }

    if (wasted != 0) for (out) |*value| {

        value.* <<= @intCast(wasted);

    };

}

/// A sample of up to 33 bits, as a side channel of 32-bit audio needs.
fn literal(bits: *Bits, width: u8) i64 {

    if (width <= 32) return bits.signed(@intCast(width));

    const high: i64 = bits.signed(@intCast(width - 32));

    return high << 32 | bits.read(32);

}

/// Fills `out` past its first `order` samples with Rice-coded residuals.
fn residual(bits: *Bits, out: []i64, order: usize) Error!void {

    const method = bits.read(2);

    if (method > 1) return error.Invalid;

    const width: u5 = if (method == 0) 4 else 5;
    const escape = (@as(u32, 1) << width) - 1;
    const partitioning: u5 = @intCast(bits.read(4));
    const share = out.len >> partitioning;

    if (share << partitioning != out.len or share < order) return error.Invalid;

    var index = order;

    for (0..@as(usize, 1) << partitioning) |partition| {

        const count = if (partition == 0) share - order else share;
        const parameter = bits.read(width);
        const values = out[index..][0..count];

        if (parameter == escape) {

            const raw: u6 = @intCast(bits.read(5));

            for (values) |*value| value.* = bits.signed(raw);

        } else {

            const k: u5 = @intCast(parameter);

            for (values) |*value| {

                const quotient = bits.unary(@as(u32, 0xffffffff) >> k) orelse return error.Invalid;
                const folded = @as(u64, quotient) << k | bits.read(k);

                value.* = @as(i64, @intCast(folded >> 1)) ^ -@as(i64, @intCast(folded & 1));

            }

        }

        if (bits.overrun()) return error.Invalid;

        index += count;

    }

}

/// Adds the fixed polynomial predictions of `order` to the residuals.
fn fixed(out: []i64, order: usize) void {

    switch (order) {

        1 => for (1..out.len) |i| {

            out[i] +%= out[i - 1];

        },
        2 => for (2..out.len) |i| {

            out[i] +%= 2 *% out[i - 1] -% out[i - 2];

        },
        3 => for (3..out.len) |i| {

            out[i] +%= 3 *% (out[i - 1] -% out[i - 2]) +% out[i - 3];

        },
        4 => for (4..out.len) |i| {

            out[i] +%= 4 *% (out[i - 1] +% out[i - 3]) -% 6 *% out[i - 2] -% out[i - 4];

        },
        else => {

        },

    }

}

/// Adds the linear predictions of `coefficients`, newest sample first, to the residuals.
fn predict(out: []i64, coefficients: []const i64, shift: u6) void {

    for (coefficients.len..out.len) |i| {

        var sum: i64 = 0;

        for (coefficients, 1..) |coefficient, back| sum +%= coefficient *% out[i - back];

        out[i] +%= sum >> shift;

    }

}

/// The speakers FLAC assigns to each number of channels.
fn layout(channels: u8) u32 {

    return switch (channels) {

        3 => 0x7,
        4 => 0x33,
        5 => 0x37,
        6 => 0x3f,
        7 => 0x70f,
        8 => 0x63f,
        else => 0,

    };

}

/// Steps over an ID3v2 tag that some programs put before the stream.
fn skipTag(source: *Source) Error!void {

    const head = try source.peek(10);

    if (head.len < 10 or !std.mem.eql(u8, head[0..3], "ID3")) return;

    var size: u64 = 0;

    for (head[6..10]) |byte| size = size << 7 | (byte & 0x7f);

    try source.skip(10 + size + if (head[5] & 0x10 != 0) @as(u64, 10) else 0);

}

/// Reads the seek table's points, leaving out the placeholders.
fn table(allocator: std.mem.Allocator, source: *Source, length: u24) Error![]Point {

    const count = @min(length / 18, 65536);
    const points = try allocator.alloc(Point, count);
    var kept: usize = 0;

    errdefer allocator.free(points);

    for (0..count) |_| {

        const entry = try source.take(18);
        const number = std.mem.readInt(u64, entry[0..8], .big);

        if (number == std.math.maxInt(u64)) continue;

        points[kept] = .{

            .sample = number,
            .offset = std.mem.readInt(u64, entry[8..16], .big),

        };

        kept += 1;

    }

    try source.skip(length - count * 18);

    return points[0..kept];

}

/// Takes the title and artist from Vorbis comments.
fn comments(body: []const u8, tags: *Tags) void {

    if (body.len < 8) return;

    const vendor = std.mem.readInt(u32, body[0..4], .little);

    if (vendor > body.len - 8) return;

    var position: usize = 4 + vendor;
    const count = std.mem.readInt(u32, body[position..][0..4], .little);

    position += 4;

    for (0..count) |_| {

        if (position + 4 > body.len) return;

        const length = std.mem.readInt(u32, body[position..][0..4], .little);

        position += 4;

        if (length > body.len - position) return;

        const entry = body[position..][0..length];
        const equals = std.mem.indexOfScalar(u8, entry, '=') orelse entry.len;
        const key = entry[0..equals];
        const value = if (equals < entry.len) entry[equals + 1 ..] else "";

        if (std.ascii.eqlIgnoreCase(key, "TITLE")) tags.title.set(value);
        if (std.ascii.eqlIgnoreCase(key, "ARTIST")) tags.artist.set(value);

        position += length;

    }

}

/// Decodes a whole fixture frame by frame, checking its samples against the MD5 the encoder stored.
fn verify(bytes: []const u8) !void {

    const allocator = std.testing.allocator;
    var source = Source.fixed(bytes);
    var decoder = try Decoder.open(allocator, &source);
    var digest = std.crypto.hash.Md5.init(.{});
    var total: u64 = 0;

    defer decoder.deinit(allocator);

    const width = (decoder.stream.bits + 7) / 8;

    while (try decoder.advance()) {

        try std.testing.expectEqual(total, decoder.start);

        for (0..decoder.block) |index| {

            for (0..decoder.stream.channels) |channel| {

                const value = decoder.samples[channel * decoder.stream.largest + index];
                var little: [4]u8 = undefined;

                std.mem.writeInt(u32, &little, @truncate(@as(u64, @bitCast(value))), .little);
                digest.update(little[0..width]);

            }

        }

        total += decoder.block;

    }

    var result: [16]u8 = undefined;

    digest.final(&result);
    try std.testing.expectEqual(decoder.stream.total, total);
    try std.testing.expectEqualSlices(u8, &decoder.stream.signature, &result);

}

test "FLAC fixtures from 8 to 32 bits and up to six channels decode exactly as their MD5s say" {

    for ([_][]const u8{

        @embedFile("fixtures/flac-stereo16.flac"),
        @embedFile("fixtures/flac-mono24.flac"),
        @embedFile("fixtures/flac-mono8.flac"),
        @embedFile("fixtures/flac-surround.flac"),
        @embedFile("fixtures/flac-stereo32.flac"),
        @embedFile("fixtures/flac-tagged.flac"),

    }) |bytes| try verify(bytes);

}

test "FLAC reads tags, scales samples, folds surround, and reads the same through small refills" {

    const allocator = std.testing.allocator;
    const tagged = @embedFile("fixtures/flac-tagged.flac");
    var source = Source.fixed(tagged);
    var decoder = try Decoder.open(allocator, &source);

    defer decoder.deinit(allocator);

    try std.testing.expectEqualStrings("Sweep Test", decoder.tags.title.get());
    try std.testing.expectEqualStrings("Gränite", decoder.tags.artist.get());
    try std.testing.expectEqual(22050, decoder.rate);
    try std.testing.expectEqual(44100, decoder.frames);

    const stereo = @embedFile("fixtures/flac-stereo16.flac");
    var file = @import("source.zig").Chunked{

        .bytes = stereo,
        .piece = 1000,

    };

    var buffer: [8192]u8 = undefined;
    var whole = Source.fixed(stereo);
    var chunked = file.source(&buffer);
    var first = try Decoder.open(allocator, &whole);
    var second = try Decoder.open(allocator, &chunked);

    defer first.deinit(allocator);
    defer second.deinit(allocator);

    const expected = try allocator.alloc(f32, 13230 * 2);
    const actual = try allocator.alloc(f32, 13230 * 2);

    defer allocator.free(expected);
    defer allocator.free(actual);

    try std.testing.expectEqual(13230, try first.read(expected));

    var done: usize = 0;

    while (true) {

        const count = try second.read(actual[done * 2 ..][0..@min(2 * 617, actual.len - done * 2)]);

        if (count == 0) break;
        done += count;

    }

    try std.testing.expectEqual(13230, done);
    try std.testing.expectEqualSlices(f32, expected, actual);

    var peak: f32 = 0;

    for (expected) |value| peak = @max(peak, @abs(value));

    try std.testing.expect(peak > 0.8 and peak < 1);

    const surround = @embedFile("fixtures/flac-surround.flac");
    var multichannel = Source.fixed(surround);
    var folded = try Decoder.open(allocator, &multichannel);

    defer folded.deinit(allocator);

    try std.testing.expectEqual(2, folded.channels);
    try std.testing.expectEqual(2880, try folded.read(actual[0 .. 2880 * 2]));

}

test "FLAC seeks exactly through its seek table and by bisecting a file without one" {

    const allocator = std.testing.allocator;
    const tagged = @embedFile("fixtures/flac-tagged.flac");
    const stripped = try allocator.dupe(u8, tagged);

    defer allocator.free(stripped);

    // Turns the seek table, the block after STREAMINFO, into padding.
    try std.testing.expectEqual(3, stripped[42] & 0x7f);
    stripped[42] = stripped[42] & 0x80 | 1;

    var whole = Source.fixed(tagged);
    var reference = try Decoder.open(allocator, &whole);
    const all = try allocator.alloc(f32, 44100);

    defer reference.deinit(allocator);
    defer allocator.free(all);

    try std.testing.expectEqual(44100, try reference.read(all));

    for ([_][]const u8{ tagged, stripped }) |bytes| {

        var source = Source.fixed(bytes);
        var decoder = try Decoder.open(allocator, &source);

        defer decoder.deinit(allocator);

        try std.testing.expectEqual(bytes.ptr == tagged.ptr, decoder.points.len != 0);

        for ([_]u64{ 30000, 5, 1152, 44099, 20000, 0 }) |target| {

            var out: [64]f32 = undefined;

            try std.testing.expectEqual(target, try decoder.seek(target));

            const count = try decoder.read(&out);

            try std.testing.expectEqual(@min(64, 44100 - target), count);
            try std.testing.expectEqualSlices(f32, all[@intCast(target)..][0..count], out[0..count]);

        }

        try std.testing.expectEqual(44100, try decoder.seek(1 << 40));
        try std.testing.expectEqual(0, try decoder.read(all[0..10]));

    }

}

test "FLAC steps over corrupt frames and never fails on damaged or truncated files" {

    const allocator = std.testing.allocator;
    const original = @embedFile("fixtures/flac-stereo16.flac");
    const damaged = try allocator.dupe(u8, original);
    const out = try allocator.alloc(f32, 4096);

    defer allocator.free(damaged);
    defer allocator.free(out);

    // A flipped bit in the second frame's residuals costs only that frame.
    damaged[damaged.len / 2] ^= 0x10;

    var source = Source.fixed(damaged);
    var decoder = try Decoder.open(allocator, &source);
    var total: usize = 0;

    while (true) {

        const count = try decoder.read(out);

        if (count == 0) break;
        total += count;

    }

    decoder.deinit(allocator);
    try std.testing.expect(total < 13230 and total >= 13230 - 4096);

    var prng = std.Random.DefaultPrng.init(11);

    for (0..300) |round| {

        @memcpy(damaged, original);

        for (0..1 + round % 8) |_| damaged[prng.random().uintLessThan(usize, damaged.len)] = prng.random().int(u8);

        // Damage near the start reaches the metadata too.
        if (round % 3 == 0) damaged[prng.random().uintLessThan(usize, 120)] ^= prng.random().int(u8);

        source = Source.fixed(damaged[0 .. damaged.len - prng.random().uintLessThan(usize, damaged.len / 2)]);

        var broken = Decoder.open(allocator, &source) catch continue;

        defer broken.deinit(allocator);

        while (try broken.read(out) != 0) {

        }

        _ = try broken.seek(prng.random().uintLessThan(u64, 20000));

    }

}
