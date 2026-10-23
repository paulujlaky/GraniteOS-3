//! MPEG-1 video (ISO 11172-2): an elementary stream decoded picture by picture and handed out in display order.

const std = @import("std");

const Bits = @import("bits.zig").Bits;
const Source = @import("source.zig").Source;
const Demuxer = @import("system.zig").Demuxer;

pub const Error = @import("source.zig").Error;

/// What the sequence header says about every picture that follows it.
pub const Sequence = struct {

    width: u32,
    height: u32,

    /// Pictures per second.
    rate: f64,

};

/// How a picture was coded: on its own, from the reference before it, from references on both sides, or as DC terms only.
pub const Kind = enum(u3) {

    intra = 1,
    predicted = 2,
    bidirectional = 3,
    dc = 4,

};

/// A decoded picture in 4:2:0 YCbCr, as planes that may run wider and taller than the display size.
pub const Picture = struct {

    /// Display size from the sequence header.
    width: u32,
    height: u32,

    /// Luma row length: the coded width, a multiple of 16; chroma rows are half as long.
    stride: u32,

    y: []const u8,
    cb: []const u8,
    cr: []const u8,

    /// Seconds: the PTS given with it, else the previous picture's time plus one picture period.
    time: f64,

    kind: Kind,

    /// Writes width * height opaque 0xFFRRGGBB pixels row after row, from BT.601 studio range to full range RGB.
    pub fn convert(self: *const Picture, pixels: []u32) void {

        const width: usize = self.width;
        const stride: usize = self.stride;
        const chroma = stride / 2;

        if (width == 0 or stride % 16 != 0 or stride < width) return;

        const height = @min(self.height, pixels.len / width);
        const lines = (height + 1) / 2;

        if (self.y.len < stride * height or self.cb.len < chroma * lines or self.cr.len < chroma * lines) return;

        const Wide = @Vector(16, i32);
        const Half = @Vector(8, i32);
        const doubled = [16]i32{ 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7 };
        const shift: @Vector(16, u5) = @splat(16);
        const by_sixteen: @Vector(16, u5) = @splat(16);
        const by_eight: @Vector(16, u5) = @splat(8);
        const top: Wide = @splat(255);
        const bottom: Wide = @splat(0);

        var row: usize = 0;

        while (row < height) : (row += 2) {

            const pair = @min(2, height - row);
            var x: usize = 0;

            while (x < width) : (x += 16) {

                const at = row / 2 * chroma + x / 2;
                const blue: @Vector(8, u8) = self.cb[at..][0..8].*;
                const red: @Vector(8, u8) = self.cr[at..][0..8].*;
                const u = @as(Half, @intCast(blue)) - @as(Half, @splat(128));
                const v = @as(Half, @intCast(red)) - @as(Half, @splat(128));
                const round: Half = @splat(1 << 15);

                const red_offset = @shuffle(i32, v * @as(Half, @splat(cr_red)) + round, undefined, doubled);
                const green_offset = @shuffle(i32, round - u * @as(Half, @splat(cb_green)) - v * @as(Half, @splat(cr_green)), undefined, doubled);
                const blue_offset = @shuffle(i32, u * @as(Half, @splat(cb_blue)) + round, undefined, doubled);

                for (0..pair) |line| {

                    const start = (row + line) * stride + x;
                    const luma: @Vector(16, u8) = self.y[start..][0..16].*;
                    const scaled = (@as(Wide, @intCast(luma)) - @as(Wide, @splat(16))) * @as(Wide, @splat(luma_scale));

                    const r: @Vector(16, u32) = @intCast(@min(@max((scaled + red_offset) >> shift, bottom), top));
                    const g: @Vector(16, u32) = @intCast(@min(@max((scaled + green_offset) >> shift, bottom), top));
                    const b: @Vector(16, u32) = @intCast(@min(@max((scaled + blue_offset) >> shift, bottom), top));
                    const opaque_black: @Vector(16, u32) = @splat(0xff000000);
                    const out: [16]u32 = opaque_black | r << by_sixteen | g << by_eight | b;

                    const count = @min(16, width - x);
                    const place = (row + line) * width + x;

                    @memcpy(pixels[place..][0..count], out[0..count]);

                }

            }

        }

    }

};

/// BT.601 studio swing to full range, scaled by 2^16.
const luma_scale: i32 = @intFromFloat(@round(255.0 / 219.0 * 65536.0));
const cr_red: i32 = @intFromFloat(@round(255.0 / 224.0 * 1.402 * 65536.0));
const cb_green: i32 = @intFromFloat(@round(255.0 / 224.0 * 1.772 * 0.114 / 0.587 * 65536.0));
const cr_green: i32 = @intFromFloat(@round(255.0 / 224.0 * 1.402 * 0.299 / 0.587 * 65536.0));
const cb_blue: i32 = @intFromFloat(@round(255.0 / 224.0 * 1.772 * 65536.0));

