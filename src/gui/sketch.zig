//! Anti-aliased shapes beyond rounded rectangles, such as lines at any angle, rings, arcs, ellipses, and curves.
//! A sketch records them for the display to draw on its GPU, or paints them on the CPU into pixels, such as a drawing's canvas.

const std = @import("std");

const canvas = @import("canvas.zig");
const draw = @import("draw.zig");
const node = @import("node.zig");

const Rect = canvas.Rect;

/// Most points a shape's outline takes on the GPU, a curve's included.
pub const most = 4096;

/// Points (x, y) along a curve, which may sit unaligned in a drawing command.
pub const Points = []align(1) const [2]f32;

/// Paints shapes in pixel coordinates whose centres sit at halves.
/// Colours are 0xTTRRGGBB as everywhere else, so plain 0xRRGGBB is opaque and `canvas.shade` makes it translucent.
pub const Sketch = struct {

    /// Premultiplied 0xAARRGGBB pixels painted on the CPU, `width` by `height`; with `list`, only the size of the area drawn in.
    pixels: []u32 = &.{},
    width: usize,
    height: usize,

    /// When set, shapes are recorded here for the display, moved by `origin`, rather than painted.
    list: ?*draw.List = null,
    origin: canvas.Point = .{},

    /// Fills every pixel with `color`, or makes them all transparent with `clear(transparent)`; recording, a transparent clear draws nothing.
    pub fn clear(self: *Sketch, color: u32) void {

        if (self.list) |list| {

            if (color >> 24 != 0xff) list.fill(.{

                .x = self.origin.x,
                .y = self.origin.y,
                .width = @intCast(self.width),
                .height = @intCast(self.height),

            }, color);

            return;

        }

        @memset(self.pixels[0 .. self.width * self.height], premultiply(color, 1));

    }

    pub fn disc(self: *Sketch, x: f32, y: f32, radius: f32, color: u32) void {

        self.form(.{

            .disc = .{

                .x = x,
                .y = y,
                .radius = radius,

            },

        }, color);

    }

    /// A circle's outline `width` pixels thick, centred on `radius`.
    pub fn ring(self: *Sketch, x: f32, y: f32, radius: f32, width: f32, color: u32) void {

        self.form(.{

            .ring = .{

                .x = x,
                .y = y,
                .radius = radius,
                .half = width / 2,

            },

        }, color);

    }

    /// A line `width` pixels thick with round ends, such as a brush stroke or a clock hand.
    pub fn line(self: *Sketch, x0: f32, y0: f32, x1: f32, y1: f32, width: f32, color: u32) void {

        self.form(.{

            .line = .{

                .x = x0,
                .y = y0,
                .dx = x1 - x0,
                .dy = y1 - y0,
                .half = width / 2,

            },

        }, color);

    }

    /// Part of a ring with round ends, from turn `start` to turn `end` clockwise from twelve o'clock, such as a countdown's progress.
    pub fn arc(self: *Sketch, x: f32, y: f32, radius: f32, width: f32, start: f32, end: f32, color: u32) void {

        if (end - start >= 1) return self.ring(x, y, radius, width, color);
        if (end <= start) return;

        self.form(.{

            .arc = .{

                .x = x,
                .y = y,
                .radius = radius,
                .half = width / 2,
                .start = start,
                .end = end,

            },

        }, color);

    }

    /// An ellipse inside `box` (left, top, right, bottom), filled when `width` is 0, else outlined `width` pixels thick.
    pub fn ellipse(self: *Sketch, box: [4]f32, width: f32, color: u32) void {

        self.form(.{

            .ellipse = .{

                .x = (box[0] + box[2]) / 2,
                .y = (box[1] + box[3]) / 2,
                .rx = @max(@abs(box[2] - box[0]) / 2, 0.5),
                .ry = @max(@abs(box[3] - box[1]) / 2, 0.5),
                .half = width / 2,

            },

        }, color);

    }

    /// A rectangle inside `box` (left, top, right, bottom) with corners of `radius`, filled when `width` is 0, else outlined `width` pixels thick.
    pub fn rectangle(self: *Sketch, box: [4]f32, radius: f32, width: f32, color: u32) void {

        const left = @min(box[0], box[2]);
        const top = @min(box[1], box[3]);
        const right = @max(box[0], box[2]);
        const bottom = @max(box[1], box[3]);

        self.form(.{

            .rectangle = .{

                .x = (left + right) / 2,
                .y = (top + bottom) / 2,
                .rx = (right - left) / 2,
                .ry = (bottom - top) / 2,
                .radius = @max(@min(radius, @min(right - left, bottom - top) / 2), 0),
                .half = width / 2,

            },

        }, color);

    }

    /// A line through `points`, each (x, y), `width` pixels thick; with `under`, the area between it and the floor is shaded first, so points must run left to right.
    pub fn curve(self: *Sketch, points: Points, width: f32, color: u32, under: ?Under) void {

        if (points.len < 2) return;
        if (self.list) |list| return list.curve(points, self.origin, width, color, under);

        if (under) |area| shade(self, points, area, .{ 0, 0 });

        self.cover(color, Polyline{

            .points = points,
            .half = width / 2,

        });

    }

    fn form(self: *Sketch, shape: Form, color: u32) void {

        if (self.list) |list| return list.form(shape.moved(@floatFromInt(self.origin.x), @floatFromInt(self.origin.y)), color);

        self.cover(color, shape);

    }

    /// Blends `color` over every pixel `shape` touches, as far as it covers it.
    fn cover(self: *Sketch, color: u32, shape: anytype) void {

        const span = canvas.touched(shape.box(), .{

            .width = @intCast(self.width),
            .height = @intCast(self.height),

        }) orelse return;
        const alpha = canvas.opacity(color);

        for (span.top..span.bottom) |y| {

            const row = self.pixels[y * self.width ..];
            const fy = @as(f32, @floatFromInt(y)) + 0.5;

            for (span.left..span.right) |x| {

                const coverage = std.math.clamp(0.5 - shape.distance(@as(f32, @floatFromInt(x)) + 0.5, fy), 0, 1);

                if (coverage > 0) row[x] = over(row[x], color, coverage * alpha);

            }

        }

    }

    /// The pixels `shade` may paint.
    fn region(self: *const Sketch) ?Rect {

        return .{

            .width = @intCast(self.width),
            .height = @intCast(self.height),

        };

    }

    /// Blends one pixel, as `canvas.Canvas.mix` does, for `shade`.
    fn mix(self: *Sketch, x: usize, y: usize, color: u32, alpha: f32) void {

        self.pixels[y * self.width + x] = over(self.pixels[y * self.width + x], color, alpha);

    }

};

