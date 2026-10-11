//! Anti-aliased shapes the display's quads cannot draw, such as lines at any angle, rings, arcs, and ellipses, painted on the CPU into an image.

const std = @import("std");

const canvas = @import("canvas.zig");
const draw = @import("draw.zig");
const image = @import("image.zig");
const node = @import("node.zig");

const Rect = canvas.Rect;

/// Paints into premultiplied 0xAARRGGBB `pixels`, `width` by `height`, in pixel coordinates whose centres sit at halves.
/// Colours are 0xTTRRGGBB as everywhere else, so plain 0xRRGGBB is opaque and `canvas.shade` makes it translucent.
pub const Sketch = struct {

    pixels: []u32,
    width: usize,
    height: usize,

    /// Fills every pixel with `color`, or makes them all transparent with `clear(transparent)`.
    pub fn clear(self: *Sketch, color: u32) void {

        @memset(self.pixels[0 .. self.width * self.height], premultiply(color, 1));

    }

    pub fn disc(self: *Sketch, x: f32, y: f32, radius: f32, color: u32) void {

        self.cover(.{ x - radius, y - radius, x + radius, y + radius }, color, Disc{

            .x = x,
            .y = y,
            .radius = radius,

        });

    }

    /// A circle's outline `width` pixels thick, centred on `radius`.
    pub fn ring(self: *Sketch, x: f32, y: f32, radius: f32, width: f32, color: u32) void {

        const reach = radius + width / 2;

        self.cover(.{ x - reach, y - reach, x + reach, y + reach }, color, Ring{

            .x = x,
            .y = y,
            .radius = radius,
            .half = width / 2,

        });

    }

    /// A line `width` pixels thick with round ends, such as a brush stroke or a clock hand.
    pub fn line(self: *Sketch, x0: f32, y0: f32, x1: f32, y1: f32, width: f32, color: u32) void {

        const half = width / 2;

        self.cover(.{ @min(x0, x1) - half, @min(y0, y1) - half, @max(x0, x1) + half, @max(y0, y1) + half }, color, Capsule{

            .x = x0,
            .y = y0,
            .dx = x1 - x0,
            .dy = y1 - y0,
            .half = half,

        });

    }

    /// Part of a ring with round ends, from turn `start` to turn `end` clockwise from twelve o'clock, such as a countdown's progress.
    pub fn arc(self: *Sketch, x: f32, y: f32, radius: f32, width: f32, start: f32, end: f32, color: u32) void {

        if (end - start >= 1) return self.ring(x, y, radius, width, color);
        if (end <= start) return;

        const reach = radius + width / 2;

        self.cover(.{ x - reach, y - reach, x + reach, y + reach }, color, Arc{

            .x = x,
            .y = y,
            .radius = radius,
            .half = width / 2,
            .start = start,
            .end = end,

        });

    }

    /// An ellipse inside `box` (left, top, right, bottom), filled when `width` is 0, else outlined `width` pixels thick.
    pub fn ellipse(self: *Sketch, box: [4]f32, width: f32, color: u32) void {

        const half = width / 2;

        self.cover(.{ box[0] - half, box[1] - half, box[2] + half, box[3] + half }, color, Ellipse{

            .x = (box[0] + box[2]) / 2,
            .y = (box[1] + box[3]) / 2,
            .rx = @max(@abs(box[2] - box[0]) / 2, 0.5),
            .ry = @max(@abs(box[3] - box[1]) / 2, 0.5),
            .half = half,

        });

    }

    /// A rectangle inside `box` (left, top, right, bottom) with corners of `radius`, filled when `width` is 0, else outlined `width` pixels thick.
    pub fn rectangle(self: *Sketch, box: [4]f32, radius: f32, width: f32, color: u32) void {

        const half = width / 2;
        const left = @min(box[0], box[2]);
        const top = @min(box[1], box[3]);
        const right = @max(box[0], box[2]);
        const bottom = @max(box[1], box[3]);

        self.cover(.{ left - half, top - half, right + half, bottom + half }, color, Box{

            .x = (left + right) / 2,
            .y = (top + bottom) / 2,
            .rx = (right - left) / 2,
            .ry = (bottom - top) / 2,
            .radius = @min(radius, @min(right - left, bottom - top) / 2),
            .half = half,

        });

    }

    /// Blends `color` over every pixel `box` (left, top, right, bottom) touches, as far as `shape` covers it.
    fn cover(self: *Sketch, box: [4]f32, color: u32, shape: anytype) void {

        const left: usize = @intFromFloat(std.math.clamp(@floor(box[0] - 1), 0, @as(f32, @floatFromInt(self.width))));
        const top: usize = @intFromFloat(std.math.clamp(@floor(box[1] - 1), 0, @as(f32, @floatFromInt(self.height))));
        const right: usize = @intFromFloat(std.math.clamp(@ceil(box[2] + 1), 0, @as(f32, @floatFromInt(self.width))));
        const bottom: usize = @intFromFloat(std.math.clamp(@ceil(box[3] + 1), 0, @as(f32, @floatFromInt(self.height))));
        const alpha = canvas.opacity(color);

        for (top..bottom) |y| {

            const row = self.pixels[y * self.width ..];
            const fy = @as(f32, @floatFromInt(y)) + 0.5;

            for (left..right) |x| {

                const coverage = std.math.clamp(0.5 - shape.distance(@as(f32, @floatFromInt(x)) + 0.5, fy), 0, 1);

                if (coverage > 0) row[x] = over(row[x], color, coverage * alpha);

            }

        }

    }

};