pub const Decoder = struct {

    allocator: std.mem.Allocator,

    /// Stream bytes fed and not yet decoded, from `start` on; `base` counts the bytes dropped before them.
    data: std.ArrayList(u8) = .empty,
    start: usize = 0,
    base: u64 = 0,

    /// How far the search for the end of the unit at `start` has come, so waiting for more bytes rescans nothing.
    scanned: usize = 0,

    /// PTS values waiting for the picture that starts at or after their stream offset.
    stamps: [32]Stamp = undefined,
    pending: usize = 0,

    header: ?Header = null,

    /// One allocation holding three frames and the map of macroblocks a picture decoded.
    memory: []u8 = &.{},
    frames: [3]Frame = undefined,
    done: []u8 = &.{},

    /// Frames 0 and 1 take turns as the newer and older reference; frame 2 holds B and D pictures.
    newer: ?u2 = null,
    older: ?u2 = null,

    /// Whether the newer reference still waits to be shown.
    held: bool = false,

    /// The latest group of pictures: its count, whether it is closed or has a broken link, and references decoded in it.
    group: u32 = 0,
    closed: bool = false,
    broken: bool = false,
    references: u32 = 0,

    /// Pictures the latest group has numbered so far: one past its highest temporal reference.
    span: u32 = 0,

    /// A sequence header came last, so an extension now would mean MPEG-2.
    extension: bool = false,

    /// When the latest timed picture says its group started, to time pictures that come without one.
    anchor: ?Anchor = null,
    last: ?f64 = null,

    shown: Picture = undefined,
    block: [64]i32 align(32) = @splat(0),

    const Stamp = struct {

        offset: u64,
        time: f64,

    };

    const Anchor = struct {

        group: u32,
        time: f64,

    };

    const Unit = struct {

        code: u8,
        at: usize,
        end: usize,

    };

    /// Frame buffers are allocated from `allocator` once a sequence header gives the size.
    pub fn init(allocator: std.mem.Allocator) Decoder {

        return .{

            .allocator = allocator,

        };

    }

    /// `allocator` must be the one `feed` was given.
    pub fn deinit(self: *Decoder, allocator: std.mem.Allocator) void {

        self.data.deinit(allocator);
        self.allocator.free(self.memory);
        self.* = undefined;

    }

    /// Appends elementary-stream bytes; `time` is the PTS (seconds) of the first picture that starts in them, when the packet carried one.
    pub fn feed(self: *Decoder, allocator: std.mem.Allocator, bytes: []const u8, time: ?f64) Error!void {

        if (self.start > 0 and self.start >= self.data.items.len / 2) {

            const kept = self.data.items.len - self.start;

            std.mem.copyForwards(u8, self.data.items[0..kept], self.data.items[self.start..]);
            self.data.shrinkRetainingCapacity(kept);
            self.base += self.start;
            self.scanned -|= self.start;
            self.start = 0;

        }

        if (time) |seconds| {

            if (self.pending == self.stamps.len) {

                std.mem.copyForwards(Stamp, self.stamps[0 .. self.pending - 1], self.stamps[1..self.pending]);
                self.pending -= 1;

            }

            self.stamps[self.pending] = .{

                .offset = self.base + self.data.items.len,
                .time = seconds,

            };

            self.pending += 1;

        }

        try self.data.appendSlice(allocator, bytes);

    }

    pub fn sequence(self: *const Decoder) ?Sequence {

        const header = self.header orelse return null;

        return .{

            .width = header.width,
            .height = header.height,
            .rate = header.rate,

        };

    }

    /// Drops buffered bytes and reference pictures, as after a seek; output resumes at the next I picture.
    pub fn reset(self: *Decoder) void {

        self.base += self.data.items.len;
        self.data.clearRetainingCapacity();
        self.start = 0;
        self.scanned = 0;
        self.pending = 0;

        self.newer = null;
        self.older = null;
        self.held = false;

        self.closed = false;
        self.broken = false;
        self.references = 0;
        self.extension = false;

        self.anchor = null;
        self.last = null;
        self.span = 0;

    }

    /// The next picture in display order, or null until more bytes arrive; once `ending`, decodes what is left and shows the last reference picture. The picture stays valid until the next call.
    pub fn next(self: *Decoder, ending: bool) Error!?*const Picture {

        while (self.unit(ending)) |found| {

            const body = self.data.items[found.at + 4 .. found.end];
            const extension = self.extension;

            self.start = found.end;
            self.scanned = 0;
            self.extension = false;

            switch (found.code) {

                0xb3 => {

                    const header = parse(body) catch continue;

                    if (self.header) |current| {

                        if (current.width != header.width or current.height != header.height) {

                            if (self.held) {

                                // Shows the last picture of the old size first, then reads this header again.
                                self.start = found.at;
                                self.held = false;

                                return self.show(self.newer.?);

                            }

                            try self.allocate(header);

                        }

                    } else {

                        try self.allocate(header);

                    }

                    self.header = header;
                    self.extension = true;

                },
                0xb5 => if (extension) return error.Unsupported,
                0xb7 => if (self.held) {

                    self.held = false;

                    return self.show(self.newer.?);

                },
                0xb8 => {

                    var bits = Bits.init(body);

                    bits.skip(25);
                    self.closed = bits.bit();
                    self.broken = bits.bit();
                    self.advance();
                    self.references = 0;

                },
                0x00 => if (self.picture(body, self.base + found.at)) |shown| return shown,
                else => {},

            }

        }

        if (ending and self.held) {

            self.held = false;

            return self.show(self.newer.?);

        }

        return null;

    }

    /// The start code at or after `start` and where its unit ends, or null while the end has not arrived.
    fn unit(self: *Decoder, ending: bool) ?Unit {

        const items = self.data.items;

        const at = find(items, self.start) orelse {

            self.start = if (ending) items.len else @max(self.start, items.len -| 3);
            return null;

        };

        self.start = at;

        if (at + 4 > items.len) {

            if (ending) self.start = items.len;
            return null;

        }

        const code = items[at + 3];
        var search = @max(self.scanned, at + 4);

        while (find(items, search)) |place| {

            if (place + 4 > items.len) break;

            if (code != 0x00 or !within(items[place + 3])) {

                return .{

                    .code = code,
                    .at = at,
                    .end = place,

                };

            }

            search = place + 3;

        }

        // A unit that never ends is decoded anyway once it grows past any real picture.
        if (ending or items.len - at > 1 << 24) {

            return .{

                .code = code,
                .at = at,
                .end = items.len,

            };

        }

        self.scanned = @max(at + 4, items.len -| 3);

        return null;

    }

    /// Frees the frames of an earlier size and allocates them for `header`, all in one piece.
    fn allocate(self: *Decoder, header: Header) Error!void {

        const luma = header.columns * 16 * header.rows * 16;
        const frame = luma + luma / 2;
        const count = header.columns * header.rows;

        self.allocator.free(self.memory);
        self.memory = &.{};
        self.header = null;

        self.memory = try self.allocator.alloc(u8, 3 * frame + count);

        for (&self.frames, 0..) |*slot, index| {

            const base = self.memory[index * frame ..][0..frame];

            slot.* = .{

                .y = base[0..luma],
                .cb = base[luma..][0 .. luma / 4],
                .cr = base[luma + luma / 4 ..][0 .. luma / 4],

            };

            @memset(slot.y, 16);
            @memset(slot.cb, 128);
            @memset(slot.cr, 128);

        }

        self.done = self.memory[3 * frame ..][0..count];
        self.newer = null;
        self.older = null;
        self.held = false;

    }

    /// The PTS given for the picture starting at stream `offset`, dropping any meant for earlier bytes.
    fn stamp(self: *Decoder, offset: u64) ?f64 {

        var found: ?f64 = null;
        var used: usize = 0;

        while (used < self.pending and self.stamps[used].offset <= offset) : (used += 1) found = self.stamps[used].time;

        std.mem.copyForwards(Stamp, self.stamps[0 .. self.pending - used], self.stamps[used..self.pending]);
        self.pending -= used;

        return found;

    }

    /// Decodes the picture whose header and slices are `body`, returning one to show now if there is one.
    fn picture(self: *Decoder, body: []const u8, offset: u64) ?*const Picture {

        var bits = Bits.init(body);
        const time = self.stamp(offset);

        const order = bits.read(10);
        const code = bits.read(3);
        var forward = Vector{};
        var backward = Vector{};

        bits.skip(16);
        self.span = @max(self.span, order + 1);

        if (code == 2 or code == 3) forward = Vector.read(&bits) orelse return null;
        if (code == 3) backward = Vector.read(&bits) orelse return null;

        while (bits.bit()) bits.skip(8);

        if (self.header == null) return null;

        const header = &self.header.?;

        if (time) |seconds| {

            self.anchor = .{

                .group = self.group,
                .time = seconds - @as(f64, @floatFromInt(order)) / header.rate,

            };

        }

        if (bits.overrun() or code < 1 or code > 4) return null;

        const kind: Kind = @enumFromInt(code);
        const leading = self.references < 2;

        var past: ?*const Frame = null;
        var future: ?*const Frame = null;
        var target: u2 = 2;

        switch (kind) {

            .intra, .predicted => {

                if (kind == .predicted) past = &self.frames[self.newer orelse return null];
                target = if (self.newer == 0) 1 else 0;

            },
            .bidirectional => {

                const newer = self.newer orelse return null;

                if (self.broken and leading) return null;

                future = &self.frames[newer];

                if (self.older) |older| {

                    past = &self.frames[older];

                } else {

                    // A closed group's leading B pictures predict only from the reference after them.
                    if (!(self.closed and leading)) return null;
                    past = future;

                }

            },
            .dc => {},

        }

        const frame = &self.frames[target];

        frame.time = time;
        frame.kind = kind;
        frame.order = order;
        frame.group = self.group;

        var context = Slice{

            .header = header,
            .kind = kind,
            .stride = header.columns * 16,

            .target = frame,
            .past = past,
            .future = future,

            .forward = forward,
            .backward = backward,

            .done = self.done,
            .block = &self.block,

        };

        @memset(self.done, 0);

        var search: usize = bits.consumed();

        while (find(body, search)) |place| {

            if (place + 4 > body.len) break;

            const slice = body[place + 3];
            const end = find(body, place + 4) orelse body.len;

            search = place + 4;

            if (slice < 1 or slice > 0xaf or slice > header.rows) continue;

            context.decode(body[place + 4 .. end], slice - 1) catch continue;

        }

        const nearest = if (self.newer) |newer| &self.frames[newer] else null;

        context.conceal(if (kind == .bidirectional) future else nearest);

        if (kind == .bidirectional or kind == .dc) return self.show(target);

        // A plain copy: Zig 0.15 lets `if (held) self.newer else null` alias the field it reads.
        const previous = self.newer;
        const waiting = self.held;

        self.older = self.newer;
        self.newer = target;
        self.held = true;
        self.references +|= 1;

        if (!waiting) return null;

        return if (previous) |index| self.show(index) else null;

    }

    /// Starts a new group of pictures, carrying the time anchor over by the pictures the last group numbered.
    fn advance(self: *Decoder) void {

        if (self.anchor) |anchor| {

            if (anchor.group == self.group and self.header != null) {

                const time = anchor.time + @as(f64, @floatFromInt(self.span)) / self.header.?.rate;

                self.anchor = .{

                    .group = self.group +% 1,
                    .time = time,

                };

            }

        }

        self.group +%= 1;
        self.span = 0;

    }

    fn show(self: *Decoder, index: u2) *const Picture {

        const frame = &self.frames[index];
        const header = &self.header.?;
        const period = 1.0 / header.rate;

        var time: f64 = 0;

        if (frame.time) |given| {

            time = given;

        } else if (self.last) |last| {

            time = last + period;

        } else if (self.anchor) |anchor| {

            if (anchor.group == frame.group) time = anchor.time + @as(f64, @floatFromInt(frame.order)) * period;

        }

        self.last = time;

        self.shown = .{

            .width = header.width,
            .height = header.height,
            .stride = header.columns * 16,

            .y = frame.y,
            .cb = frame.cb,
            .cr = frame.cr,

            .time = time,
            .kind = frame.kind,

        };

        return &self.shown;

    }

};

/// The sequence header's numbers, with the quantiser matrices in zigzag order.
const Header = struct {

    width: u32,
    height: u32,
    rate: f64,

    /// Macroblocks across and down.
    columns: u32,
    rows: u32,

    intra: [64]u8,
    inter: [64]u8,

};

const rates = [_]f64{ 0, 24000.0 / 1001.0, 24, 25, 30000.0 / 1001.0, 30, 50, 60000.0 / 1001.0, 60 };

/// Reads a sequence header from the bytes after its start code.
fn parse(body: []const u8) Error!Header {

    var bits = Bits.init(body);

    const width = bits.read(12);
    const height = bits.read(12);

    bits.skip(4);

    const rate = bits.read(4);

    bits.skip(18 + 1 + 10 + 1);

    var header = Header{

        .width = width,
        .height = height,
        .rate = if (rate < rates.len) rates[rate] else 0,

        .columns = (width + 15) / 16,
        .rows = (height + 15) / 16,

        .intra = default_intra,
        .inter = @splat(16),

    };

    if (bits.bit()) {

        for (&header.intra) |*value| value.* = @intCast(bits.read(8));

    }

    if (bits.bit()) {

        for (&header.inter) |*value| value.* = @intCast(bits.read(8));

    }

    if (bits.overrun() or width == 0 or height == 0 or header.rate == 0) return error.Invalid;
    if (std.mem.indexOfScalar(u8, &header.intra, 0) != null or std.mem.indexOfScalar(u8, &header.inter, 0) != null) return error.Invalid;

    return header;

}

/// Whether a start code belongs inside a picture: a slice, user data, or an extension.
fn within(code: u8) bool {

    return (code >= 0x01 and code <= 0xaf) or code == 0xb2 or code == 0xb5;

}

/// Where the next 00 00 01 start code prefix at or after `from` begins.
fn find(bytes: []const u8, from: usize) ?usize {

    var search = from;

    while (search + 3 <= bytes.len) {

        const one = std.mem.indexOfScalarPos(u8, bytes, search + 2, 1) orelse return null;

        if (bytes[one - 1] == 0 and bytes[one - 2] == 0) return one - 2;
        search = one - 1;

    }

    return null;

}

const Frame = struct {

    y: []u8,
    cb: []u8,
    cr: []u8,

    time: ?f64 = null,
    kind: Kind = .intra,

    /// Temporal reference: place in display order within its group.
    order: u32 = 0,
    group: u32 = 0,

};

/// How a picture codes motion vectors in one direction.
const Vector = struct {

    /// Bits of each vector's remainder, f_code - 1.
    size: u3 = 0,

    /// Whether vectors count whole pels rather than half pels.
    full: bool = false,

    fn read(bits: *Bits) ?Vector {

        const full = bits.bit();
        const code = bits.read(3);

        if (code == 0) return null;

        return .{

            .size = @intCast(code - 1),
            .full = full,

        };

    }

};

const Flags = packed struct(u8) {

    quant: bool = false,
    forward: bool = false,
    backward: bool = false,
    pattern: bool = false,
    intra: bool = false,
    _: u3 = 0,

};