/// How a curve shades the area below it, down to `floor`: `colors[0]` at `ceiling` fading to `colors[1]` at the floor,
/// whose two ends round up like the bottom corners of a box with corners of `radius`.
pub const Under = struct {

    floor: f32,
    ceiling: f32,
    colors: [2]u32,
    radius: f32 = 0,

    /// The floor at `x` along a curve running from `left` to `right`.
    pub fn bottom(self: Under, x: f32, left: f32, right: f32) f32 {

        const within = @min(x - left, right - x);
        if (within >= self.radius or self.radius <= 0) return self.floor;

        const d = self.radius - @max(within, 0);

        return self.floor - self.radius + @sqrt(@max(self.radius * self.radius - d * d, 0));

    }

    /// The shade at height `y`, as 0xTTRRGGBB.
    pub fn color(self: Under, y: f32) u32 {

        const t = std.math.clamp((y - self.ceiling) / @max(self.floor - self.ceiling, 1), 0, 1);
        var result: u32 = 0;

        for ([_]u5{ 0, 8, 16, 24 }) |shift| {

            const a: f32 = @floatFromInt(self.colors[0] >> shift & 0xff);
            const b: f32 = @floatFromInt(self.colors[1] >> shift & 0xff);

            result |= @as(u32, @intFromFloat(a + (b - a) * t + 0.5)) << shift;

        }

        return result;

    }

};

