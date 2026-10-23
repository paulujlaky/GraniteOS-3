//! MPEG program streams, as .mpg and .mpeg files hold them: MPEG-1 system streams and MPEG-2 program streams split back
//! into the video and audio they interleave. A bare MPEG-1 video elementary stream passes through as video.

const std = @import("std");

const Source = @import("source.zig").Source;
const Chunked = @import("source.zig").Chunked;
const Decoder = @import("video.zig").Decoder;
const Kind = @import("video.zig").Kind;

pub const Error = @import("source.zig").Error;

pub const Stream = enum {

    video,
    audio,

};

pub const Packet = struct {

    kind: Stream,

    /// PTS in seconds from the stream's start, when the packet carried one.
    time: ?f64,

    /// Payload; valid until the next call.
    bytes: []const u8,

};

pub const Demuxer = struct {

    /// Whether the file has an MPEG-1 video stream and an MPEG audio stream.
    video: bool,
    audio: bool,

    source: *Source,

    /// The streams chosen: the first video and the first audio stream found.
    video_id: u8 = 0,
    audio_id: u8 = 0,

    /// Whether the file is a bare video elementary stream, and its pictures per second for reading time codes.
    elementary: bool = false,
    rate: f64 = 25,

    /// Where the first pack starts, and the 90 kHz clock reading that counts as time zero.
    first: u64 = 0,
    zero: u64 = 0,

    length: ?f64 = null,

    /// The rest of the payload being handed out, its stream, and its time until the first piece of it goes.
    remaining: u64 = 0,
    current: Stream = .video,
    time: ?f64 = null,

    const Header = struct {

        id: u8,
        time: ?u64,
        length: u64,

    };

    const Unit = union(enum) {

        pack: u64,
        packet: Header,

    };

    const Stamp = struct {

        offset: u64,
        time: u64,

    };

    /// Validates `source` and finds its streams by scanning the first packs.
    pub fn open(source: *Source) Error!Demuxer {

        try source.seek(0);

        var self = Demuxer{

            .video = false,
            .audio = false,
            .source = source,

        };

        const head = try source.peek(12);

        if (head.len >= 12 and std.mem.eql(u8, head[0..4], "\x00\x00\x01\xb3")) {

            var probe = Probe{};

            probe.add(try source.peek(@intCast(@min(source.size, probe.bytes.len))));
            if (probe.result orelse false) return error.Unsupported;

            self.elementary = true;
            self.video = true;
            self.rate = rates[head[7] & 15];

            if (self.rate == 0) return error.Invalid;

            if (try self.stamp(0, scan_limit)) |found| self.zero = found.time;
            self.length = try self.last();

            try source.seek(0);

            return self;

        }

        self.first = try self.sync(1 << 16) orelse return error.Invalid;

        var probe = Probe{};
        var clock: ?u64 = null;
        var video_time: ?u64 = null;
        var audio_time: ?u64 = null;
        var mpeg2 = false;

        while (source.offset() - self.first < scan_limit) {

            const found = try self.unit() orelse break;

            switch (found) {

                .pack => |reading| {

                    if (clock == null) clock = reading;

                },
                .packet => |header| {

                    var feed: ?*Probe = null;

                    if (header.id >= 0xe0 and header.id <= 0xef) {

                        if (self.video_id == 0) self.video_id = header.id;

                        if (header.id == self.video_id) {

                            if (video_time == null) video_time = header.time;
                            if (probe.result == null) feed = &probe;

                        }

                    } else if (header.id >= 0xc0 and header.id <= 0xdf) {

                        if (self.audio_id == 0) self.audio_id = header.id;
                        if (header.id == self.audio_id and audio_time == null) audio_time = header.time;

                    }

                    try self.pass(header.length, feed);

                },

            }

            if (probe.result != null and self.audio_id != 0 and audio_time != null and video_time != null) break;

        }

        if (probe.result) |result| mpeg2 = result;

        self.video = self.video_id != 0 and probe.result != null and !mpeg2;
        self.audio = self.audio_id != 0;

        if (mpeg2) return error.Unsupported;
        if (!self.video and !self.audio) return if (clock != null) error.Unsupported else error.Invalid;

        var zero = clock orelse std.math.maxInt(u64);

        if (self.video and video_time != null) zero = @min(zero, video_time.?);
        if (self.audio and audio_time != null) zero = @min(zero, audio_time.?);

        self.zero = if (zero == std.math.maxInt(u64)) 0 else zero;
        self.length = try self.last();

        try source.seek(self.first);

        return self;

    }

    /// The next payload of the chosen streams, skipping others, padding, and private streams; null at the end.
    pub fn next(self: *Demuxer) Error!?Packet {

        if (self.elementary) {

            const bytes = try self.source.peek(self.window());
            const count = @min(bytes.len, self.window());

            if (count == 0) return null;
            try self.source.skip(count);

            return .{

                .kind = .video,
                .time = null,
                .bytes = bytes[0..count],

            };

        }

        while (true) {

            if (self.remaining > 0) {

                const bytes = try self.source.peek(@intCast(@min(self.remaining, self.window())));
                const count: usize = @intCast(@min(bytes.len, self.remaining));

                if (count == 0) {

                    self.remaining = 0;
                    return null;

                }

                try self.source.skip(count);
                self.remaining -= count;

                const time = self.time;

                self.time = null;

                return .{

                    .kind = self.current,
                    .time = time,
                    .bytes = bytes[0..count],

                };

            }

            const found = try self.unit() orelse return null;

            switch (found) {

                .pack => {},
                .packet => |header| {

                    const video = self.video and header.id == self.video_id;
                    const audio = self.audio and header.id == self.audio_id;

                    if (video or audio) {

                        self.current = if (video) .video else .audio;
                        self.time = if (header.time) |ticks| self.elapsed(ticks) else null;
                        self.remaining = header.length;

                        if (header.length == 0) self.time = null;

                    } else {

                        try self.source.skip(header.length);

                    }

                },

            }

        }

    }

    /// Seconds from the first to the last timestamp, or null when the file's end has none.
    pub fn duration(self: *const Demuxer) ?f64 {

        return self.length;

    }

    /// Moves to a pack at or before `seconds`, by bisecting byte offsets on timestamps, and returns the time it landed on.
    pub fn seek(self: *Demuxer, seconds: f64) Error!f64 {

        self.remaining = 0;
        self.time = null;

        const start = try self.stamp(self.first, scan_limit) orelse {

            try self.source.seek(self.first);
            return 0;

        };

        const target: u64 = if (seconds <= 0) 0 else @intFromFloat(@min(seconds * 90000, 1e15));
        var low = start;
        var high = self.source.size;

        if (self.after(start.time) > target) {

            try self.source.seek(self.first);
            return 0;

        }

        while (high - low.offset > 4096) {

            const middle = low.offset + (high - low.offset) / 2;
            const found = try self.stamp(middle, scan_limit / 4) orelse {

                high = middle;
                continue;

            };

            if (found.offset >= high or self.after(found.time) > target) {

                high = middle;

            } else {

                low = found;

            }

        }

        // Bisection stops a few packs short, so step through those to the last one before the target.
        var cursor = low.offset + 1;

        for (0..64) |_| {

            const found = try self.stamp(cursor, scan_limit / 4) orelse break;

            cursor = self.source.offset();

            if (found.offset <= low.offset) continue;
            if (self.after(found.time) > target) break;
            low = found;

        }

        try self.source.seek(low.offset);

        return @max(self.elapsed(low.time), 0);

    }

    /// How far into the stream 90 kHz clock reading `ticks` lies, wrapping as 33-bit clocks do.
    fn after(self: *const Demuxer, ticks: u64) u64 {

        const difference = (ticks -% self.zero) & clock_mask;

        return if (difference >= 1 << 32) 0 else difference;

    }

    fn elapsed(self: *const Demuxer, ticks: u64) f64 {

        const difference = (ticks -% self.zero) & clock_mask;
        const signed: i64 = if (difference >= 1 << 32) @as(i64, @intCast(difference)) - (1 << 33) else @intCast(difference);

        return @as(f64, @floatFromInt(signed)) / 90000;

    }

    /// The most bytes one peek can hand out.
    fn window(self: *const Demuxer) usize {

        return if (self.source.reader == null) 1 << 16 else self.source.buffer.len;

    }

    /// Reads the pack or packet header at the reading position, moving past it; resyncs past anything else, null at the end.
    fn unit(self: *Demuxer) Error!?Unit {

        while (true) {

            const head = try self.source.peek(4);

            if (head.len < 4) {

                try self.source.skip(head.len);
                return null;

            }

            if (head[0] != 0 or head[1] != 0 or head[2] != 1 or head[3] < 0xb9) {

                if (!try self.resync()) return null;
                continue;

            }

            const code = head[3];

            if (code == 0xb9) {

                try self.source.skip(4);
                continue;

            }

            if (code == 0xba) {

                const pack = try self.source.peek(14);

                if (pack.len >= 14 and pack[4] >> 6 == 1) {

                    try self.source.skip(14 + @as(u64, pack[13] & 7));

                    return .{ .pack = (@as(u64, pack[4] >> 3 & 7) << 30) | (@as(u64, pack[4] & 3) << 28) | (@as(u64, pack[5]) << 20) | (@as(u64, pack[6] >> 3) << 15) | (@as(u64, pack[6] & 3) << 13) | (@as(u64, pack[7]) << 5) | (pack[8] >> 3) };

                }

                if (pack.len >= 12 and pack[4] >> 4 == 2) {

                    try self.source.skip(12);

                    return .{ .pack = timestamp(pack[4..9]) };

                }

                try self.source.skip(4);
                continue;

            }

            const packet = try self.source.peek(6);

            if (packet.len < 6) {

                try self.source.skip(packet.len);
                return null;

            }

            const total = 6 + @as(u64, std.mem.readInt(u16, packet[4..6], .big));

            // System headers, stream maps, padding, private and other streams carry nothing chosen.
            if (code < 0xc0 or code >= 0xf0) {

                try self.source.skip(total);
                continue;

            }

            if (try self.pes(code, total)) |header| return .{ .packet = header };

        }

    }

    /// Reads the header of the PES packet of `total` bytes at the reading position, MPEG-1 or MPEG-2 style.
    fn pes(self: *Demuxer, code: u8, total: u64) Error!?Header {

        const wanted: usize = @intCast(@min(total, 6 + 3 + 255));
        const bytes = try self.source.peek(wanted);

        if (bytes.len < wanted) {

            try self.source.skip(total);
            return null;

        }

        var at: usize = 6;
        var time: ?u64 = null;

        if (wanted > 6 and bytes[6] >> 6 == 2) {

            if (wanted < 9 or 9 + @as(usize, bytes[8]) > wanted) {

                try self.source.skip(total);
                return null;

            }

            if (bytes[7] & 0x80 != 0 and bytes[8] >= 5) time = timestamp(bytes[9..14]);
            at = 9 + @as(usize, bytes[8]);

        } else {

            while (at < wanted and at < 6 + 16 and bytes[at] == 0xff) at += 1;

            if (at < wanted and bytes[at] >> 6 == 1) at += 2;

            if (at >= wanted) {

                try self.source.skip(total);
                return null;

            }

            switch (bytes[at] >> 4) {

                2 => if (at + 5 <= wanted) {

                    time = timestamp(bytes[at..][0..5]);
                    at += 5;

                } else {

                    at = wanted + 1;

                },
                3 => if (at + 10 <= wanted) {

                    time = timestamp(bytes[at..][0..5]);
                    at += 10;

                } else {

                    at = wanted + 1;

                },
                else => at = if (bytes[at] == 0x0f) at + 1 else wanted + 1,

            }

            if (at > wanted) {

                try self.source.skip(total);
                return null;

            }

        }

        try self.source.skip(at);

        return .{

            .id = code,
            .time = time,
            .length = total - at,

        };

    }

    /// Moves past `count` payload bytes, showing them to `probe` first when there is one.
    fn pass(self: *Demuxer, count: u64, probe: ?*Probe) Error!void {

        var left = count;

        if (probe) |sniffer| {

            while (left > 0 and sniffer.result == null) {

                const bytes = try self.source.peek(@intCast(@min(left, self.window())));
                const piece: usize = @intCast(@min(bytes.len, left));

                if (piece == 0) return;

                sniffer.add(bytes[0..piece]);
                try self.source.skip(piece);
                left -= piece;

            }

        }

        try self.source.skip(left);

    }

    /// Moves to the next byte that could begin a start code of the system layer; false at the end.
    fn resync(self: *Demuxer) Error!bool {

        try self.source.skip(1);

        while (true) {

            const bytes = try self.source.peek(@min(self.window(), 4096));

            if (bytes.len < 4) {

                try self.source.skip(bytes.len);
                return false;

            }

            var index: usize = 0;

            while (std.mem.indexOfPos(u8, bytes, index, "\x00\x00\x01")) |at| {

                if (at + 3 >= bytes.len) break;

                if (bytes[at + 3] >= 0xb9) {

                    try self.source.skip(at);
                    return true;

                }

                index = at + 1;

            }

            try self.source.skip(bytes.len - 3);

        }

    }

    /// Moves to the next pack header within `limit` bytes and returns where it starts.
    fn sync(self: *Demuxer, limit: u64) Error!?u64 {

        const start = self.source.offset();

        while (self.source.offset() - start < limit) {

            const bytes = try self.source.peek(@min(self.window(), 4096));

            if (bytes.len < 5) return null;

            var index: usize = 0;

            while (std.mem.indexOfPos(u8, bytes, index, "\x00\x00\x01\xba")) |at| {

                if (at + 4 >= bytes.len) break;

                const kind = bytes[at + 4];

                if (kind >> 6 == 1 or kind >> 4 == 2) {

                    try self.source.skip(at);
                    return self.source.offset();

                }

                index = at + 1;

            }

            try self.source.skip(bytes.len - 4);

        }

        return null;

    }

    /// The first timestamp at or after `offset` and where to land for it: a PTS of the timing stream, or a group's time code.
    fn stamp(self: *Demuxer, offset: u64, limit: u64) Error!?Stamp {

        try self.source.seek(offset);

        if (self.elementary) return self.group(limit);

        const pack = try self.sync(limit) orelse return null;
        const timing = if (self.video) self.video_id else self.audio_id;

        while (self.source.offset() - pack < limit) {

            const found = try self.unit() orelse return null;

            switch (found) {

                .pack => {},
                .packet => |header| {

                    if (header.id == timing) {

                        if (header.time) |time| {

                            return .{

                                .offset = pack,
                                .time = time,

                            };

                        }

                    }

                    try self.source.skip(header.length);

                },

            }

        }

        return null;

    }

    /// The next group of pictures header within `limit` bytes, its time code read as 90 kHz ticks.
    fn group(self: *Demuxer, limit: u64) Error!?Stamp {

        const start = self.source.offset();

        // A sequence header right before the group, where decoding can start.
        var header: ?u64 = null;

        while (self.source.offset() - start < limit) {

            const bytes = try self.source.peek(@min(self.window(), 4096));

            if (bytes.len < 8) return null;

            var index: usize = 0;
            var used = bytes.len - 7;

            while (std.mem.indexOfPos(u8, bytes, index, "\x00\x00\x01")) |at| {

                if (at + 8 > bytes.len) {

                    used = at;
                    break;

                }

                const place = self.source.offset() + at;

                switch (bytes[at + 3]) {

                    0xb3 => header = place,
                    0xb8 => {

                        const code = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .big);
                        const hours: u64 = code >> 26 & 31;
                        const minutes: u64 = code >> 20 & 63;
                        const whole: u64 = code >> 13 & 63;
                        const pictures: f64 = @floatFromInt(code >> 7 & 63);

                        const landing = header orelse try self.preceding(place);

                        try self.source.seek(place + 4);

                        return .{

                            .offset = landing,
                            .time = (hours * 3600 + minutes * 60 + whole) * 90000 + @as(u64, @intFromFloat(pictures * 90000 / self.rate)),

                        };

                    },
                    0xb2, 0xb5 => {},
                    else => header = null,

                }

                index = at + 3;

            }

            try self.source.skip(used);

        }

        return null;

    }

    /// Where the sequence header just before the group header at `place` starts, or `place` when there is none.
    fn preceding(self: *Demuxer, place: u64) Error!u64 {

        const from = place -| @min(1024, self.window());

        try self.source.seek(from);

        const length: usize = @intCast(place - from);
        const bytes = try self.source.peek(length);
        var found = place;
        var index: usize = 0;

        while (std.mem.indexOfPos(u8, bytes[0..@min(length, bytes.len)], index, "\x00\x00\x01")) |at| {

            if (at + 3 >= length) break;

            switch (bytes[at + 3]) {

                0xb3 => found = from + at,
                0xb2, 0xb5 => {},
                else => found = place,

            }

            index = at + 3;

        }

        return found;

    }

    /// Seconds from time zero to the latest timestamp near the file's end.
    fn last(self: *Demuxer) Error!?f64 {

        const tail = 256 * 1024;
        const from = @max(self.first, self.source.size -| tail);
        var latest: ?u64 = null;

        try self.source.seek(from);

        if (self.elementary) {

            while (try self.group(tail)) |found| latest = found.time;

        } else {

            _ = try self.sync(tail) orelse return null;

            while (try self.unit()) |found| {

                switch (found) {

                    .pack => {},
                    .packet => |header| {

                        const chosen = (self.video and header.id == self.video_id) or (self.audio and header.id == self.audio_id);

                        if (chosen and header.time != null) {

                            if (latest == null or self.after(header.time.?) > self.after(latest.?)) latest = header.time;

                        }

                        try self.source.skip(header.length);

                    },

                }

            }

        }

        return if (latest) |time| self.elapsed(time) else null;

    }

};