/// One picture's decoding state, carried from macroblock to macroblock through its slices.
const Slice = struct {

    header: *const Header,
    kind: Kind,
    stride: usize,

    target: *Frame,
    past: ?*const Frame,
    future: ?*const Frame,

    forward: Vector,
    backward: Vector,

    done: []u8,
    block: *[64]i32,

    quantizer: u32 = 1,

    /// DC predictors for Y, Cb and Cr.
    dc: [3]i32 = @splat(1024),

    /// Motion vector predictors, horizontal then vertical, in the units the stream sends.
    motion: [2][2]i32 = @splat(@splat(0)),

    /// The macroblock before, whose prediction a skipped one in a B picture repeats.
    previous: Flags = .{ .intra = true },

    fn decode(self: *Slice, bytes: []const u8, row: u32) Error!void {

        var bits = Bits.init(bytes);
        const columns = self.header.columns;
        const count = columns * self.header.rows;

        self.quantizer = bits.read(5);

        if (self.quantizer == 0) return error.Invalid;

        while (bits.bit()) bits.skip(8);

        self.dc = @splat(1024);
        self.motion = @splat(@splat(0));
        self.previous = .{ .intra = true };

        // A block an earlier slice gave up on part way may still hold coefficients.
        self.block.* = @splat(0);

        var address = row * columns + try increment(&bits, count) - 1;

        while (true) {

            if (address >= count) return error.Invalid;

            try self.macroblock(&bits, address);

            if (bits.overrun()) return error.Invalid;
            if (bits.peek(23) == 0) return;

            const step = try increment(&bits, count);

            if (address + step >= count) return error.Invalid;

            for (address + 1..address + step) |skipped| try self.skip(@intCast(skipped));

            address += step;

        }

    }

    fn macroblock(self: *Slice, bits: *Bits, address: u32) Error!void {

        const entry = switch (self.kind) {

            .intra => intra_types[bits.peek(2)],
            .predicted => predicted_types[bits.peek(6)],
            .bidirectional => bidirectional_types[bits.peek(6)],
            .dc => dc_types[bits.peek(1)],

        };

        if (entry.length == 0) return error.Invalid;
        bits.skip(entry.length);

        const flags: Flags = @bitCast(@as(u8, @intCast(entry.value)));

        if (flags.quant) {

            self.quantizer = bits.read(5);
            if (self.quantizer == 0) return error.Invalid;

        }

        if (flags.forward) {

            for (&self.motion[0]) |*value| value.* = try vector(bits, self.forward.size, value.*);

        }

        if (flags.backward) {

            for (&self.motion[1]) |*value| value.* = try vector(bits, self.backward.size, value.*);

        }

        var pattern: u32 = if (flags.intra) 63 else 0;

        if (flags.pattern) {

            const coded = patterns[bits.peek(9)];

            if (coded.length == 0) return error.Invalid;
            bits.skip(coded.length);
            pattern = @intCast(coded.value);

        }

        if (flags.intra) {

            self.motion = @splat(@splat(0));

        } else {

            self.dc = @splat(1024);
            if (self.kind == .predicted and !flags.forward) self.motion[0] = .{ 0, 0 };
            self.predict(address, flags);

        }

        const columns = self.header.columns;
        const column = address % columns;
        const row = address / columns;

        for (0..6) |index| {

            if (pattern & @as(u32, 32) >> @intCast(index) == 0) continue;

            const only = try self.coefficients(bits, index, flags.intra);
            const plane, const place, const stride = self.locate(index, column, row);

            if (only) {

                const value = (self.block[0] + 4) >> 3;

                self.block[0] = 0;
                if (flags.intra) fill(plane, place, stride, value) else adjust(plane, place, stride, value);

            } else {

                if (flags.intra) put(self.block, plane, place, stride) else add(self.block, plane, place, stride);
                self.block.* = @splat(0);

            }

        }

        if (self.kind == .dc and !bits.bit()) return error.Invalid;

        self.previous = flags;
        self.done[address] = 1;

    }

    /// Fills in a macroblock the stream skipped: the reference copied in a P picture, the last prediction repeated in a B one.
    fn skip(self: *Slice, address: u32) Error!void {

        self.dc = @splat(1024);

        switch (self.kind) {

            .predicted => {

                self.motion[0] = .{ 0, 0 };
                self.predict(address, .{});

            },
            .bidirectional => {

                if (self.previous.intra) return error.Invalid;
                self.predict(address, self.previous);

            },
            else => return error.Invalid,

        }

        self.done[address] = 1;

    }

    fn predict(self: *Slice, address: u32, flags: Flags) void {

        const columns = self.header.columns;
        const column = address % columns;
        const row = address / columns;
        var average = false;

        if (self.kind == .predicted or flags.forward) {

            if (self.past) |past| {

                self.compensate(past, column, row, self.motion[0], self.forward.full, false);
                average = true;

            }

        }

        if (flags.backward) {

            if (self.future) |future| self.compensate(future, column, row, self.motion[1], self.backward.full, average);

        }

    }

    fn compensate(self: *Slice, source: *const Frame, column: usize, row: usize, motion: [2]i32, full: bool, average: bool) void {

        const width = self.header.columns * 16;
        const height = self.header.rows * 16;
        const x = if (full) motion[0] << 1 else motion[0];
        const y = if (full) motion[1] << 1 else motion[1];
        const half_x = @divTrunc(x, 2);
        const half_y = @divTrunc(y, 2);

        copy(16, self.target.y, source.y, self.stride, width, height, column * 16, row * 16, x, y, average);
        copy(8, self.target.cb, source.cb, self.stride / 2, width / 2, height / 2, column * 8, row * 8, half_x, half_y, average);
        copy(8, self.target.cr, source.cr, self.stride / 2, width / 2, height / 2, column * 8, row * 8, half_x, half_y, average);

    }

    /// The plane, offset, and row length of block `index` of the macroblock at `column`, `row`.
    fn locate(self: *Slice, index: usize, column: usize, row: usize) struct { []u8, usize, usize } {

        const stride = self.stride;

        return switch (index) {

            0...3 => .{ self.target.y, (row * 16 + index / 2 * 8) * stride + column * 16 + index % 2 * 8, stride },
            4 => .{ self.target.cb, row * 8 * (stride / 2) + column * 8, stride / 2 },
            else => .{ self.target.cr, row * 8 * (stride / 2) + column * 8, stride / 2 },

        };

    }

    /// Reads block `index`'s coefficients into `block`, dequantised and transposed; true when only the first is set.
    fn coefficients(self: *Slice, bits: *Bits, index: usize, intra: bool) Error!bool {

        const block = self.block;
        var position: u32 = 0;
        var only = true;

        if (intra) {

            const component = if (index < 4) 0 else index - 3;
            const entry = if (component == 0) luma_sizes[bits.peek(7)] else chroma_sizes[bits.peek(8)];

            if (entry.length == 0) return error.Invalid;
            bits.skip(entry.length);

            const size: u6 = @intCast(entry.value);
            var difference: i32 = 0;

            if (size > 0) {

                const raw: i32 = @intCast(bits.read(size));

                difference = if (raw >> @intCast(size - 1) != 0) raw else raw + 1 - (@as(i32, 1) << @intCast(size));

            }

            self.dc[component] = std.math.clamp(self.dc[component] + difference * 8, 0, 2047);
            block[0] = self.dc[component];

            if (self.kind == .dc) return true;

        } else if (bits.peek(1) == 1) {

            // The first coefficient's "1s" stands for run 0, level 1, where later it would end the block.
            block[0] = self.dequantize(1, bits.peek(2) & 1 != 0, 0, false);
            bits.skip(2);

        } else {

            position = std.math.maxInt(u32);

        }

        while (true) {

            const word = bits.peek(32);
            const entry = if (word >> 24 >= 4) first_codes[word >> 24] else second_codes[word >> 16];
            var run: u32 = entry.run;
            var level: i32 = entry.level;
            var negative = false;

            if (entry.run == end_of_block) {

                bits.skip(2);
                break;

            }

            if (entry.run == escape) {

                run = word >> 20 & 63;

                const fixed: u8 = @truncate(word >> 12);
                const extra: i32 = @intCast(word >> 4 & 0xff);

                if (fixed == 0) {

                    level = extra;
                    bits.skip(28);

                } else if (fixed == 0x80) {

                    level = extra - 256;
                    bits.skip(28);

                } else {

                    level = @as(i8, @bitCast(fixed));
                    bits.skip(20);

                }

                if (level == 0) return error.Invalid;
                negative = level < 0;
                level = @intCast(@abs(level));

            } else {

                if (entry.length == 0) return error.Invalid;
                negative = word >> @intCast(31 - entry.length) & 1 != 0;
                bits.skip(entry.length + 1);

            }

            position +%= run + 1;

            if (position > 63) return error.Invalid;

            block[scan[position]] = self.dequantize(@intCast(level), negative, position, intra);
            if (position != 0) only = false;

        }

        return only;

    }

    fn dequantize(self: *const Slice, level: u32, negative: bool, position: u32, intra: bool) i32 {

        const matrix = if (intra) &self.header.intra else &self.header.inter;
        const weight = self.quantizer * matrix[position];
        var value: i32 = @intCast(if (intra) level * weight >> 3 else (2 * level + 1) * weight >> 4);

        if (value != 0) value = (value - 1) | 1;

        return if (negative) -@min(value, 2048) else @min(value, 2047);

    }

    /// Fills in macroblocks no slice decoded with what `source` shows there.
    fn conceal(self: *Slice, source: ?*const Frame) void {

        const from = source orelse return;
        const columns = self.header.columns;
        const stride = self.stride;

        for (self.done, 0..) |done, address| {

            if (done != 0) continue;

            const column = address % columns;
            const row = address / columns;

            for (0..16) |line| {

                const at = (row * 16 + line) * stride + column * 16;

                @memcpy(self.target.y[at..][0..16], from.y[at..][0..16]);

            }

            for (0..8) |line| {

                const at = (row * 8 + line) * (stride / 2) + column * 8;

                @memcpy(self.target.cb[at..][0..8], from.cb[at..][0..8]);
                @memcpy(self.target.cr[at..][0..8], from.cr[at..][0..8]);

            }

        }

    }

};

