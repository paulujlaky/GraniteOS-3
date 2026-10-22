//! The system's short sounds, played from a few bell-like notes rather than kept as recordings.

const std = @import("std");

const mixer = @import("mixer.zig");

const Frame = mixer.Frame;

/// One note: when it starts and how long it rings, in seconds, its pitch in hertz, and its peak, full scale at one.
const Note = struct {

    start: f32,
    length: f32,
    pitch: f32,
    peak: f32,

    /// Its sound `t` seconds after it starts: a quick swell, then a decay that reaches silence as it ends.
    fn at(self: Note, t: f32) f32 {

        if (t < 0 or t >= self.length) return 0;

        const swell = @min(t / attack, 1);
        const fade = @exp(-4 * t / self.length) * (1 - t / self.length);
        const angle = std.math.tau * self.pitch * t;

        // A touch of the octave and twelfth above makes it ring like a small bell.
        return self.peak * swell * fade * (@sin(angle) + 0.3 * @sin(2 * angle) + 0.1 * @sin(3 * angle));

    }

};

/// Seconds a note takes to swell to its peak, short enough to sound struck yet long enough not to click.
const attack = 0.004;

pub const Tune = []const Note;

/// Indexed as `api.audio.Sound` numbers them.
pub const tunes = [_]Tune{

    // Signing in: a rising C major arpeggio.
    &.{

        .{ .start = 0, .length = 0.9, .pitch = 523.25, .peak = 0.16 },
        .{ .start = 0.09, .length = 0.85, .pitch = 659.25, .peak = 0.15 },
        .{ .start = 0.18, .length = 0.9, .pitch = 783.99, .peak = 0.15 },
        .{ .start = 0.27, .length = 1.1, .pitch = 1046.5, .peak = 0.13 },

    },

    // A notification: two soft notes, a fifth apart.
    &.{

        .{ .start = 0, .length = 0.45, .pitch = 880, .peak = 0.16 },
        .{ .start = 0.11, .length = 0.6, .pitch = 1318.5, .peak = 0.14 },

    },

    // Something refused: a falling third, low and short.
    &.{

        .{ .start = 0, .length = 0.25, .pitch = 329.63, .peak = 0.22 },
        .{ .start = 0.12, .length = 0.35, .pitch = 261.63, .peak = 0.22 },

    },

    // The volume changing: one short tick.
    &.{

        .{ .start = 0, .length = 0.07, .pitch = 987.77, .peak = 0.2 },

    },

    // A screenshot: two quick high notes, like a shutter.
    &.{

        .{ .start = 0, .length = 0.05, .pitch = 2093, .peak = 0.12 },
        .{ .start = 0.06, .length = 0.08, .pitch = 1567.98, .peak = 0.12 },

    },

};

/// Seconds until `tune`'s last note has died away.
pub fn duration(tune: Tune) f32 {

    var end: f32 = 0;

    for (tune) |note| end = @max(end, note.start + note.length);

    return end;

}

/// A tune playing, and how many frames of it have played.
pub const Voice = struct {

    tune: Tune,
    frame: u32 = 0,

    pub fn done(self: *const Voice) bool {

        return seconds(self.frame) >= duration(self.tune);

    }

    /// Adds its next `out.len` frames to `out` at `gain`.
    pub fn mix(self: *Voice, out: []Frame, gain: f32) void {

        for (out, self.frame..) |*frame, index| {

            const t = seconds(@intCast(index));
            var sum: f32 = 0;

            for (self.tune) |note| sum += note.at(t - note.start);

            frame.* += @as(Frame, @splat(sum * gain));

        }

        self.frame += @intCast(out.len);

    }

};

fn seconds(frame: u32) f32 {

    return @as(f32, @floatFromInt(frame)) / mixer.rate;

}