const clock_mask = (1 << 33) - 1;

/// Bytes scanned from the start to find the streams.
const scan_limit = 1 << 20;

const rates = [16]f64{ 0, 24000.0 / 1001.0, 24, 25, 30000.0 / 1001.0, 30, 50, 60000.0 / 1001.0, 60, 0, 0, 0, 0, 0, 0, 0 };

/// A 33-bit PTS or MPEG-1 SCR in its five-byte form.
fn timestamp(bytes: []const u8) u64 {

    return (@as(u64, bytes[0] >> 1 & 7) << 30) | (@as(u64, bytes[1]) << 22) | (@as(u64, bytes[2] >> 1) << 15) | (@as(u64, bytes[3]) << 7) | (bytes[4] >> 1);

}

/// Watches the start of a video stream for its sequence header and whether an MPEG-2 sequence extension follows it.
const Probe = struct {

    bytes: [256]u8 = undefined,
    length: usize = 0,

    /// Whether `bytes` starts with the sequence header's start code.
    found: bool = false,

    /// Whether the stream is MPEG-2, once known.
    result: ?bool = null,

    fn add(self: *Probe, piece: []const u8) void {

        var rest = piece;

        while (rest.len > 0 and self.result == null) {

            const count = @min(self.bytes.len - self.length, rest.len);

            @memcpy(self.bytes[self.length..][0..count], rest[0..count]);
            self.length += count;
            rest = rest[count..];
            self.examine();

        }

    }

    fn examine(self: *Probe) void {

        if (!self.found) {

            const at = std.mem.indexOf(u8, self.bytes[0..self.length], "\x00\x00\x01\xb3") orelse {

                const kept = @min(self.length, 3);

                std.mem.copyForwards(u8, self.bytes[0..kept], self.bytes[self.length - kept .. self.length]);
                self.length = kept;
                return;

            };

            std.mem.copyForwards(u8, self.bytes[0 .. self.length - at], self.bytes[at..self.length]);
            self.length -= at;
            self.found = true;

        }

        if (std.mem.indexOfPos(u8, self.bytes[0..self.length], 4, "\x00\x00\x01")) |at| {

            if (at + 3 < self.length) self.result = self.bytes[at + 3] == 0xb5;

        } else if (self.length == self.bytes.len) {

            self.result = false;

        }

    }

};