fn increment(bits: *Bits, count: u32) Error!u32 {

    var total: u32 = 0;

    while (true) {

        const entry = increments[bits.peek(11)];

        if (entry.length == 0 or total > count) return error.Invalid;
        bits.skip(entry.length);

        switch (entry.value) {

            stuffing => {},
            address_escape => total += 33,
            else => return total + @as(u32, @intCast(entry.value)),

        }

    }

}

/// The next motion vector component from `previous`, whose range wraps at 16 << `size`.
fn vector(bits: *Bits, size: u3, previous: i32) Error!i32 {

    const entry = motions[bits.peek(11)];

    if (entry.length == 0) return error.Invalid;
    bits.skip(entry.length);

    var delta: i32 = entry.value;

    if (size != 0 and delta != 0) {

        const remainder: i32 = @intCast(bits.read(size));
        const magnitude = ((@as(i32, @intCast(@abs(delta))) - 1) << size) + remainder + 1;

        delta = if (delta < 0) -magnitude else magnitude;

    }

    const limit = @as(i32, 16) << size;
    var value = previous + delta;

    if (value > limit - 1) value -= 2 * limit;
    if (value < -limit) value += 2 * limit;

    return value;

}

/// Predicts the `size` square at `x`, `y` of `target` from `source` moved by half-pel vector `dx`, `dy`, or averages it in.
fn copy(comptime size: usize, target: []u8, source: []const u8, stride: usize, width: usize, height: usize, x: usize, y: usize, dx: i32, dy: i32, average: bool) void {

    const left = @as(i64, @intCast(x)) + (dx >> 1);
    const top = @as(i64, @intCast(y)) + (dy >> 1);
    const half_x: u2 = @intCast(dx & 1);
    const half_y: u2 = @intCast(dy & 1);
    const mode = half_x | half_y << 1;
    const into = target[y * stride + x ..];

    if (left >= 0 and top >= 0 and left + size + half_x <= @as(i64, @intCast(width)) and top + size + half_y <= @as(i64, @intCast(height))) {

        const from = source[@as(usize, @intCast(top)) * stride + @as(usize, @intCast(left)) ..];

        switch (mode) {

            inline else => |chosen| if (average) interpolate(size, chosen, true, into, stride, from, stride) else interpolate(size, chosen, false, into, stride, from, stride),

        }

        return;

    }

    // Vectors reaching past the picture read its edge pels repeated.
    var edge: [17 * 17]u8 = undefined;

    for (0..size + 1) |line| {

        const row: usize = @intCast(std.math.clamp(top + @as(i64, @intCast(line)), 0, @as(i64, @intCast(height)) - 1));

        for (0..size + 1) |offset| {

            const column: usize = @intCast(std.math.clamp(left + @as(i64, @intCast(offset)), 0, @as(i64, @intCast(width)) - 1));

            edge[line * 17 + offset] = source[row * stride + column];

        }

    }

    switch (mode) {

        inline else => |chosen| if (average) interpolate(size, chosen, true, into, stride, &edge, 17) else interpolate(size, chosen, false, into, stride, &edge, 17),

    }

}

fn interpolate(comptime size: usize, comptime mode: u2, comptime average: bool, target: []u8, target_stride: usize, source: []const u8, source_stride: usize) void {

    const Wide = @Vector(size, u16);
    const one: Wide = @splat(1);
    const two: Wide = @splat(2);
    const by_one: @Vector(size, u4) = @splat(1);
    const by_two: @Vector(size, u4) = @splat(2);

    for (0..size) |line| {

        const from = source[line * source_stride ..];
        const into = target[line * target_stride ..][0..size];

        if (mode == 0 and !average) {

            into.* = from[0..size].*;
            continue;

        }

        const value: Wide = switch (mode) {

            0 => widen(size, from[0..size]),
            1 => (widen(size, from[0..size]) + widen(size, from[1..][0..size]) + one) >> by_one,
            2 => (widen(size, from[0..size]) + widen(size, from[source_stride..][0..size]) + one) >> by_one,
            3 => (widen(size, from[0..size]) + widen(size, from[1..][0..size]) + widen(size, from[source_stride..][0..size]) + widen(size, from[source_stride + 1 ..][0..size]) + two) >> by_two,

        };

        const result = if (average) (widen(size, into) + value + one) >> by_one else value;
        const narrow: @Vector(size, u8) = @truncate(result);

        into.* = narrow;

    }

}

fn widen(comptime size: usize, bytes: *const [size]u8) @Vector(size, u16) {

    const narrow: @Vector(size, u8) = bytes.*;

    return @intCast(narrow);

}

/// Pels plus `amount`, held to 0..255.
fn plus(pels: @Vector(8, u8), amount: Row) @Vector(8, u8) {

    const sum = @as(Row, @intCast(pels)) +% amount;

    return @intCast(@min(@max(sum, @as(Row, @splat(0))), @as(Row, @splat(255))));

}

const Row = @Vector(8, i32);

/// IDCT weights: sqrt(2) * cos(k * pi / 16) scaled by 2^14.
const weights = weights: {

    var values: [8]i32 = undefined;

    for (&values, 0..) |*value, k| value.* = @intFromFloat(@round(@sqrt(2.0) * @cos(@as(f64, @floatFromInt(k)) * std.math.pi / 16.0) * 16384.0));

    break :weights values;

};

/// One 1-D IDCT down each column of eight rows, scaled up by 2^14 * 2 * sqrt(2) and shifted down by `shift`.
fn pass(x: [8]Row, comptime shift: u5) [8]Row {

    const w1: Row = @splat(weights[1]);
    const w2: Row = @splat(weights[2]);
    const w3: Row = @splat(weights[3]);
    const w4: Row = @splat(weights[4]);
    const w5: Row = @splat(weights[5]);
    const w6: Row = @splat(weights[6]);
    const w7: Row = @splat(weights[7]);
    const round: Row = @splat(1 << (shift - 1));
    const amount: @Vector(8, u5) = @splat(shift);

    // Wrapping arithmetic keeps corrupt coefficients from trapping; real ones stay far from the limits.
    const even0 = x[0] *% w4 +% round;
    const even4 = x[4] *% w4;
    const a0 = even0 +% even4 +% x[2] *% w2 +% x[6] *% w6;
    const a1 = even0 -% even4 +% x[2] *% w6 -% x[6] *% w2;
    const a2 = even0 -% even4 -% x[2] *% w6 +% x[6] *% w2;
    const a3 = even0 +% even4 -% x[2] *% w2 -% x[6] *% w6;

    const b0 = x[1] *% w1 +% x[3] *% w3 +% x[5] *% w5 +% x[7] *% w7;
    const b1 = x[1] *% w3 -% x[3] *% w7 -% x[5] *% w1 -% x[7] *% w5;
    const b2 = x[1] *% w5 -% x[3] *% w1 +% x[5] *% w7 +% x[7] *% w3;
    const b3 = x[1] *% w7 -% x[3] *% w5 +% x[5] *% w3 -% x[7] *% w1;

    return .{

        (a0 +% b0) >> amount,
        (a1 +% b1) >> amount,
        (a2 +% b2) >> amount,
        (a3 +% b3) >> amount,
        (a3 -% b3) >> amount,
        (a2 -% b2) >> amount,
        (a1 -% b1) >> amount,
        (a0 -% b0) >> amount,

    };

}

fn transpose(r: [8]Row) [8]Row {

    const pair_low = [8]i32{ 0, -1, 1, -2, 4, -5, 5, -6 };
    const pair_high = [8]i32{ 2, -3, 3, -4, 6, -7, 7, -8 };
    const quad_low = [8]i32{ 0, 1, -1, -2, 4, 5, -5, -6 };
    const quad_high = [8]i32{ 2, 3, -3, -4, 6, 7, -7, -8 };
    const half_low = [8]i32{ 0, 1, 2, 3, -1, -2, -3, -4 };
    const half_high = [8]i32{ 4, 5, 6, 7, -5, -6, -7, -8 };

    const p0 = @shuffle(i32, r[0], r[1], pair_low);
    const p1 = @shuffle(i32, r[0], r[1], pair_high);
    const p2 = @shuffle(i32, r[2], r[3], pair_low);
    const p3 = @shuffle(i32, r[2], r[3], pair_high);
    const p4 = @shuffle(i32, r[4], r[5], pair_low);
    const p5 = @shuffle(i32, r[4], r[5], pair_high);
    const p6 = @shuffle(i32, r[6], r[7], pair_low);
    const p7 = @shuffle(i32, r[6], r[7], pair_high);

    const q0 = @shuffle(i32, p0, p2, quad_low);
    const q1 = @shuffle(i32, p0, p2, quad_high);
    const q2 = @shuffle(i32, p1, p3, quad_low);
    const q3 = @shuffle(i32, p1, p3, quad_high);
    const q4 = @shuffle(i32, p4, p6, quad_low);
    const q5 = @shuffle(i32, p4, p6, quad_high);
    const q6 = @shuffle(i32, p5, p7, quad_low);
    const q7 = @shuffle(i32, p5, p7, quad_high);

    return .{

        @shuffle(i32, q0, q4, half_low),
        @shuffle(i32, q1, q5, half_low),
        @shuffle(i32, q2, q6, half_low),
        @shuffle(i32, q3, q7, half_low),
        @shuffle(i32, q0, q4, half_high),
        @shuffle(i32, q1, q5, half_high),
        @shuffle(i32, q2, q6, half_high),
        @shuffle(i32, q3, q7, half_high),

    };

}

/// The 2-D IDCT of a block stored transposed, as rows of pels.
fn idct(block: *const [64]i32) [8]Row {

    var rows: [8]Row = undefined;

    for (&rows, 0..) |*row, index| row.* = block[index * 8 ..][0..8].*;

    return pass(transpose(pass(rows, 11)), 20);

}

fn put(block: *const [64]i32, plane: []u8, place: usize, stride: usize) void {

    const rows = idct(block);

    for (rows, 0..) |row, line| plane[place + line * stride ..][0..8].* = plus(@splat(0), row);

}

