//! Quartz: the frosted material under bars, docks, menus, and windows, showing what lies behind them softened under a graphite tint.
//! The display softens on a grid a quarter of the screen's resolution each way, in passes its GPU and CPU share: each texel averages
//! its block of the screen, a Gaussian blurs the grid across and then down, and the screen samples it smoothly back up.

const std = @import("std");

const canvas = @import("canvas.zig");

const Rect = canvas.Rect;

/// Screen pixels to a grid texel, each way.
pub const scale = 4;

/// Texels either side of each one the Gaussian takes in; three standard deviations span them, as shadows soften.
pub const taps = 6;

/// How far past the pixels it draws Quartz reads what lies behind them.
pub const reach = scale * (taps + 2);

/// The Gaussian from its middle tap outwards, normalised over both sides.
const gaussian = curve: {

    var values: [taps + 1]f32 = undefined;
    var total: f32 = 0;

    for (&values, 0..) |*value, k| {

        const x: f32 = @floatFromInt(k);

        value.* = @exp(-x * x * 4.5 / (taps * taps));
        total += if (k == 0) value.* else 2 * value.*;

    }

    for (&values) |*value| value.* /= total;

    break :curve values;

};

/// The Gaussian in 16.16 fixed point for the CPU; the middle tap takes what rounding leaves, so all of them sum to exactly one.
pub const weights = fixed: {

    var values: [taps + 1]u32 = undefined;
    var sides: u32 = 0;

    for (values[1..], gaussian[1..]) |*value, weight| {

        value.* = @intFromFloat(@round(weight * 65536));
        sides += 2 * value.*;

    }

    values[0] = 65536 - sides;

    break :fixed values;

};

/// The Gaussian for the GPU, whose smooth sampling reads two neighbouring taps at once: how far out each pair of taps samples, and
/// their combined weight, after the middle tap at no distance.
pub const pairs = merged: {

    var values: [taps / 2 + 1][2]f32 = undefined;

    values[0] = .{ 0, gaussian[0] };

    for (values[1..], 0..) |*pair, index| {

        const near = gaussian[2 * index + 1];
        const far = gaussian[2 * index + 2];

        pair.* = .{ (near * (2 * index + 1) + far * (2 * index + 2)) / (near + far), near + far };

    }

    break :merged values;

};

/// The grid a `width` by `height` screen softens on.
pub fn grid(width: usize, height: usize) [2]usize {

    return .{ (width + scale - 1) / scale, (height + scale - 1) / scale };

}

/// The pixels of room the CPU softens a `width` by `height` screen in: the grid twice over.
pub fn room(width: usize, height: usize) usize {

    const size = grid(width, height);

    return 2 * size[0] * size[1];

}

/// The grid texels each pass fills so `visible` can be drawn: `gathered` from the screen, blurred `across` from those, then `down`
/// from those, which the screen samples.
pub const Plan = struct {

    gathered: Rect,
    across: Rect,
    down: Rect,

    /// What drawing `visible` takes on a `columns` by `rows` grid; null when it lies off the grid.
    pub fn of(visible: Rect, columns: usize, rows: usize) ?Plan {

        const all = Rect{

            .width = @intCast(columns),
            .height = @intCast(rows),

        };

        const left = @divFloor(visible.x, scale) - 1;
        const top = @divFloor(visible.y, scale) - 1;

        // Each pixel samples the two texels either side of its centre, so one more each way than those under it.
        const needed = Rect{

            .x = left,
            .y = top,
            .width = @divFloor(visible.right() + scale - 1, scale) + 1 - left,
            .height = @divFloor(visible.bottom() + scale - 1, scale) + 1 - top,

        };

        const down = needed.intersect(all) orelse return null;

        const across = (Rect{

            .x = down.x,
            .y = down.y - taps,
            .width = down.width,
            .height = down.height + 2 * taps,

        }).intersect(all).?;

        const gathered = (Rect{

            .x = across.x - taps,
            .y = across.y,
            .width = across.width + 2 * taps,
            .height = across.height,

        }).intersect(all).?;

        return .{

            .gathered = gathered,
            .across = across,
            .down = down,

        };

    }

};

/// A pixel's channels, wide enough for weighted sums of them.
pub const Channels = @Vector(4, u32);

/// Softens what `source` shows into the first grid of `spare`, as `plan` says, under `tint`; the second grid holds the blur across.
pub fn soften(source: *const canvas.Canvas, plan: Plan, spare: []u32, tint: u32) void {

    const size = grid(source.width, source.height);
    const columns = size[0];
    const soft = spare[0 .. columns * size[1]];
    const smear = spare[soft.len..][0..soft.len];

    for (@intCast(plan.gathered.y)..@intCast(plan.gathered.bottom())) |y| {

        for (@intCast(plan.gathered.x)..@intCast(plan.gathered.right())) |x| {

            var sum: Channels = @splat(0);

            // A block at the screen's edge repeats its last pixels, as the GPU's sampling does.
            for (0..scale) |dy| {

                const row = source.pixels[@min(y * scale + dy, source.height - 1) * source.width ..][0..source.width];

                for (0..scale) |dx| sum += split(row[@min(x * scale + dx, source.width - 1)]);

            }

            soft[y * columns + x] = join(sum, scale * scale);

        }

    }

    for (@intCast(plan.across.y)..@intCast(plan.across.bottom())) |y| {

        const row = soft[y * columns ..][0..columns];

        for (@intCast(plan.across.x)..@intCast(plan.across.right())) |x| {

            var sum = split(row[x]) * splat(weights[0]);

            for (1..taps + 1) |k| sum += (split(row[x -| k]) + split(row[@min(x + k, columns - 1)])) * splat(weights[k]);

            smear[y * columns + x] = join(sum, 65536);

        }

    }

    // Tinting the grid rather than the screen tints sixteen times fewer pixels, and blends the same.
    for (@intCast(plan.down.y)..@intCast(plan.down.bottom())) |y| {

        for (@intCast(plan.down.x)..@intCast(plan.down.right())) |x| {

            var sum = split(smear[y * columns + x]) * splat(weights[0]);

            for (1..taps + 1) |k| sum += (split(smear[(y -| k) * columns + x]) + split(smear[@min(y + k, size[1] - 1) * columns + x])) * splat(weights[k]);

            soft[y * columns + x] = tinted(join(sum, 65536), tint);

        }

    }

}

/// `color` under `tint`, as far as the tint is opaque.
pub fn tinted(color: u32, tint: u32) u32 {

    const amount = 255 - (tint >> 24);

    return join(split(color) * splat(255 - amount) + split(tint) * splat(amount), 255);

}

/// The red, green, and blue of 0x00RRGGBB `pixel`, and its top byte.
pub fn split(pixel: u32) Channels {

    const shifts = @Vector(4, u5){ 0, 8, 16, 24 };

    return (@as(Channels, @splat(pixel)) >> shifts) & splat(0xff);

}

/// Packs the first three channels of `sum`, each divided by `total` and rounded, back into 0x00RRGGBB.
pub fn join(sum: Channels, comptime total: u32) u32 {

    const channels = (sum + splat(total / 2)) / splat(total);

    return channels[0] | channels[1] << 8 | channels[2] << 16;

}

pub fn splat(value: u32) Channels {

    return @splat(value);

}