const gop_file = @embedFile("fixtures/video-gop.mpg");
const sif_file = @embedFile("fixtures/video-sif.mpg");
const odd_file = @embedFile("fixtures/video-odd.m1v");
const long_file = @embedFile("fixtures/system-long.mpg");
const mpeg2_file = @embedFile("fixtures/system-mpeg2.mpg");

/// Everything a demuxer hands out, stream by stream: the bytes joined up and the times given.
const Split = struct {

    video: std.ArrayList(u8) = .empty,
    audio: std.ArrayList(u8) = .empty,
    video_times: std.ArrayList(f64) = .empty,
    audio_times: std.ArrayList(f64) = .empty,

    fn read(allocator: std.mem.Allocator, demuxer: *Demuxer) !Split {

        var split = Split{};

        while (try demuxer.next()) |packet| {

            const bytes, const times = switch (packet.kind) {

                .video => .{ &split.video, &split.video_times },
                .audio => .{ &split.audio, &split.audio_times },

            };

            try bytes.appendSlice(allocator, packet.bytes);
            if (packet.time) |time| try times.append(allocator, time);

        }

        return split;

    }

};

test "demuxer splits MPEG-1 system and MPEG-2 program streams into video and audio" {

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();

    const allocator = arena.allocator();

    // Each file with the length and CRC-32 of the streams ffmpeg copies out of it and their first PTS as ffprobe gives it.
    const cases = [_]struct { []const u8, usize, u32, usize, u32, f64, f64 }{

        .{ gop_file, 32398, 0xe2bfe18e, 4032, 0x3ccd2402, 0.54, 0.524967 },
        .{ sif_file, 32299, 0xbf03bd04, 2496, 0x260ea47a, 0.533367, 0.523344 },
        .{ long_file, 27014, 0xcacb8b76, 24048, 0xeb873fa8, 0.54, 0.524967 },

    };

    for (cases) |case| {

        const file, const video_length, const video_crc, const audio_length, const audio_crc, const video_start, const audio_start = case;
        var input = Source.fixed(file);
        var demuxer = try Demuxer.open(&input);

        try std.testing.expect(demuxer.video and demuxer.audio);

        const split = try Split.read(allocator, &demuxer);

        try std.testing.expectEqual(video_length, split.video.items.len);
        try std.testing.expectEqual(video_crc, std.hash.Crc32.hash(split.video.items));
        try std.testing.expectEqual(audio_length, split.audio.items.len);
        try std.testing.expectEqual(audio_crc, std.hash.Crc32.hash(split.audio.items));

        try std.testing.expectApproxEqAbs(video_start, split.video_times.items[0], 1e-5);
        try std.testing.expectApproxEqAbs(audio_start, split.audio_times.items[0], 1e-5);

        for (split.audio_times.items[1..], split.audio_times.items[0 .. split.audio_times.items.len - 1]) |later, earlier| try std.testing.expect(later > earlier);
        for (split.video_times.items) |time| try std.testing.expect(time >= video_start - 1e-5);

        try std.testing.expectEqual(null, try demuxer.next());

    }

}