pub const transparent = canvas.shade(0, 0);

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

// Each shape gives the signed distance from a pixel centre to its edge, negative inside.

const Disc = struct {

    x: f32,
    y: f32,
    radius: f32,

    fn distance(self: Disc, px: f32, py: f32) f32 {

        return std.math.hypot(px - self.x, py - self.y) - self.radius;

    }

};

const Ring = struct {

    x: f32,
    y: f32,
    radius: f32,
    half: f32,

    fn distance(self: Ring, px: f32, py: f32) f32 {

        return @abs(std.math.hypot(px - self.x, py - self.y) - self.radius) - self.half;

    }

};

const Capsule = struct {

    x: f32,
    y: f32,
    dx: f32,
    dy: f32,
    half: f32,

    fn distance(self: Capsule, px: f32, py: f32) f32 {

        const length = self.dx * self.dx + self.dy * self.dy;
        const t = if (length == 0) 0 else std.math.clamp(((px - self.x) * self.dx + (py - self.y) * self.dy) / length, 0, 1);

        return std.math.hypot(px - self.x - self.dx * t, py - self.y - self.dy * t) - self.half;

    }

};

const Arc = struct {

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

};

const Ellipse = struct {

    x: f32,
    y: f32,
    rx: f32,
    ry: f32,
    half: f32,

    fn distance(self: Ellipse, px: f32, py: f32) f32 {

        // The implicit form divided by its gradient is close to the true distance near the curve, which is all coverage needs.
        const nx = (px - self.x) / self.rx;
        const ny = (py - self.y) / self.ry;
        const gradient = 2 * std.math.hypot(nx / self.rx, ny / self.ry);
        const value = (nx * nx + ny * ny - 1) / @max(gradient, 1e-6);

        return if (self.half == 0) value else @abs(value) - self.half;

    }

};

const Box = struct {

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

};

/// A picture the app paints with a `Sketch` and the display shows as an image; it is painted again only when its size changes or the app calls `invalidate`.
pub const Figure = struct {

    /// Paints the figure, whose pixels start transparent.
    paint: *const fn (*Figure, *Sketch) void,
    picture: ?image.Image = null,
    stale: bool = true,

    /// Schedules the figure to paint again, after changing what it shows; the window still needs to repaint it.
    pub fn invalidate(self: *Figure) void {

        self.stale = true;

    }

    /// Shows the figure over `area`, painting it first if it is stale or `area` changed size.
    pub fn record(self: *Figure, area: Rect, target: *draw.List) void {

        if (area.width <= 0 or area.height <= 0) return;

        const width: u32 = @intCast(area.width);
        const height: u32 = @intCast(area.height);

        if (self.picture) |*old| if (old.width != width or old.height != height) {

            old.deinit();
            self.picture = null;

        };

        if (self.picture == null) {

            self.picture = image.Image.init(width, height) catch return;
            self.stale = true;

        }

        const picture = &self.picture.?;

        if (self.stale) {

            var sketch = picture.sketch();

            sketch.clear(transparent);
            self.paint(self, &sketch);
            picture.publish() catch return;
            self.stale = false;

        }

        target.image(picture.handle, area);

    }

    /// The custom node callback behind `gui.figure`, which keeps the figure in the node's data.
    pub fn recorder(owner: *node.Node, target: *draw.List) void {

        const self: *Figure = @ptrFromInt(owner.data);

        self.record(owner.inner(), target);

    }

};