fn add(block: *const [64]i32, plane: []u8, place: usize, stride: usize) void {

    const rows = idct(block);

    for (rows, 0..) |row, line| {

        const into = plane[place + line * stride ..][0..8];

        into.* = plus(into.*, row);

    }

}

fn fill(plane: []u8, place: usize, stride: usize, value: i32) void {

    const pel: u8 = @intCast(std.math.clamp(value, 0, 255));

    for (0..8) |line| plane[place + line * stride ..][0..8].* = @splat(pel);

}

fn adjust(plane: []u8, place: usize, stride: usize, value: i32) void {

    const amount: Row = @splat(value);

    for (0..8) |line| {

        const into = plane[place + line * stride ..][0..8];

        into.* = plus(into.*, amount);

    }

}

/// Raster positions in zigzag order.
const zigzag = [64]u8{

    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,

};

/// Zigzag order to raster positions, transposed for `idct`.
const scan = scan: {

    var positions: [64]u8 = undefined;

    for (&positions, zigzag) |*position, raster| position.* = raster % 8 * 8 + raster / 8;

    break :scan positions;

};

/// The default intra matrix of ISO 11172-2, in zigzag order as a sequence header would send it.
const default_intra = intra: {

    const raster = [64]u8{

        8, 16, 19, 22, 26, 27, 29, 34,
        16, 16, 22, 24, 27, 29, 34, 37,
        19, 22, 26, 27, 29, 34, 34, 38,
        22, 22, 26, 27, 29, 34, 37, 40,
        22, 26, 27, 29, 32, 35, 40, 48,
        26, 27, 29, 32, 35, 40, 48, 58,
        26, 27, 29, 34, 38, 46, 56, 69,
        27, 29, 35, 38, 46, 56, 69, 83,

    };

    var values: [64]u8 = undefined;

    for (&values, zigzag) |*value, position| value.* = raster[position];

    break :intra values;

};

const Entry = struct {

    value: i16 = 0,
    length: u8 = 0,

};

const Code = struct { []const u8, i16 };

/// A table read by the next `width` bits; an entry of length zero is a code the table lacks.
fn lookup(comptime width: u4, comptime codes: []const Code) [1 << width]Entry {

    @setEvalBranchQuota(200000);

    var table = [_]Entry{.{}} ** (1 << width);

    for (codes) |code| {

        const prefix, const length = binary(code[0]);
        const room: u6 = @intCast(width - length);
        const first = prefix << room;

        for (first..first + (@as(usize, 1) << room)) |index| {

            if (table[index].length != 0) @compileError("codes overlap: " ++ code[0]);
            table[index] = .{ .value = code[1], .length = length };

        }

    }

    return table;

}

/// A code written as '0' and '1' characters, spaces ignored, as its value and length.
fn binary(comptime text: []const u8) struct { usize, u8 } {

    var value: usize = 0;
    var length: u8 = 0;

    for (text) |character| {

        if (character == ' ') continue;
        value = value << 1 | (character - '0');
        length += 1;

    }

    return .{ value, length };

}

fn marks(comptime set: Flags) i16 {

    return @as(u8, @bitCast(set));

}

const stuffing = 34;
const address_escape = 35;

const increments = lookup(11, &.{

    .{ "1", 1 }, .{ "011", 2 }, .{ "010", 3 }, .{ "0011", 4 },
    .{ "0010", 5 }, .{ "0001 1", 6 }, .{ "0001 0", 7 }, .{ "0000 111", 8 },
    .{ "0000 110", 9 }, .{ "0000 1011", 10 }, .{ "0000 1010", 11 }, .{ "0000 1001", 12 },
    .{ "0000 1000", 13 }, .{ "0000 0111", 14 }, .{ "0000 0110", 15 }, .{ "0000 0101 11", 16 },
    .{ "0000 0101 10", 17 }, .{ "0000 0101 01", 18 }, .{ "0000 0101 00", 19 }, .{ "0000 0100 11", 20 },
    .{ "0000 0100 10", 21 }, .{ "0000 0100 011", 22 }, .{ "0000 0100 010", 23 }, .{ "0000 0100 001", 24 },
    .{ "0000 0100 000", 25 }, .{ "0000 0011 111", 26 }, .{ "0000 0011 110", 27 }, .{ "0000 0011 101", 28 },
    .{ "0000 0011 100", 29 }, .{ "0000 0011 011", 30 }, .{ "0000 0011 010", 31 }, .{ "0000 0011 001", 32 },
    .{ "0000 0011 000", 33 }, .{ "0000 0001 111", stuffing }, .{ "0000 0001 000", address_escape },

});

const intra_types = lookup(2, &.{

    .{ "1", marks(.{ .intra = true }) },
    .{ "01", marks(.{ .intra = true, .quant = true }) },

});

const predicted_types = lookup(6, &.{

    .{ "1", marks(.{ .forward = true, .pattern = true }) },
    .{ "01", marks(.{ .pattern = true }) },
    .{ "001", marks(.{ .forward = true }) },
    .{ "0001 1", marks(.{ .intra = true }) },
    .{ "0001 0", marks(.{ .quant = true, .forward = true, .pattern = true }) },
    .{ "0000 1", marks(.{ .quant = true, .pattern = true }) },
    .{ "0000 01", marks(.{ .quant = true, .intra = true }) },

});

const bidirectional_types = lookup(6, &.{

    .{ "10", marks(.{ .forward = true, .backward = true }) },
    .{ "11", marks(.{ .forward = true, .backward = true, .pattern = true }) },
    .{ "010", marks(.{ .backward = true }) },
    .{ "011", marks(.{ .backward = true, .pattern = true }) },
    .{ "0010", marks(.{ .forward = true }) },
    .{ "0011", marks(.{ .forward = true, .pattern = true }) },
    .{ "0001 1", marks(.{ .intra = true }) },
    .{ "0001 0", marks(.{ .quant = true, .forward = true, .backward = true, .pattern = true }) },
    .{ "0000 11", marks(.{ .quant = true, .forward = true, .pattern = true }) },
    .{ "0000 10", marks(.{ .quant = true, .backward = true, .pattern = true }) },
    .{ "0000 01", marks(.{ .quant = true, .intra = true }) },

});

const dc_types = lookup(1, &.{

    .{ "1", marks(.{ .intra = true }) },

});

const patterns = lookup(9, &.{

    .{ "111", 60 }, .{ "1101", 4 }, .{ "1100", 8 }, .{ "1011", 16 }, .{ "1010", 32 },
    .{ "1001 1", 12 }, .{ "1001 0", 48 }, .{ "1000 1", 20 }, .{ "1000 0", 40 }, .{ "0111 1", 28 },
    .{ "0111 0", 44 }, .{ "0110 1", 52 }, .{ "0110 0", 56 }, .{ "0101 1", 1 }, .{ "0101 0", 61 },
    .{ "0100 1", 2 }, .{ "0100 0", 62 }, .{ "0011 11", 24 }, .{ "0011 10", 36 }, .{ "0011 01", 3 },
    .{ "0011 00", 63 }, .{ "0010 111", 5 }, .{ "0010 110", 9 }, .{ "0010 101", 17 }, .{ "0010 100", 33 },
    .{ "0010 011", 6 }, .{ "0010 010", 10 }, .{ "0010 001", 18 }, .{ "0010 000", 34 }, .{ "0001 1111", 7 },
    .{ "0001 1110", 11 }, .{ "0001 1101", 19 }, .{ "0001 1100", 35 }, .{ "0001 1011", 13 }, .{ "0001 1010", 49 },
    .{ "0001 1001", 21 }, .{ "0001 1000", 41 }, .{ "0001 0111", 14 }, .{ "0001 0110", 50 }, .{ "0001 0101", 22 },
    .{ "0001 0100", 42 }, .{ "0001 0011", 15 }, .{ "0001 0010", 51 }, .{ "0001 0001", 23 }, .{ "0001 0000", 43 },
    .{ "0000 1111", 25 }, .{ "0000 1110", 37 }, .{ "0000 1101", 26 }, .{ "0000 1100", 38 }, .{ "0000 1011", 29 },
    .{ "0000 1010", 45 }, .{ "0000 1001", 53 }, .{ "0000 1000", 57 }, .{ "0000 0111", 30 }, .{ "0000 0110", 46 },
    .{ "0000 0101", 54 }, .{ "0000 0100", 58 }, .{ "0000 0011 1", 31 }, .{ "0000 0011 0", 47 }, .{ "0000 0010 1", 55 },
    .{ "0000 0010 0", 59 }, .{ "0000 0001 1", 27 }, .{ "0000 0001 0", 39 },

});

const motions = lookup(11, &.{

    .{ "0000 0011 001", -16 }, .{ "0000 0011 011", -15 }, .{ "0000 0011 101", -14 }, .{ "0000 0011 111", -13 },
    .{ "0000 0100 001", -12 }, .{ "0000 0100 011", -11 }, .{ "0000 0100 11", -10 }, .{ "0000 0101 01", -9 },
    .{ "0000 0101 11", -8 }, .{ "0000 0111", -7 }, .{ "0000 1001", -6 }, .{ "0000 1011", -5 },
    .{ "0000 111", -4 }, .{ "0001 1", -3 }, .{ "0011", -2 }, .{ "011", -1 },
    .{ "1", 0 }, .{ "010", 1 }, .{ "0010", 2 }, .{ "0001 0", 3 },
    .{ "0000 110", 4 }, .{ "0000 1010", 5 }, .{ "0000 1000", 6 }, .{ "0000 0110", 7 },
    .{ "0000 0101 10", 8 }, .{ "0000 0101 00", 9 }, .{ "0000 0100 10", 10 }, .{ "0000 0100 010", 11 },
    .{ "0000 0100 000", 12 }, .{ "0000 0011 110", 13 }, .{ "0000 0011 100", 14 }, .{ "0000 0011 010", 15 },
    .{ "0000 0011 000", 16 },

});