test "demuxer passes a bare video elementary stream through and seeks it by time code" {

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();

    const allocator = arena.allocator();
    var input = Source.fixed(odd_file);
    var demuxer = try Demuxer.open(&input);

    try std.testing.expect(demuxer.video and !demuxer.audio);

    const split = try Split.read(allocator, &demuxer);

    try std.testing.expectEqualSlices(u8, odd_file, split.video.items);
    try std.testing.expectEqual(0, split.video_times.items.len);

    // Time codes count from each group's first picture in display order: the B pictures before I pictures 6 and 12.
    try std.testing.expectApproxEqAbs(0.44, demuxer.duration().?, 1e-9);
    try std.testing.expectApproxEqAbs(0.2, try demuxer.seek(0.3), 1e-9);

    const packet = (try demuxer.next()).?;

    // It lands on the sequence header repeated before the group, where a decoder can start.
    try std.testing.expectEqualSlices(u8, "\x00\x00\x01\xb3", packet.bytes[0..4]);
    try std.testing.expectEqual(0, try demuxer.seek(0.1));
    try std.testing.expectEqualSlices(u8, odd_file[0..64], (try demuxer.next()).?.bytes[0..64]);

}

test "demuxer finds the duration from the end of the file" {

    // Each file with where ffprobe says it ends: its start time plus its duration.
    for ([_]struct { []const u8, f64 }{ .{ gop_file, 0.524967 + 0.995033 }, .{ long_file, 0.524967 + 5.835033 }, .{ sif_file, 0.523344 + 0.293634 } }) |case| {

        var input = Source.fixed(case[0]);
        const demuxer = try Demuxer.open(&input);

        try std.testing.expectApproxEqAbs(case[1], demuxer.duration().?, 0.05);

    }

}