/// Shades the area between `points`, running left to right, and the floor `under` describes, column by column into `target`, a `Sketch` or `canvas.Canvas`;
/// `shift` moves both onto the target.
pub fn shade(target: anytype, points: Points, under: Under, shift: [2]f32) void {

    const left = points[0][0];
    const right = points[points.len - 1][0];
    const limit = target.region() orelse return;
    const sx: i32 = @intFromFloat(shift[0]);
    const sy: i32 = @intFromFloat(shift[1]);
    var piece: usize = 0;
    var x = @max(@as(i32, @intFromFloat(@floor(left))), limit.x - sx);

    // Columns and rows count in the points' own coordinates, landing `shift` along.
    while (x < @min(@as(i32, @intFromFloat(@ceil(right))), limit.right() - sx)) : (x += 1) {

        const fx = @as(f32, @floatFromInt(x)) + 0.5;

        while (piece + 2 < points.len and points[piece + 1][0] < fx) piece += 1;

        const a = points[piece];
        const b = points[piece + 1];
        const t = if (b[0] == a[0]) 0 else std.math.clamp((fx - a[0]) / (b[0] - a[0]), 0, 1);
        const top = a[1] + (b[1] - a[1]) * t;
        const floor = under.bottom(fx, left, right);
        var y = @max(@as(i32, @intFromFloat(@floor(top))), limit.y - sy);

        while (y < @min(@as(i32, @intFromFloat(@ceil(floor))), limit.bottom() - sy)) : (y += 1) {

            const fy: f32 = @floatFromInt(y);
            const covered = std.math.clamp(@min(fy + 1, floor) - @max(fy, top), 0, 1);
            const tint = under.color(fy + 0.5);

            target.mix(@intCast(x + sx), @intCast(y + sy), tint & 0xffffff, covered * canvas.opacity(tint));

        }

    }

}

pub const transparent = canvas.shade(0, 0);

/// One shape a sketch draws, kept as the signed distance from any point to its edge, negative inside.
/// Every variant starts with `x` and `y`, so moving one moves just those.
pub const Form = union(enum(u32)) {

    disc: Disc,
    ring: Ring,
    line: Capsule,
    arc: Arc,
    ellipse: Ellipse,
    rectangle: Box,

    pub fn distance(self: Form, px: f32, py: f32) f32 {

        return switch (self) {

            inline else => |shape| shape.distance(px, py),

        };

    }

    /// The box (left, top, right, bottom) it may touch.
    pub fn box(self: Form) [4]f32 {

        return switch (self) {

            inline else => |shape| shape.box(),

        };

    }

    pub fn moved(self: Form, dx: f32, dy: f32) Form {

        var result = self;

        switch (result) {

            inline else => |*shape| {

                shape.x += dx;
                shape.y += dy;

            },

        }

        return result;

    }

    /// The shape's fields as they travel in a drawing command.
    pub fn values(self: Form) [8]f32 {

        var result = [_]f32{0} ** 8;

        switch (self) {

            inline else => |shape| @memcpy(std.mem.sliceAsBytes(result[0 .. @sizeOf(@TypeOf(shape)) / 4]), std.mem.asBytes(&shape)),

        }

        return result;

    }

    /// The shape `kind` names with fields `fields`, or null when any is out of range.
    pub fn read(kind: u32, fields: [8]f32) ?Form {

        for (fields) |value| {

            if (!std.math.isFinite(value) or @abs(value) > 1 << 20) return null;

        }

        inline for (@typeInfo(Form).@"union".fields, 0..) |field, index| {

            if (kind == index) {

                const shape = std.mem.bytesToValue(field.type, std.mem.sliceAsBytes(fields[0 .. @sizeOf(field.type) / 4]));

                // Negative sizes would turn shapes inside out.
                inline for (@typeInfo(field.type).@"struct".fields) |member| {

                    if (comptime !std.mem.eql(u8, member.name, "x") and !std.mem.eql(u8, member.name, "y") and !std.mem.eql(u8, member.name, "dx") and !std.mem.eql(u8, member.name, "dy") and !std.mem.eql(u8, member.name, "start") and !std.mem.eql(u8, member.name, "end")) {

                        if (@field(shape, member.name) < 0) return null;

                    }

                }

                return @unionInit(Form, field.name, shape);

            }

        }

        return null;

    }

    /// The outline the GPU draws: points along its edge, or along its middle when it has a width, written into `out`.
    pub fn path(self: Form, out: [][2]f32) Path {

        switch (self) {

            .disc => |shape| return circle(out, shape.x, shape.y, shape.radius, shape.radius, 0),
            .ring => |shape| return circle(out, shape.x, shape.y, shape.radius, shape.radius, shape.half),
            .ellipse => |shape| return circle(out, shape.x, shape.y, shape.rx, shape.ry, shape.half),
            .line => |shape| {

                if (shape.dx == 0 and shape.dy == 0) return circle(out, shape.x, shape.y, shape.half, shape.half, 0);

                out[0] = .{ shape.x, shape.y };
                out[1] = .{ shape.x + shape.dx, shape.y + shape.dy };

                return .{

                    .points = out[0..2],
                    .half = shape.half,
                    .closed = false,

                };

            },
            .arc => |shape| {

                const count = @max(steps(shape.radius + shape.half, shape.end - shape.start), 2);

                for (out[0 .. count + 1], 0..) |*point, index| {

                    const turn = (shape.start + (shape.end - shape.start) * @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(count))) * std.math.tau;

                    point.* = .{ shape.x + @sin(turn) * shape.radius, shape.y - @cos(turn) * shape.radius };

                }

                return .{

                    .points = out[0 .. count + 1],
                    .half = shape.half,
                    .closed = false,

                };

            },
            .rectangle => |shape| {

                const r = shape.radius;
                const quarter = if (r < 0.5) 0 else steps(r, 0.25);
                var count: usize = 0;

                // Corner by corner clockwise from the top right, each a quarter circle unless square.
                for ([_][2]f32{ .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 }, .{ -1, -1 } }, 0..) |sign, corner| {

                    const cx = shape.x + sign[0] * (shape.rx - r);
                    const cy = shape.y + sign[1] * (shape.ry - r);

                    for (0..quarter + 1) |index| {

                        const turn = (@as(f32, @floatFromInt(corner)) + @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(@max(quarter, 1)))) * std.math.tau / 4;

                        out[count] = .{ cx + @sin(turn) * r, cy - @cos(turn) * r };
                        count += 1;

                    }

                }

                return .{

                    .points = out[0..count],
                    .half = shape.half,

                };

            },

        }

    }

};

