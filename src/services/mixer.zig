//! The audio service's arithmetic: each stream resampled to the device's rate, streams added together under gains that
//! glide rather than jump, and the sum rounded to the device's 16-bit samples.

const std = @import("std");

/// The device's frame rate, which every stream is resampled to.
pub const rate = 48000;

/// A stereo frame as the mix adds it up, full scale at ±1.
pub const Frame = @Vector(2, f32);

pub const silence: Frame = @splat(0);

/// One source frame in 32.32 fixed point, the resampler's unit of position.
const unit: u64 = 1 << 32;

/// The frames a client has written to its ring and the service has not yet taken; frame `n` of the stream sits at
/// `n % capacity`, its channels interleaved.
pub fn Ring(comptime Sample: type) type {

    return struct {

        const Self = @This();

        samples: []const Sample,
        channels: u8,
        capacity: u64,

        /// The next frame to take, and one past the last written.
        taken: u64,
        written: u64,

        fn next(self: *Self) ?Frame {

            if (self.taken == self.written) return null;

            const at: usize = @intCast(self.taken % self.capacity * self.channels);
            const left = level(self.samples[at]);

            self.taken += 1;

            return if (self.channels == 1) @splat(left) else .{ left, level(self.samples[at + 1]) };

        }

    };

}

/// A sample at full scale ±1; floats beyond it, or not numbers at all, are held to it so one bad stream cannot spoil the mix.
fn level(sample: anytype) f32 {

    return switch (@TypeOf(sample)) {

        i16 => @as(f32, @floatFromInt(sample)) / 32768,
        f32 => @min(@max(sample, -1), 1),
        else => @compileError("unsupported sample type"),

    };

}

/// Turns one stream's frames into frames at the device's rate, interpolating between source frames along a cubic.
pub const Resampler = struct {

    /// Source frames per device frame, and how far past `window[1]` the next device frame falls; starting a whole frame
    /// on reads the first source frame at once.
    step: u64,
    phase: u64 = unit,

    /// The source frames around the position: one before, the two either side, and one after.
    window: [4]Frame = .{silence} ** 4,

    /// The gain the last block ended on, where the next starts.
    gain: f32 = 0,

    pub fn init(source: u32) Resampler {

        return .{

            .step = (@as(u64, source) << 32) / rate,

        };

    }

    /// Source frames that `frames` device frames take, rounded down.
    pub fn span(self: *const Resampler, frames: u64) u64 {

        return @intCast(@as(u128, frames) * self.step >> 32);

    }

    /// Forgets the frames it was between, as after frames were dropped, so nothing old bleeds into what follows.
    pub fn reset(self: *Resampler) void {

        self.phase = unit;
        self.window = .{silence} ** 4;

    }

    /// Adds up to `out.len` device frames from `ring` to `out`, the gain gliding from where it was to `target`; returns how
    /// many, fewer when the ring runs dry.
    pub fn mix(self: *Resampler, comptime Sample: type, ring: *Ring(Sample), out: []Frame, target: f32) usize {

        if (out.len == 0) return 0;

        const start = self.gain;
        const slope = (target - start) / @as(f32, @floatFromInt(out.len));
        var produced: usize = 0;

        fill: while (produced < out.len) : (produced += 1) {

            while (self.phase >= unit) {

                const frame = ring.next() orelse break :fill;

                self.window = .{ self.window[1], self.window[2], self.window[3], frame };
                self.phase -= unit;

            }

            const value = if (self.phase == 0) self.window[1] else cubic(self.window, @as(f32, @floatFromInt(self.phase)) / unit);
            const gain: Frame = @splat(start + slope * @as(f32, @floatFromInt(produced)));

            out[produced] += value * gain;
            self.phase += self.step;

        }

        self.gain = start + slope * @as(f32, @floatFromInt(produced));

        return produced;

    }

};

/// The Catmull-Rom curve through the middle two of `window`'s frames, `t` of the way from the first to the second.
fn cubic(window: [4]Frame, t: f32) Frame {

    const before, const from, const to, const after = window;
    const half: Frame = @splat(0.5);
    const s: Frame = @splat(t);

    const a = (after - before) * half + (from - to) * @as(Frame, @splat(1.5));
    const b = before - from * @as(Frame, @splat(2.5)) + to * @as(Frame, @splat(2)) - after * half;
    const c = (to - before) * half;

    return ((a * s + b) * s + c) * s + from;

}

/// Rounds `mix` to 16-bit samples, left then right, clipping what lies beyond full scale.
pub fn quantize(mix: []const Frame, out: []i16) void {

    const flat = @as([*]const f32, @ptrCast(mix.ptr))[0 .. mix.len * 2];

    for (flat, out[0..flat.len]) |value, *sample| sample.* = @intFromFloat(@round(@min(@max(value, -1), 1) * 32767));

}

/// The gain of a volume in percent, cubed so equal steps sound about equally far apart.
pub fn loudness(percent: u8) f32 {

    const x = @as(f32, @floatFromInt(@min(percent, 100))) / 100;

    return x * x * x;

}

/// Where the device is in its cyclic buffer, counted in frames since it started from cyclic byte offsets.
pub const Cursor = struct {

    /// The buffer's length in bytes, the offset last read, and the bytes played in all.
    size: u32,
    last: u32 = 0,
    bytes: u64 = 0,

    /// Takes in the device's offset now, returning the frames played; it must have moved less than the whole buffer since
    /// last time.
    pub fn advance(self: *Cursor, offset: u32) u64 {

        const at = offset % self.size;

        self.bytes += (at + self.size - self.last) % self.size;
        self.last = at;

        return self.bytes / 4;

    }

};