test "demuxer seeks to a pack before the target and decoding resumes at an I picture" {

    var input = Source.fixed(long_file);
    var demuxer = try Demuxer.open(&input);
    var decoder = Decoder.init(std.testing.allocator);

    defer decoder.deinit(std.testing.allocator);

    // A group is 12 pictures at 25 per second.
    const group = 12.0 / 25.0;

    for ([_]f64{ 0, 1.3, 2.9, 4.4, 5.9, 3.1, 0.7 }) |target| {

        const landed = try demuxer.seek(target);

        try std.testing.expect(landed <= target + 1e-9);
        try std.testing.expect(landed >= target - group);

        decoder.reset();

        const first = shown: while (try demuxer.next()) |packet| {

            if (packet.kind != .video) continue;

            try decoder.feed(std.testing.allocator, packet.bytes, packet.time);

            if (try decoder.next(false)) |picture| break :shown picture;

        } else return error.TestUnexpectedResult;

        try std.testing.expectEqual(Kind.intra, first.kind);
        try std.testing.expect(@abs(first.time - @max(target, 0.54)) <= group);

    }

    try std.testing.expectEqual(0, try demuxer.seek(-3));
    try std.testing.expect(try demuxer.seek(1000) <= demuxer.duration().?);

}

test "demuxer reads the same packets through a small window as from memory" {

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();

    const allocator = arena.allocator();

    for ([_][]const u8{ gop_file, sif_file, odd_file }) |file| {

        var whole = Source.fixed(file);
        var memory = try Demuxer.open(&whole);
        var chunked = Chunked{

            .bytes = file,
            .piece = 37,

        };

        var buffer: [1024]u8 = undefined;
        var windowed = chunked.source(&buffer);
        var small = try Demuxer.open(&windowed);

        try std.testing.expectEqual(memory.duration(), small.duration());

        const expected = try Split.read(allocator, &memory);
        const got = try Split.read(allocator, &small);

        try std.testing.expectEqualSlices(u8, expected.video.items, got.video.items);
        try std.testing.expectEqualSlices(u8, expected.audio.items, got.audio.items);
        try std.testing.expectEqualSlices(f64, expected.video_times.items, got.video_times.items);
        try std.testing.expectEqualSlices(f64, expected.audio_times.items, got.audio_times.items);

        try std.testing.expectEqual(try memory.seek(0.6), try small.seek(0.6));

    }

}