const luma_sizes = lookup(7, &.{

    .{ "100", 0 }, .{ "00", 1 }, .{ "01", 2 }, .{ "101", 3 }, .{ "110", 4 },
    .{ "1110", 5 }, .{ "1111 0", 6 }, .{ "1111 10", 7 }, .{ "1111 110", 8 },

});

const chroma_sizes = lookup(8, &.{

    .{ "00", 0 }, .{ "01", 1 }, .{ "10", 2 }, .{ "110", 3 }, .{ "1110", 4 },
    .{ "1111 0", 5 }, .{ "1111 10", 6 }, .{ "1111 110", 7 }, .{ "1111 1110", 8 },

});

const end_of_block = 64;
const escape = 65;

/// A DCT coefficient code: the zeros before it and its magnitude, its sign bit following.
const Coefficient = struct {

    run: u8 = 0,
    level: u8 = 0,
    length: u8 = 0,

};

const CoefficientCode = struct { []const u8, u8, u8 };

/// Run, level, and code of every DCT coefficient ISO 11172-2 table B.5c lists, signs left off.
const coefficient_codes = [_]CoefficientCode{

    .{ "11", 0, 1 }, .{ "011", 1, 1 }, .{ "0100", 0, 2 }, .{ "0101", 2, 1 },
    .{ "0010 1", 0, 3 }, .{ "0011 1", 3, 1 }, .{ "0011 0", 4, 1 }, .{ "0001 10", 1, 2 },
    .{ "0001 11", 5, 1 }, .{ "0001 01", 6, 1 }, .{ "0001 00", 7, 1 }, .{ "0000 110", 0, 4 },
    .{ "0000 100", 2, 2 }, .{ "0000 111", 8, 1 }, .{ "0000 101", 9, 1 }, .{ "0010 0110", 0, 5 },
    .{ "0010 0001", 0, 6 }, .{ "0010 0101", 1, 3 }, .{ "0010 0100", 3, 2 }, .{ "0010 0111", 10, 1 },
    .{ "0010 0011", 11, 1 }, .{ "0010 0010", 12, 1 }, .{ "0010 0000", 13, 1 }, .{ "0000 0010 10", 0, 7 },
    .{ "0000 0011 00", 1, 4 }, .{ "0000 0010 11", 2, 3 }, .{ "0000 0011 11", 4, 2 }, .{ "0000 0010 01", 5, 2 },
    .{ "0000 0011 10", 14, 1 }, .{ "0000 0011 01", 15, 1 }, .{ "0000 0010 00", 16, 1 }, .{ "0000 0001 1101", 0, 8 },
    .{ "0000 0001 1000", 0, 9 }, .{ "0000 0001 0011", 0, 10 }, .{ "0000 0001 0000", 0, 11 }, .{ "0000 0001 1011", 1, 5 },
    .{ "0000 0001 0100", 2, 4 }, .{ "0000 0001 1100", 3, 3 }, .{ "0000 0001 0010", 4, 3 }, .{ "0000 0001 1110", 6, 2 },
    .{ "0000 0001 0101", 7, 2 }, .{ "0000 0001 0001", 8, 2 }, .{ "0000 0001 1111", 17, 1 }, .{ "0000 0001 1010", 18, 1 },
    .{ "0000 0001 1001", 19, 1 }, .{ "0000 0001 0111", 20, 1 }, .{ "0000 0001 0110", 21, 1 }, .{ "0000 0000 1101 0", 0, 12 },
    .{ "0000 0000 1100 1", 0, 13 }, .{ "0000 0000 1100 0", 0, 14 }, .{ "0000 0000 1011 1", 0, 15 }, .{ "0000 0000 1011 0", 1, 6 },
    .{ "0000 0000 1010 1", 1, 7 }, .{ "0000 0000 1010 0", 2, 5 }, .{ "0000 0000 1001 1", 3, 4 }, .{ "0000 0000 1001 0", 5, 3 },
    .{ "0000 0000 1000 1", 9, 2 }, .{ "0000 0000 1000 0", 10, 2 }, .{ "0000 0000 1111 1", 22, 1 }, .{ "0000 0000 1111 0", 23, 1 },
    .{ "0000 0000 1110 1", 24, 1 }, .{ "0000 0000 1110 0", 25, 1 }, .{ "0000 0000 1101 1", 26, 1 }, .{ "0000 0000 0111 11", 0, 16 },
    .{ "0000 0000 0111 10", 0, 17 }, .{ "0000 0000 0111 01", 0, 18 }, .{ "0000 0000 0111 00", 0, 19 }, .{ "0000 0000 0110 11", 0, 20 },
    .{ "0000 0000 0110 10", 0, 21 }, .{ "0000 0000 0110 01", 0, 22 }, .{ "0000 0000 0110 00", 0, 23 }, .{ "0000 0000 0101 11", 0, 24 },
    .{ "0000 0000 0101 10", 0, 25 }, .{ "0000 0000 0101 01", 0, 26 }, .{ "0000 0000 0101 00", 0, 27 }, .{ "0000 0000 0100 11", 0, 28 },
    .{ "0000 0000 0100 10", 0, 29 }, .{ "0000 0000 0100 01", 0, 30 }, .{ "0000 0000 0100 00", 0, 31 }, .{ "0000 0000 0011 000", 0, 32 },
    .{ "0000 0000 0010 111", 0, 33 }, .{ "0000 0000 0010 110", 0, 34 }, .{ "0000 0000 0010 101", 0, 35 }, .{ "0000 0000 0010 100", 0, 36 },
    .{ "0000 0000 0010 011", 0, 37 }, .{ "0000 0000 0010 010", 0, 38 }, .{ "0000 0000 0010 001", 0, 39 }, .{ "0000 0000 0010 000", 0, 40 },
    .{ "0000 0000 0011 111", 1, 8 }, .{ "0000 0000 0011 110", 1, 9 }, .{ "0000 0000 0011 101", 1, 10 }, .{ "0000 0000 0011 100", 1, 11 },
    .{ "0000 0000 0011 011", 1, 12 }, .{ "0000 0000 0011 010", 1, 13 }, .{ "0000 0000 0011 001", 1, 14 }, .{ "0000 0000 0001 0011", 1, 15 },
    .{ "0000 0000 0001 0010", 1, 16 }, .{ "0000 0000 0001 0001", 1, 17 }, .{ "0000 0000 0001 0000", 1, 18 }, .{ "0000 0000 0001 0100", 6, 3 },
    .{ "0000 0000 0001 1010", 11, 2 }, .{ "0000 0000 0001 1001", 12, 2 }, .{ "0000 0000 0001 1000", 13, 2 }, .{ "0000 0000 0001 0111", 14, 2 },
    .{ "0000 0000 0001 0110", 15, 2 }, .{ "0000 0000 0001 0101", 16, 2 }, .{ "0000 0000 0001 1111", 27, 1 }, .{ "0000 0000 0001 1110", 28, 1 },
    .{ "0000 0000 0001 1101", 29, 1 }, .{ "0000 0000 0001 1100", 30, 1 }, .{ "0000 0000 0001 1011", 31, 1 },

};

/// Coefficient codes looked up by the first eight bits of the next 32, when those do not start with six zeros.
const first_codes = coefficientTable(256, 8);

/// Codes starting with six zeros, looked up by the first sixteen bits.
const second_codes = coefficientTable(1024, 16);

fn coefficientTable(comptime size: usize, comptime width: u8) [size]Coefficient {

    @setEvalBranchQuota(200000);

    var table = [_]Coefficient{.{}} ** size;
    const special = [_]CoefficientCode{ .{ "10", end_of_block, 0 }, .{ "0000 01", escape, 0 } };

    for (coefficient_codes ++ special) |code| {

        const value, const length = binary(code[0]);

        if ((length > 8) != (width == 16)) continue;

        const room: u6 = @intCast(width - length);
        const first = value << room;

        for (first..first + (@as(usize, 1) << room)) |index| {

            if (table[index].length != 0) @compileError("codes overlap: " ++ code[0]);
            table[index] = .{ .run = code[1], .level = code[2], .length = length };

        }

    }

    return table;

}

/// Pictures decoded from a fixture: their times and kinds, with pels sampled from the chosen ones.
const Played = struct {

    times: std.ArrayList(f64) = .empty,
    kinds: std.ArrayList(u8) = .empty,
    samples: std.ArrayList(u8) = .empty,

    /// Keeps every `step`th pel of every `step`th row of each displayed plane, as the reference files do.
    fn keep(self: *Played, allocator: std.mem.Allocator, picture: *const Picture, chosen: []const usize, step: usize) !void {

        if (std.mem.indexOfScalar(usize, chosen, self.times.items.len) != null) {

            const width: usize = picture.width;
            const height: usize = picture.height;
            const chroma = picture.stride / 2;

            const planes = [_]struct { []const u8, usize, usize, usize }{

                .{ picture.y, picture.stride, width, height },
                .{ picture.cb, chroma, (width + 1) / 2, (height + 1) / 2 },
                .{ picture.cr, chroma, (width + 1) / 2, (height + 1) / 2 },

            };

            for (planes) |plane| {

                const pels, const stride, const across, const down = plane;
                var row: usize = 0;

                while (row < down) : (row += step) {

                    var column: usize = 0;

                    while (column < across) : (column += step) try self.samples.append(allocator, pels[row * stride + column]);

                }

            }

        }

        try self.times.append(allocator, picture.time);
        try self.kinds.append(allocator, "?IPBD"[@intFromEnum(picture.kind)]);

    }

};

/// Demuxes `file` and decodes its video, fed in pieces of at most `piece` bytes.
fn play(allocator: std.mem.Allocator, file: []const u8, chosen: []const usize, step: usize, piece: usize) !Played {

    var input = Source.fixed(file);
    var demuxer = try Demuxer.open(&input);
    var decoder = Decoder.init(std.testing.allocator);
    var played = Played{};

    defer decoder.deinit(std.testing.allocator);

    while (try demuxer.next()) |packet| {

        if (packet.kind != .video) continue;

        var rest = packet.bytes;
        var time = packet.time;

        while (rest.len > 0) {

            const count = @min(piece, rest.len);

            try decoder.feed(std.testing.allocator, rest[0..count], time);
            time = null;
            rest = rest[count..];

            while (try decoder.next(false)) |picture| try played.keep(allocator, picture, chosen, step);

        }

    }

    while (try decoder.next(true)) |picture| try played.keep(allocator, picture, chosen, step);

    return played;

}

