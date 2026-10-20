//! The dark granite drawn behind the desktop when no picture is chosen.

const std = @import("std");

const gui = @import("gui");

/// Paints dark granite: light falling from the top left over mottled stone, flecked lighter and darker; each pixel spans
/// `scale` screen pixels, so a small preview shows the same stone as the desktop.
pub fn paint(picture: *gui.Image, scale: f32) void {

    const pixels = picture.pixels();
    const width = @as(f32, @floatFromInt(picture.width)) * scale;
    const tall = @as(f32, @floatFromInt(picture.height)) * scale;

    for (0..picture.height) |y| {

        for (0..picture.width) |x| {

            const fx = @as(f32, @floatFromInt(x)) * scale;
            const fy = @as(f32, @floatFromInt(y)) * scale;
            const light = 1 - (fx / width * 0.55 + fy / tall * 0.45);
            const stone = noise(fx / 240, fy / 240) * 9 + noise(fx / 70, fy / 70) * 5;
            const grain = noise(fx / 1.7 + 91, fy / 1.7 + 17);
            const fleck: f32 = if (grain > 0.7) 34 * (grain - 0.7) / 0.3 else if (grain < -0.75) -6 else 0;
            const level = std.math.clamp(19 + 22 * light * light + stone + fleck, 0, 255);
            const value: u32 = @intFromFloat(level);

            pixels[y * picture.width + x] = 0xff000000 | value << 16 | value << 8 | value;

        }

    }

}

/// Smooth value noise in -1..1 over a lattice of random heights.
fn noise(x: f32, y: f32) f32 {

    const left = @floor(x);
    const top = @floor(y);
    const u = smooth(x - left);
    const v = smooth(y - top);
    const column: i32 = @intFromFloat(left);
    const row: i32 = @intFromFloat(top);

    const upper = lattice(column, row) + (lattice(column + 1, row) - lattice(column, row)) * u;
    const lower = lattice(column, row + 1) + (lattice(column + 1, row + 1) - lattice(column, row + 1)) * u;

    return upper + (lower - upper) * v;

}

fn smooth(t: f32) f32 {

    return t * t * (3 - 2 * t);

}

fn lattice(x: i32, y: i32) f32 {

    var hash = @as(u32, @bitCast(x)) *% 0x9e3779b1 ^ @as(u32, @bitCast(y)) *% 0x85ebca77;

    hash = (hash ^ (hash >> 15)) *% 0x2c1b3c6d;
    hash = (hash ^ (hash >> 12)) *% 0x297a2d39;
    hash ^= hash >> 15;

    return @as(f32, @floatFromInt(hash & 0xffff)) / 32767.5 - 1;

}