/// A shape's outline for the GPU: filled when `half` is zero, else a band `half` either side; open ones get round ends.
pub const Path = struct {

    points: [][2]f32,
    half: f32,
    closed: bool = true,

};

/// Points around an ellipse, clockwise from twelve o'clock, enough that no chord strays a twentieth of a pixel from the curve.
fn circle(out: [][2]f32, x: f32, y: f32, rx: f32, ry: f32, half: f32) Path {

    const count = steps(@max(rx, ry) + half, 1);

    for (out[0..count], 0..) |*point, index| {

        const turn = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(count)) * std.math.tau;

        point.* = .{ x + @sin(turn) * rx, y - @cos(turn) * ry };

    }

    return .{

        .points = out[0..count],
        .half = half,

    };

}

/// Chords for `turns` of a circle of `radius`.
fn steps(radius: f32, turns: f32) usize {

    const whole = std.math.clamp(@ceil(std.math.pi * @sqrt(10 * @max(radius, 0))), 12, 360);

    return @intFromFloat(@max(@ceil(whole * @min(turns, 1)), 1));

}

/// How much of pixel (`x`, `y`) lies inside a `width` by `height` rectangle with corners of `radius`.
pub fn inside(x: usize, y: usize, width: usize, height: usize, radius: i32) f32 {

    const r: f32 = @floatFromInt(@max(@min(radius, @as(i32, @intCast(@min(width, height) / 2))), 0));
    const fx = @as(f32, @floatFromInt(x)) + 0.5;
    const fy = @as(f32, @floatFromInt(y)) + 0.5;
    const dx = fx - std.math.clamp(fx, r, @as(f32, @floatFromInt(width)) - r);
    const dy = fy - std.math.clamp(fy, r, @as(f32, @floatFromInt(height)) - r);

    if (dx == 0 and dy == 0) return 1;

    return std.math.clamp(r - @sqrt(dx * dx + dy * dy) + 0.5, 0, 1);

}