/// The video elementary stream a fixture carries.
fn elementary(allocator: std.mem.Allocator, file: []const u8) ![]u8 {

    var input = Source.fixed(file);
    var demuxer = try Demuxer.open(&input);
    var bytes: std.ArrayList(u8) = .empty;

    while (try demuxer.next()) |packet| {

        if (packet.kind == .video) try bytes.appendSlice(allocator, packet.bytes);

    }

    return bytes.items;

}

fn psnr(a: []const u8, b: []const u8) f64 {

    var sum: f64 = 0;

    for (a, b) |x, y| {

        const difference = @as(f64, @floatFromInt(x)) - @as(f64, @floatFromInt(y));

        sum += difference * difference;

    }

    if (sum == 0) return 99;

    return 10 * std.math.log10(255.0 * 255.0 * @as(f64, @floatFromInt(a.len)) / sum);

}

const gop_file = @embedFile("fixtures/video-gop.mpg");
const odd_file = @embedFile("fixtures/video-odd.m1v");
const sif_file = @embedFile("fixtures/video-sif.mpg");
const long_file = @embedFile("fixtures/system-long.mpg");

test "video decodes I, P, and B pictures within 40 dB of ffmpeg" {

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();

    const allocator = arena.allocator();

    // Each file with ffmpeg's frames (display order, subsampled by `step`), the frames chosen, `step`, and display size.
    const cases = [_]struct { []const u8, []const u8, []const usize, usize, usize, usize }{

        .{ gop_file, @embedFile("fixtures/video-gop.yuv"), &.{ 0, 4, 11, 22 }, 2, 160, 120 },
        .{ odd_file, @embedFile("fixtures/video-odd.yuv"), &.{ 0, 7, 14 }, 1, 100, 60 },
        .{ sif_file, @embedFile("fixtures/video-sif.yuv"), &.{ 1, 5, 8 }, 4, 352, 240 },

    };

    for (cases) |case| {

        const file, const reference, const chosen, const step, const width, const height = case;
        const played = try play(allocator, file, chosen, step, 1 << 30);
        const luma = (height + step - 1) / step * ((width + step - 1) / step);
        const chroma = ((height + 1) / 2 + step - 1) / step * (((width + 1) / 2 + step - 1) / step);

        try std.testing.expectEqual(reference.len, played.samples.items.len);

        var at: usize = 0;

        for (chosen) |_| {

            for ([_]usize{ luma, chroma, chroma }) |size| {

                try std.testing.expect(psnr(played.samples.items[at..][0..size], reference[at..][0..size]) >= 40);
                at += size;

            }

        }

    }

}

test "video shows pictures in display order at the times and count ffprobe reports" {

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();

    const allocator = arena.allocator();

    // Each file with ffprobe's picture types and its first picture's time and picture period in seconds.
    const cases = [_]struct { []const u8, []const u8, f64, f64 }{

        .{ gop_file, "IBBPBBPBBPBBIBBPBBPBBPBBI", 0.54, 0.04 },
        .{ sif_file, "IBBPBBIBP", 48003.0 / 90000.0, 1001.0 / 30000.0 },
        .{ odd_file, "IBPBPBIBPBPBIBP", 0, 0.04 },

    };

    for (cases) |case| {

        const file, const kinds, const first, const period = case;
        const played = try play(allocator, file, &.{}, 1, 1 << 30);

        try std.testing.expectEqualStrings(kinds, played.kinds.items);

        for (played.times.items, 0..) |time, index| {

            try std.testing.expectApproxEqAbs(first + @as(f64, @floatFromInt(index)) * period, time, 1e-6);

        }

    }

    const long = try play(allocator, long_file, &.{}, 1, 1 << 30);

    try std.testing.expectEqual(150, long.times.items.len);

    for (long.times.items[1..], long.times.items[0 .. long.times.items.len - 1]) |later, earlier| try std.testing.expect(later > earlier);

}

test "video decodes the same from small pieces as from whole packets" {

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();

    const allocator = arena.allocator();
    const chosen = [_]usize{ 0, 3, 13, 24 };
    const whole = try play(allocator, gop_file, &chosen, 1, 1 << 30);
    const pieces = try play(allocator, gop_file, &chosen, 1, 7);

    try std.testing.expectEqualSlices(u8, whole.samples.items, pieces.samples.items);
    try std.testing.expectEqualSlices(f64, whole.times.items, pieces.times.items);
    try std.testing.expectEqualStrings(whole.kinds.items, pieces.kinds.items);

}

test "video resumes at an I picture after a reset" {

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();

    const allocator = arena.allocator();
    const Piece = struct { []const u8, ?f64 };
    var pieces: std.ArrayList(Piece) = .empty;
    var input = Source.fixed(long_file);
    var demuxer = try Demuxer.open(&input);

    while (try demuxer.next()) |packet| {

        if (packet.kind == .video) try pieces.append(allocator, .{ try allocator.dupe(u8, packet.bytes), packet.time });

    }

    var decoder = Decoder.init(std.testing.allocator);

    defer decoder.deinit(std.testing.allocator);

    const count = pieces.items.len;

    for (pieces.items[0 .. count / 3]) |piece| {

        try decoder.feed(std.testing.allocator, piece[0], piece[1]);

        while (try decoder.next(false)) |_| {}

    }

    decoder.reset();

    var kinds: std.ArrayList(Kind) = .empty;
    var times: std.ArrayList(f64) = .empty;

    for (pieces.items[count / 2 ..]) |piece| {

        try decoder.feed(std.testing.allocator, piece[0], piece[1]);

        while (try decoder.next(false)) |picture| {

            try kinds.append(allocator, picture.kind);
            try times.append(allocator, picture.time);

        }

    }

    while (try decoder.next(true)) |picture| {

        try kinds.append(allocator, picture.kind);
        try times.append(allocator, picture.time);

    }

    try std.testing.expect(kinds.items.len > 40);
    try std.testing.expectEqual(Kind.intra, kinds.items[0]);

    for (times.items[1..], times.items[0 .. times.items.len - 1]) |later, earlier| try std.testing.expectApproxEqAbs(0.04, later - earlier, 1e-6);

    try std.testing.expectApproxEqAbs(6.0 - 0.04 + 0.54, times.items[times.items.len - 1], 1e-6);

}

test "video converts studio range YCbCr to full range RGB" {

    // 18 x 3 pels: a whole 16-pel span and a short tail across, a row pair and a lone row down.
    var y: [32 * 3]u8 = @splat(16);
    var cb: [16 * 2]u8 = @splat(128);
    var cr: [16 * 2]u8 = @splat(128);
    var pixels: [18 * 3]u32 = undefined;

    const picture = Picture{

        .width = 18,
        .height = 3,
        .stride = 32,

        .y = &y,
        .cb = &cb,
        .cr = &cr,

        .time = 0,
        .kind = .intra,

    };

    picture.convert(&pixels);

    for (pixels) |pixel| try std.testing.expectEqual(0xff000000, pixel);

    var prng = std.Random.DefaultPrng.init(601);
    const random = prng.random();

    for (0..20) |_| {

        random.bytes(&y);
        random.bytes(&cb);
        random.bytes(&cr);
        picture.convert(&pixels);

        for (0..3) |row| {

            for (0..18) |column| {

                const luma = (@as(f64, @floatFromInt(y[row * 32 + column])) - 16) * 255 / 219;
                const u = @as(f64, @floatFromInt(cb[row / 2 * 16 + column / 2])) - 128;
                const v = @as(f64, @floatFromInt(cr[row / 2 * 16 + column / 2])) - 128;
                const scale = 255.0 / 224.0;
                const expected = [3]f64{ luma + scale * 1.402 * v, luma - scale * (1.772 * 0.114 * u + 1.402 * 0.299 * v) / 0.587, luma + scale * 1.772 * u };
                const pixel = pixels[row * 18 + column];

                try std.testing.expectEqual(0xff000000, pixel & 0xff000000);

                for (expected, 0..) |channel, index| {

                    const got: f64 = @floatFromInt(pixel >> @intCast(16 - index * 8) & 0xff);

                    try std.testing.expect(@abs(std.math.clamp(@round(channel), 0, 255) - got) <= 1);

                }

            }

        }

    }

    @memset(&y, 235);
    @memset(&cb, 128);
    @memset(&cr, 128);
    y[1] = 126;
    picture.convert(&pixels);

    try std.testing.expectEqual(0xffffffff, pixels[0]);
    try std.testing.expectEqual(0xff808080, pixels[1]);

    // Planes too small for the size given leave the pixels alone.
    const short = Picture{

        .width = 18,
        .height = 3,
        .stride = 32,

        .y = y[0..40],
        .cb = &cb,
        .cr = &cr,

        .time = 0,
        .kind = .intra,

    };

    pixels[0] = 0;
    short.convert(&pixels);

    try std.testing.expectEqual(0, pixels[0]);

}

