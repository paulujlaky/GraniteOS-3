//! Line graphs drawn on the CPU into an image, so their curves get the anti-aliased edges the display's quads cannot draw.

const std = @import("std");

const sketch = @import("sketch.zig");
const theme = @import("theme.zig");

/// The widest graph drawn; wider areas draw nothing.
const widest = 4096;

/// The curve's height at each column edge, in pixels from the top; shared, since graphs draw one at a time.
var curve: [widest + 1]f32 = undefined;

/// Colours and line width of a graph, as 0xRRGGBB.
pub const Look = struct {

    background: u32 = theme.background,
    grid: u32 = theme.line,
    line: u32 = theme.accent,
    radius: i32 = theme.radius,

    /// How opaque the area under the curve is at its top and at the bottom; kept clear of the panels graphs sit on, so the fill never blends into its surroundings.
    fill: [2]f32 = .{ 0.34, 0.12 },
    width: f32 = 1.6,

    /// How far an exponential scale lifts small values, so small changes show; 0 plots evenly.
    emphasis: f32 = 3,

    /// Rows of grid lines splitting the height evenly.
    rows: u8 = 4,

};

/// A smooth graph of `values`, each from 0 to 1, oldest first; show it with `gui.chart`, and call `invalidate` after changing them.
pub const Graph = struct {

    values: []const f32,
    look: Look = .{},
    figure: sketch.Figure = .{

        .paint = &paint,

    },

    pub fn invalidate(self: *Graph) void {

        self.figure.invalidate();

    }

    fn paint(figure: *sketch.Figure, target: *sketch.Sketch) void {

        const self: *Graph = @fieldParentPtr("figure", figure);

        plot(target.pixels, target.width, target.height, self.values, self.look);

    }

};

/// Draws `values` as premultiplied 0xAARRGGBB `pixels`, `width` by `height`: a rounded background, grid rows, and a smooth curve over a fading fill.
pub fn plot(pixels: []u32, width: usize, height: usize, values: []const f32, look: Look) void {

    if (width == 0 or height == 0 or width > widest) return;

    const pad = look.width + 1;
    const span = @as(f32, @floatFromInt(height)) - 2 * pad;
    const last: f32 = @floatFromInt(@max(values.len, 2) - 1);

    // A monotone cubic through the samples, so the curve never swings past its neighbours, nor out of range.
    for (0..width + 1) |x| {

        const at = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(width)) * last;

        curve[x] = pad + (1 - lift(sample(values, at), look.emphasis)) * span;

    }

    const tall: f32 = @floatFromInt(height);
    const half = look.width / 2;

    for (0..height) |y| {

        const fy: f32 = @floatFromInt(y);
        const depth = std.math.clamp(fy / tall, 0, 1);
        const shade = look.fill[0] + (look.fill[1] - look.fill[0]) * depth;
        const ruled = look.rows > 1 and y != 0 and (y * look.rows) % height < look.rows;

        for (0..width) |x| {

            var pixel = Pixel.solid(look.background);

            if (ruled) pixel.over(look.grid, 1);

            // Four samples across the column cover the curve's slope.
            var covered: f32 = 0;

            for (0..4) |step| {

                const t = (@as(f32, @floatFromInt(step)) + 0.5) / 4;

                covered += std.math.clamp(fy + 1 - (curve[x] + (curve[x + 1] - curve[x]) * t), 0, 1) / 4;

            }

            pixel.over(look.line, covered * shade);
            pixel.over(look.line, std.math.clamp(half + 0.5 - distance(x, fy + 0.5, width), 0, 1));
            pixels[y * width + x] = pixel.pack(sketch.inside(x, y, width, height, look.radius));

        }

    }

}

/// The value `at` samples along `values`, eased between them by Fritsch-Butland tangents.
fn sample(values: []const f32, at: f32) f32 {

    if (values.len == 0) return 0;
    if (values.len == 1) return std.math.clamp(values[0], 0, 1);

    const index: usize = @min(@as(usize, @intFromFloat(at)), values.len - 2);
    const t = at - @as(f32, @floatFromInt(index));
    const a = values[index];
    const b = values[index + 1];
    const m0 = tangent(values, index);
    const m1 = tangent(values, index + 1);
    const t2 = t * t;
    const t3 = t2 * t;

    return std.math.clamp((2 * t3 - 3 * t2 + 1) * a + (t3 - 2 * t2 + t) * m0 + (-2 * t3 + 3 * t2) * b + (t3 - t2) * m1, 0, 1);

}

/// `value` on an exponential scale that rises steeply near 0 and still ends at 1; it keeps order, so the curve stays monotone between samples.
fn lift(value: f32, emphasis: f32) f32 {

    if (emphasis <= 0) return value;

    return (1 - @exp(-emphasis * value)) / (1 - @exp(-emphasis));

}

fn tangent(values: []const f32, index: usize) f32 {

    if (index == 0) return values[1] - values[0];
    if (index == values.len - 1) return values[index] - values[index - 1];

    const before = values[index] - values[index - 1];
    const after = values[index + 1] - values[index];

    if (before * after <= 0) return 0;

    return 2 * before * after / (before + after);

}

/// How far the pixel centre in column `x` at height `y` lies from the curve, looking a few columns either side.
fn distance(x: usize, y: f32, width: usize) f32 {

    const px = @as(f32, @floatFromInt(x)) + 0.5;
    var nearest: f32 = std.math.inf(f32);
    var column = x -| 2;

    while (column < @min(x + 3, width)) : (column += 1) {

        const ax: f32 = @floatFromInt(column);
        const ay = curve[column];
        const dy = curve[column + 1] - ay;
        const t = std.math.clamp(((px - ax) + (y - ay) * dy) / (1 + dy * dy), 0, 1);
        const ex = px - (ax + t);
        const ey = y - (ay + dy * t);

        nearest = @min(nearest, @sqrt(ex * ex + ey * ey));

    }

    return nearest;

}

/// An opaque colour being built up in floats, layer over layer.
const Pixel = struct {

    channels: [3]f32,

    fn solid(color: u32) Pixel {

        return .{

            .channels = .{ channel(color, 16), channel(color, 8), channel(color, 0) },

        };

    }

    fn over(self: *Pixel, color: u32, alpha: f32) void {

        if (alpha <= 0) return;

        for (&self.channels, [_]u5{ 16, 8, 0 }) |*value, shift| value.* += (channel(color, shift) - value.*) * @min(alpha, 1);

    }

    /// Premultiplied by `coverage`, as images want.
    fn pack(self: Pixel, coverage: f32) u32 {

        var result: u32 = @as(u32, @intFromFloat(coverage * 255 + 0.5)) << 24;

        for (self.channels, [_]u5{ 16, 8, 0 }) |value, shift| result |= @as(u32, @intFromFloat(value * coverage + 0.5)) << shift;

        return result;

    }

};

fn channel(color: u32, shift: u5) f32 {

    return @floatFromInt(color >> shift & 0xff);

}