/// `color`, 0xTTRRGGBB, made `alpha` opaque and premultiplied as 0xAARRGGBB.
pub fn premultiply(color: u32, alpha: f32) u32 {

    const a = canvas.opacity(color) * alpha;
    var result: u32 = @as(u32, @intFromFloat(a * 255 + 0.5)) << 24;

    for ([_]u5{ 0, 8, 16 }) |shift| result |= @as(u32, @intFromFloat(@as(f32, @floatFromInt(color >> shift & 0xff)) * a + 0.5)) << shift;

    return result;

}

/// Premultiplied `pixel` with `color`, 0xTTRRGGBB, laid over it `alpha` opaque.
fn over(pixel: u32, color: u32, alpha: f32) u32 {

    if (alpha >= 1) return (color & 0xffffff) | 0xff000000;

    const keep = 1 - alpha;
    var result: u32 = 0;

    for ([_]u5{ 0, 8, 16 }) |shift| {

        const under: f32 = @floatFromInt(pixel >> shift & 0xff);
        const top: f32 = @floatFromInt(color >> shift & 0xff);

        result |= @as(u32, @intFromFloat(@min(top * alpha + under * keep + 0.5, 255))) << shift;

    }

    const coverage: f32 = @floatFromInt(pixel >> 24);

    return result | @as(u32, @intFromFloat(@min(255 * alpha + coverage * keep + 0.5, 255))) << 24;

}

// Each shape gives the signed distance from a pixel centre to its edge, negative inside, and the box it may touch.

const Disc = extern struct {

    x: f32,
    y: f32,
    radius: f32,

    fn distance(self: Disc, px: f32, py: f32) f32 {

        return std.math.hypot(px - self.x, py - self.y) - self.radius;

    }

    fn box(self: Disc) [4]f32 {

        return .{ self.x - self.radius, self.y - self.radius, self.x + self.radius, self.y + self.radius };

    }

};

const Ring = extern struct {

    x: f32,
    y: f32,
    radius: f32,
    half: f32,

    fn distance(self: Ring, px: f32, py: f32) f32 {

        return @abs(std.math.hypot(px - self.x, py - self.y) - self.radius) - self.half;

    }

    fn box(self: Ring) [4]f32 {

        const reach = self.radius + self.half;

        return .{ self.x - reach, self.y - reach, self.x + reach, self.y + reach };

    }

};

const Capsule = extern struct {

    x: f32,
    y: f32,
    dx: f32,
    dy: f32,
    half: f32,

    fn distance(self: Capsule, px: f32, py: f32) f32 {

        return segment(px, py, self.x, self.y, self.dx, self.dy) - self.half;

    }

    fn box(self: Capsule) [4]f32 {

        return .{ @min(self.x, self.x + self.dx) - self.half, @min(self.y, self.y + self.dy) - self.half, @max(self.x, self.x + self.dx) + self.half, @max(self.y, self.y + self.dy) + self.half };

    }

};

const Arc = extern struct {

    x: f32,
    y: f32,
    radius: f32,
    half: f32,
    start: f32,
    end: f32,

    fn distance(self: Arc, px: f32, py: f32) f32 {

        // Turns clockwise from twelve o'clock, as a clock face reads them.
        const turn = @mod(std.math.atan2(px - self.x, self.y - py) / std.math.tau, 1);
        const along = @mod(turn - self.start, 1);

        if (along <= self.end - self.start) return @abs(std.math.hypot(px - self.x, py - self.y) - self.radius) - self.half;

        // Past either end, the nearer round cap.
        return @min(self.cap(self.start, px, py), self.cap(self.end, px, py));

    }

    fn cap(self: Arc, turn: f32, px: f32, py: f32) f32 {

        const angle = turn * std.math.tau;

        return std.math.hypot(px - self.x - @sin(angle) * self.radius, py - self.y + @cos(angle) * self.radius) - self.half;

    }

    fn box(self: Arc) [4]f32 {

        const reach = self.radius + self.half;

        return .{ self.x - reach, self.y - reach, self.x + reach, self.y + reach };

    }

};

