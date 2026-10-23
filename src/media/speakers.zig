//! Where a recording's channels play, and how more than two fold into stereo.

const std = @import("std");

/// WAVE's speaker positions as bits of a channel mask, in the order a file's channels interleave.
pub const Speaker = enum(u5) {

    front_left,
    front_right,
    front_center,
    low_frequency,
    back_left,
    back_right,
    front_left_center,
    front_right_center,
    back_center,
    side_left,
    side_right,
    top_center,
    top_front_left,
    top_front_center,
    top_front_right,
    top_back_left,
    top_back_center,
    top_back_right,
    _,

    /// How loud the speaker comes out of the left and right of a stereo pair, by ITU-R BS.775's downmix.
    fn gains(self: Speaker) [2]f32 {

        const half = std.math.sqrt1_2;

        return switch (self) {

            .front_left, .front_left_center => .{ 1, 0 },
            .front_right, .front_right_center => .{ 0, 1 },
            .front_center, .top_center, .top_front_center => .{ half, half },
            .back_left, .side_left, .top_front_left, .top_back_left => .{ half, 0 },
            .back_right, .side_right, .top_front_right, .top_back_right => .{ 0, half },
            .back_center, .top_back_center => .{ 0.5, 0.5 },
            .low_frequency => .{ 0, 0 },
            _ => .{ 0.5, 0.5 },

        };

    }

};

/// The most channels a file may have.
pub const most = 8;

/// The gains that fold each channel of a frame into a stereo pair.
pub const Downmix = struct {

    gains: [most][2]f32 = @splat(.{ 0, 0 }),
    count: u8,

    /// For `count` channels whose speakers `mask` names, lowest bit first; channels past those it names fall in the middle.
    pub fn init(count: u8, mask: u32) Downmix {

        var result = Downmix{

            .count = @min(count, most),

        };

        var remaining = if (mask == 0) (@as(u32, 1) << @intCast(result.count)) - 1 else mask;
        var loudest = [2]f32{ 0, 0 };

        for (result.gains[0..result.count]) |*gain| {

            if (remaining == 0) {

                gain.* = .{ 0.5, 0.5 };

            } else {

                gain.* = @as(Speaker, @enumFromInt(@ctz(remaining))).gains();
                remaining &= remaining - 1;

            }

            loudest[0] += gain[0];
            loudest[1] += gain[1];

        }

        // Scales the sum so channels at full scale together still fit.
        const scale = 1 / @max(loudest[0], loudest[1], 1);

        for (result.gains[0..result.count]) |*gain| gain.* = .{ gain[0] * scale, gain[1] * scale };

        return result;

    }

    /// The stereo pair a frame of `count` samples folds to.
    pub fn fold(self: *const Downmix, frame: []const f32) [2]f32 {

        var pair = [2]f32{ 0, 0 };

        for (frame[0..self.count], self.gains[0..self.count]) |sample, gain| {

            pair[0] += sample * gain[0];
            pair[1] += sample * gain[1];

        }

        return pair;

    }

};

test "downmixes weigh the centre and surrounds and drop the low-frequency channel" {

    const surround = Downmix.init(6, 0x3f);
    const scale: f32 = 1.0 / (1.0 + 2.0 * std.math.sqrt1_2);
    const pair = surround.fold(&.{ 1, 0, 0, 1, 0, 0 });

    try std.testing.expectApproxEqAbs(scale, pair[0], 1e-6);
    try std.testing.expectEqual(0, pair[1]);
    try std.testing.expectEqual(surround.fold(&.{ 0, 0, 1, 0, 0, 0 })[0], surround.fold(&.{ 0, 0, 1, 0, 0, 0 })[1]);
    try std.testing.expectApproxEqAbs(1, surround.fold(&.{ 1, 1, 1, 1, 1, 1 })[0], 1e-6);

    const quad = Downmix.init(4, 0);

    try std.testing.expectEqual(quad.gains, Downmix.init(4, 0xf).gains);

    const unnamed = Downmix.init(3, 0x1);

    try std.testing.expectEqual(unnamed.gains[1][0], unnamed.gains[1][1]);

}