test "video IDCT stays within IEEE 1180 error limits" {

    var prng = std.Random.DefaultPrng.init(1180);
    const random = prng.random();

    // c(u) / 2 * cos((2x + 1) u pi / 16), so a 1-D transform either way is a product with this matrix.
    var basis: [8][8]f64 = undefined;

    for (0..8) |x| {

        for (0..8) |u| {

            const scale: f64 = if (u == 0) @sqrt(0.125) else 0.5;

            basis[x][u] = scale * @cos(@as(f64, @floatFromInt((2 * x + 1) * u)) * std.math.pi / 16);

        }

    }

    for ([_][2]i32{ .{ 256, 255 }, .{ 5, 5 }, .{ 300, 300 } }) |range| {

        for ([_]f64{ 1, -1 }) |sign| {

            var squares: [64]f64 = @splat(0);
            var sums: [64]f64 = @splat(0);
            var peak: f64 = 0;

            for (0..10000) |_| {

                var pels: [8][8]f64 = undefined;
                var half: [8][8]f64 = undefined;
                var coefficients: [8][8]f64 = undefined;
                var block: [64]i32 = undefined;

                for (&pels) |*row| {

                    for (row) |*pel| pel.* = sign * @as(f64, @floatFromInt(random.intRangeAtMost(i32, -range[0], range[1])));

                }

                for (0..8) |y| for (0..8) |u| {

                    var sum: f64 = 0;

                    for (0..8) |x| sum += basis[x][u] * pels[y][x];
                    half[y][u] = sum;

                };

                for (0..8) |v| for (0..8) |u| {

                    var sum: f64 = 0;

                    for (0..8) |y| sum += basis[y][v] * half[y][u];
                    coefficients[v][u] = std.math.clamp(@round(sum), -2048, 2047);
                    block[u * 8 + v] = @intFromFloat(coefficients[v][u]);

                };

                for (0..8) |v| for (0..8) |x| {

                    var sum: f64 = 0;

                    for (0..8) |u| sum += basis[x][u] * coefficients[v][u];
                    half[v][x] = sum;

                };

                const rows = idct(&block);

                for (0..8) |y| for (0..8) |x| {

                    var sum: f64 = 0;

                    for (0..8) |v| sum += basis[y][v] * half[v][x];

                    const expected = std.math.clamp(@round(sum), -256, 255);
                    const got = std.math.clamp(@as(f64, @floatFromInt(rows[y][x])), -256, 255);
                    const difference = got - expected;

                    peak = @max(peak, @abs(difference));
                    sums[y * 8 + x] += difference;
                    squares[y * 8 + x] += difference * difference;

                };

            }

            var total_square: f64 = 0;
            var total_sum: f64 = 0;

            for (squares, sums) |square, sum| {

                try std.testing.expect(square / 10000 <= 0.06);
                try std.testing.expect(@abs(sum / 10000) <= 0.015);
                total_square += square;
                total_sum += sum;

            }

            try std.testing.expect(peak <= 1);
            try std.testing.expect(total_square / 640000 <= 0.02);
            try std.testing.expect(@abs(total_sum / 640000) <= 0.0015);

        }

    }

    var lone: [64]i32 = @splat(0);

    for (idct(&lone)) |row| try std.testing.expectEqual(@as(Row, @splat(0)), row);

    lone[0] = 8 * 37;

    for (idct(&lone)) |row| try std.testing.expectEqual(@as(Row, @splat(37)), row);

}

test "video variable-length tables are complete prefix codes" {

    const filled = struct {

        fn count(table: []const Entry) usize {

            var total: usize = 0;

            for (table) |entry| total += @intFromBool(entry.length != 0);

            return total;

        }

    }.count;

    // What each table leaves out: runs of zeros a start code could begin with, and codes MPEG-1 reserves.
    try std.testing.expectEqual(2048 - 22, filled(&increments));
    try std.testing.expectEqual(2048 - 24, filled(&motions));
    try std.testing.expectEqual(512 - 2, filled(&patterns));
    try std.testing.expectEqual(128 - 1, filled(&luma_sizes));
    try std.testing.expectEqual(256 - 1, filled(&chroma_sizes));
    try std.testing.expectEqual(3, filled(&intra_types));
    try std.testing.expectEqual(64 - 1, filled(&predicted_types));
    try std.testing.expectEqual(64 - 1, filled(&bidirectional_types));

    for (first_codes[4..]) |entry| try std.testing.expect(entry.length != 0);
    for (first_codes[0..4]) |entry| try std.testing.expectEqual(0, entry.length);
    for (second_codes[16..]) |entry| try std.testing.expect(entry.length != 0);
    for (second_codes[0..16]) |entry| try std.testing.expectEqual(0, entry.length);

}

/// Bits written most significant first, for streams built by hand.
const Writer = struct {

    bytes: std.ArrayList(u8) = .empty,
    used: u3 = 0,

    fn put(self: *Writer, allocator: std.mem.Allocator, value: u32, width: u6) !void {

        var left = width;

        while (left > 0) : (left -= 1) {

            if (self.used == 0) try self.bytes.append(allocator, 0);

            const bit: u8 = @intCast(value >> @intCast(left - 1) & 1);

            self.bytes.items[self.bytes.items.len - 1] |= bit << (7 - self.used);
            self.used +%= 1;

        }

    }

    fn code(self: *Writer, allocator: std.mem.Allocator, comptime text: []const u8) !void {

        const value, const length = comptime binary(text);

        try self.put(allocator, @intCast(value), @intCast(length));

    }

    fn start(self: *Writer, allocator: std.mem.Allocator, value: u8) !void {

        self.used = 0;
        try self.bytes.appendSlice(allocator, &.{ 0, 0, 1, value });

    }

};

test "video decodes a hand-built D picture and refuses MPEG-2" {

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();

    const allocator = arena.allocator();
    var stream = Writer{};

    try stream.start(allocator, 0xb3);
    try stream.put(allocator, 32, 12);
    try stream.put(allocator, 16, 12);
    try stream.put(allocator, 1, 4);
    try stream.put(allocator, 3, 4);
    try stream.put(allocator, 0x3ffff, 18);
    try stream.put(allocator, 1, 1);
    try stream.put(allocator, 20, 10);
    try stream.put(allocator, 0, 3);

    try stream.start(allocator, 0x00);
    try stream.put(allocator, 0, 10);
    try stream.put(allocator, 4, 3);
    try stream.put(allocator, 0xffff, 16);
    try stream.put(allocator, 0, 1);

    try stream.start(allocator, 0x01);
    try stream.put(allocator, 1, 5);
    try stream.put(allocator, 0, 1);

    // Two macroblocks of DC terms: luma differences 10, -3, 0, 1 then -8, 0, 0, 0; chroma -20, 7 then 0, 0.
    try stream.code(allocator, "1");
    try stream.code(allocator, "1");
    try stream.code(allocator, "110 1010");
    try stream.code(allocator, "01 00");
    try stream.code(allocator, "100");
    try stream.code(allocator, "00 1");
    try stream.code(allocator, "11110 01011");
    try stream.code(allocator, "110 111");
    try stream.code(allocator, "1");

    try stream.code(allocator, "1");
    try stream.code(allocator, "1");
    try stream.code(allocator, "110 0111");
    try stream.code(allocator, "100");
    try stream.code(allocator, "100");
    try stream.code(allocator, "100");
    try stream.code(allocator, "00");
    try stream.code(allocator, "00");
    try stream.code(allocator, "1");

    try stream.start(allocator, 0xb7);

    var decoder = Decoder.init(std.testing.allocator);

    defer decoder.deinit(std.testing.allocator);

    try decoder.feed(std.testing.allocator, stream.bytes.items, 2.5);

    const picture = (try decoder.next(true)).?;

    try std.testing.expectEqual(Kind.dc, picture.kind);
    try std.testing.expectEqual(2.5, picture.time);
    try std.testing.expectEqual(Sequence{ .width = 32, .height = 16, .rate = 25 }, decoder.sequence().?);

    const quadrants = [_]u8{ 138, 135, 135, 136 };

    for (0..16) |row| {

        for (0..32) |column| {

            const expected: u8 = if (column < 16) quadrants[row / 8 * 2 + column % 16 / 8] else 128;

            try std.testing.expectEqual(expected, picture.y[row * 32 + column]);

        }

    }

    for (0..8) |row| {

        for (0..16) |column| {

            try std.testing.expectEqual(108, picture.cb[row * 16 + column]);
            try std.testing.expectEqual(135, picture.cr[row * 16 + column]);

        }

    }

    try std.testing.expectEqual(null, try decoder.next(true));

    // A sequence extension right after the header marks MPEG-2.
    var mpeg2 = Decoder.init(std.testing.allocator);

    defer mpeg2.deinit(std.testing.allocator);

    try mpeg2.feed(std.testing.allocator, stream.bytes.items[0..12], null);
    try mpeg2.feed(std.testing.allocator, &.{ 0, 0, 1, 0xb5, 0x14, 0x8a, 0, 1, 0, 0 }, null);
    try std.testing.expectError(error.Unsupported, mpeg2.next(true));

}

test "video survives corrupt, truncated, and reset streams without crashing" {

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();

    const allocator = arena.allocator();
    var prng = std.Random.DefaultPrng.init(0x11172);
    const random = prng.random();

    for ([_][]const u8{ gop_file, odd_file, sif_file }) |file| {

        const stream = try elementary(allocator, file);

        for (0..40) |round| {

            const bytes = try std.testing.allocator.dupe(u8, stream);

            defer std.testing.allocator.free(bytes);

            var length = bytes.len;

            switch (round % 4) {

                0 => for (0..random.intRangeAtMost(usize, 1, 40)) |_| {

                    bytes[random.uintLessThan(usize, bytes.len)] ^= @as(u8, 1) << random.int(u3);

                },
                1 => {

                    const at = random.uintLessThan(usize, bytes.len - 64);

                    random.bytes(bytes[at..][0..random.uintAtMost(usize, 64)]);

                },
                2 => length = random.uintLessThan(usize, bytes.len),
                else => {

                    const at = random.uintLessThan(usize, bytes.len - 256);

                    @memset(bytes[at..][0..random.uintAtMost(usize, 256)], if (round % 8 == 3) 0 else 0xff);

                },

            }

            var decoder = Decoder.init(std.testing.allocator);

            defer decoder.deinit(std.testing.allocator);

            var at: usize = 0;

            while (at < length) {

                const count = @min(length - at, random.intRangeAtMost(usize, 1, 3000));
                const time: ?f64 = if (random.boolean()) random.float(f64) * 10 else null;

                try decoder.feed(std.testing.allocator, bytes[at..][0..count], time);
                at += count;

                if (random.uintLessThan(u32, 50) == 0) decoder.reset();

                while (decoder.next(false) catch null) |picture| try std.testing.expect(picture.y.len >= picture.stride * picture.height);

            }

            while (decoder.next(true) catch null) |_| {}

        }

    }

}