const Ellipse = extern struct {

    x: f32,
    y: f32,
    rx: f32,
    ry: f32,
    half: f32,

    fn distance(self: Ellipse, px: f32, py: f32) f32 {

        // The implicit form divided by its gradient is close to the true distance near the curve, which is all coverage needs.
        const nx = (px - self.x) / @max(self.rx, 0.5);
        const ny = (py - self.y) / @max(self.ry, 0.5);
        const gradient = 2 * std.math.hypot(nx / @max(self.rx, 0.5), ny / @max(self.ry, 0.5));
        const value = (nx * nx + ny * ny - 1) / @max(gradient, 1e-6);

        return if (self.half == 0) value else @abs(value) - self.half;

    }

    fn box(self: Ellipse) [4]f32 {

        return .{ self.x - self.rx - self.half, self.y - self.ry - self.half, self.x + self.rx + self.half, self.y + self.ry + self.half };

    }

};

const Box = extern struct {

    x: f32,
    y: f32,
    rx: f32,
    ry: f32,
    radius: f32,
    half: f32,

    fn distance(self: Box, px: f32, py: f32) f32 {

        const qx = @abs(px - self.x) - self.rx + self.radius;
        const qy = @abs(py - self.y) - self.ry + self.radius;
        const value = std.math.hypot(@max(qx, 0), @max(qy, 0)) + @min(@max(qx, qy), 0) - self.radius;

        return if (self.half == 0) value else @abs(value) - self.half;

    }

    fn box(self: Box) [4]f32 {

        return .{ self.x - self.rx - self.half, self.y - self.ry - self.half, self.x + self.rx + self.half, self.y + self.ry + self.half };

    }

};

/// A line through many points, such as a graph, `half` either side.
pub const Polyline = struct {

    points: Points,
    half: f32,

    /// Where the points land, moved this far.
    shift: [2]f32 = .{ 0, 0 },

    pub fn distance(self: Polyline, x: f32, y: f32) f32 {

        const px = x - self.shift[0];
        const py = y - self.shift[1];
        var nearest: f32 = std.math.inf(f32);

        for (self.points[0 .. self.points.len - 1], self.points[1..]) |a, b| {

            // Segments whose box the pixel is far from cannot be nearer.
            if (px < @min(a[0], b[0]) - self.half - 1 or px > @max(a[0], b[0]) + self.half + 1) continue;
            if (py < @min(a[1], b[1]) - self.half - 1 or py > @max(a[1], b[1]) + self.half + 1) continue;

            nearest = @min(nearest, segment(px, py, a[0], a[1], b[0] - a[0], b[1] - a[1]));

        }

        return nearest - self.half;

    }

    pub fn box(self: Polyline) [4]f32 {

        var result = [4]f32{ std.math.inf(f32), std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };

        for (self.points) |point| result = .{ @min(result[0], point[0]), @min(result[1], point[1]), @max(result[2], point[0]), @max(result[3], point[1]) };

        return .{ result[0] - self.half + self.shift[0], result[1] - self.half + self.shift[1], result[2] + self.half + self.shift[0], result[3] + self.half + self.shift[1] };

    }

};

/// How far (`px`, `py`) is from the segment starting at (`x`, `y`) and running (`dx`, `dy`).
fn segment(px: f32, py: f32, x: f32, y: f32, dx: f32, dy: f32) f32 {

    const length = dx * dx + dy * dy;
    const t = if (length == 0) 0 else std.math.clamp(((px - x) * dx + (py - y) * dy) / length, 0, 1);

    return std.math.hypot(px - x - dx * t, py - y - dy * t);

}

/// A picture the app paints with a `Sketch`, recorded afresh each time its window repaints, so the display draws it on its GPU.
pub const Figure = struct {

    /// Paints the figure over its area, whose size the sketch gives.
    paint: *const fn (*Figure, *Sketch) void,

    /// Kept so apps can say a figure changed; recording already repaints it whenever its window does.
    pub fn invalidate(_: *Figure) void {

    }

    /// Records the figure over `area`.
    pub fn record(self: *Figure, area: Rect, target: *draw.List) void {

        if (area.width <= 0 or area.height <= 0) return;

        var sketch = Sketch{

            .width = @intCast(area.width),
            .height = @intCast(area.height),
            .list = target,
            .origin = .{

                .x = area.x,
                .y = area.y,

            },

        };

        self.paint(self, &sketch);

    }

    /// The custom node callback behind `gui.figure`, which keeps the figure in the node's data.
    pub fn recorder(owner: *node.Node, target: *draw.List) void {

        const self: *Figure = @ptrFromInt(owner.data);

        self.record(owner.inner(), target);

    }

};