test "demuxer rejects MPEG-2 video and files that are not program streams" {

    var mpeg2 = Source.fixed(mpeg2_file);

    try std.testing.expectError(error.Unsupported, Demuxer.open(&mpeg2));

    for ([_][]const u8{ "", "\x00\x00\x01", "plain text, not a stream", &(.{0} ** 70000) }) |bytes| {

        var input = Source.fixed(bytes);

        try std.testing.expectError(error.Invalid, Demuxer.open(&input));

    }

}

test "demuxer resyncs over garbage and survives corrupt and truncated files" {

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();

    const allocator = arena.allocator();
    var prng = std.Random.DefaultPrng.init(0x1ba);
    const random = prng.random();

    // Junk spliced in between two packs is skipped without losing a byte of either stream.
    const pack = std.mem.indexOfPos(u8, gop_file, 10000, "\x00\x00\x01\xba").?;
    var junk: [1000]u8 = undefined;

    random.bytes(&junk);

    const spliced = try std.mem.concat(allocator, u8, &.{ gop_file[0..pack], &junk, gop_file[pack..] });
    var clean = Source.fixed(gop_file);
    var dirty = Source.fixed(spliced);
    var expected = try Demuxer.open(&clean);
    var got = try Demuxer.open(&dirty);

    const before = try Split.read(allocator, &expected);
    const after = try Split.read(allocator, &got);

    try std.testing.expectEqualSlices(u8, before.video.items, after.video.items);
    try std.testing.expectEqualSlices(u8, before.audio.items, after.audio.items);

    for ([_][]const u8{ gop_file, sif_file, long_file, odd_file, mpeg2_file }) |file| {

        for (0..60) |round| {

            const bytes = try allocator.dupe(u8, file);
            var length = bytes.len;

            switch (round % 3) {

                0 => for (0..random.intRangeAtMost(usize, 1, 60)) |_| {

                    bytes[random.uintLessThan(usize, bytes.len)] = random.int(u8);

                },
                1 => length = random.uintLessThan(usize, bytes.len),
                else => {

                    const at = random.uintLessThan(usize, bytes.len - 512);

                    random.bytes(bytes[at..][0..random.uintAtMost(usize, 512)]);

                },

            }

            // Every other file goes through a small window refilled in uneven pieces.
            var chunked = Chunked{

                .bytes = bytes[0..length],
                .piece = random.intRangeAtMost(usize, 1, 700),

            };

            var buffer: [512]u8 = undefined;
            var input = if (round % 2 == 0) Source.fixed(bytes[0..length]) else chunked.source(&buffer);
            var demuxer = Demuxer.open(&input) catch continue;
            var count: usize = 0;

            _ = demuxer.duration();

            while (demuxer.next() catch null) |packet| : (count += 1) {

                try std.testing.expect(packet.bytes.len > 0);
                if (count % 50 == 7) _ = demuxer.seek(random.float(f64) * 8) catch 0;
                if (count > 2000) break;

            }

        }

    }

}
