//! Line graphs drawn as a sketch: a smooth anti-aliased curve over a fading fill, which the display draws on its GPU.

const std = @import("std");

const canvas = @import("canvas.zig");
const sketch = @import("sketch.zig");
const theme = @import("theme.zig");

/// The curve's points: one every `pitch` pixels across the widest graph drawn; wider graphs space them further apart.
const pitch = 2;
var curve: [sketch.most][2]f32 = undefined;

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

        plot(target, self.values, self.look);

    }

};

/// Draws `values` over `target`: a rounded background, grid rows, and a smooth curve over a fading fill.
pub fn plot(target: *sketch.Sketch, values: []const f32, look: Look) void {

    if (target.width == 0 or target.height == 0) return;

    const width: f32 = @floatFromInt(target.width);
    const height: f32 = @floatFromInt(target.height);
    const radius: f32 = @floatFromInt(look.radius);
    const pad = look.width + 1;
    const span = height - 2 * pad;
    const last: f32 = @floatFromInt(@max(values.len, 2) - 1);
    const count = std.math.clamp(target.width / pitch + 1, 2, curve.len);

    target.rectangle(.{ 0, 0, width, height }, radius, 0, look.background);

    for (1..look.rows) |row| {

        const y = @floor(height * @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(look.rows)));

        target.rectangle(.{ 0, y, width, y + 1 }, 0, 0, look.grid);

    }

    // A monotone cubic through the samples, so the curve never swings past its neighbours, nor out of range.
    for (curve[0..count], 0..) |*point, index| {

        const x = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(count - 1));

        point.* = .{ x * width, pad + (1 - lift(sample(values, x * last), look.emphasis)) * span };

    }

    target.curve(curve[0..count], look.width, look.line, .{

        .floor = height,
        .ceiling = 0,
        .colors = .{ canvas.shade(look.line, level(look.fill[0])), canvas.shade(look.line, level(look.fill[1])) },
        .radius = radius,

    });

}

fn level(amount: f32) u8 {

    return @intFromFloat(std.math.clamp(amount, 0, 1) * 255 + 0.5);

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
