const std = @import("std");

const font = @import("font.zig");

pub const Point = struct {

    x: i32 = 0,
    y: i32 = 0,

};

pub const Rect = struct {

    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,

    pub fn right(self: Rect) i32 {

        return self.x + self.width;

    }

    pub fn bottom(self: Rect) i32 {

        return self.y + self.height;

    }

    pub fn contains(self: Rect, point: Point) bool {

        return point.x >= self.x and point.y >= self.y and point.x < self.right() and point.y < self.bottom();

    }

    pub fn intersect(self: Rect, other: Rect) ?Rect {

        const left = @max(self.x, other.x);
        const top = @max(self.y, other.y);
        const right_edge = @min(self.right(), other.right());
        const bottom_edge = @min(self.bottom(), other.bottom());

        if (left >= right_edge or top >= bottom_edge) return null;

        return .{

            .x = left,
            .y = top,
            .width = right_edge - left,
            .height = bottom_edge - top,

        };

    }

    /// The smallest rectangle covering both.
    pub fn join(self: Rect, other: Rect) Rect {

        if (self.width <= 0 or self.height <= 0) return other;
        if (other.width <= 0 or other.height <= 0) return self;

        const left = @min(self.x, other.x);
        const top = @min(self.y, other.y);

        return .{

            .x = left,
            .y = top,
            .width = @max(self.right(), other.right()) - left,
            .height = @max(self.bottom(), other.bottom()) - top,

        };

    }

    pub fn inset(self: Rect, amount: i32) Rect {

        return .{

            .x = self.x + amount,
            .y = self.y + amount,
            .width = self.width - 2 * amount,
            .height = self.height - 2 * amount,

        };

    }

    /// A `width` by `height` rectangle centered within this one.
    pub fn centered(self: Rect, width: i32, height: i32) Rect {

        return .{

            .x = self.x + @divTrunc(self.width - width, 2),
            .y = self.y + @divTrunc(self.height - height, 2),
            .width = width,
            .height = height,

        };

    }

};

pub const Alignment = enum {

    left,
    center,
    right,

};

const Bounds = struct {

    left: usize,
    top: usize,
    right: usize,
    bottom: usize,

};

/// `color` made `amount` (0 to 255) opaque; colours are 0xTTRRGGBB, where TT is transparency, so plain 0xRRGGBB is opaque.
pub fn shade(color: u32, amount: u8) u32 {

    return (@as(u32, 255 - amount) << 24) | (color & 0xffffff);

}

/// How opaque colour `color` is, from 0 to 1.
pub fn opacity(color: u32) f32 {

    return @as(f32, @floatFromInt(255 - (color >> 24))) / 255;

}

/// What lay under the bottom corners of an area before drawing in it; see `Canvas.save`.
pub const Corners = struct {

    /// The widest curve kept; larger radii round as this.
    pub const largest = 16;

    area: Rect = .{},
    radius: i32 = 0,
    limit: Rect = .{},
    pixels: [2][largest * largest]u32 = undefined,

    /// The bottom-left and bottom-right squares the curve cuts into.
    pub fn squares(self: *const Corners) [2]Rect {

        const r = @max(@min(self.radius, @divTrunc(@min(self.area.width, self.area.height), 2)), 0);

        return .{

            .{ .x = self.area.x, .y = self.area.bottom() - r, .width = r, .height = r },
            .{ .x = self.area.right() - r, .y = self.area.bottom() - r, .width = r, .height = r },

        };

    }

};

/// Pixels as 0x00RRGGBB, row after row.
pub const Canvas = struct {

    pixels: []u32,
    width: usize,
    height: usize,

    /// Drawing outside this, when set, is discarded.
    limit: ?Rect = null,

    pub fn bounds(self: *const Canvas) Rect {

        return .{

            .width = @intCast(self.width),
            .height = @intCast(self.height),

        };

    }

    pub fn fill(self: *Canvas, area: Rect, color: u32) void {

        self.round(area, 0, color);

    }

    /// Fills `area` with anti-aliased corners of `radius` pixels.
    pub fn round(self: *Canvas, area: Rect, radius: i32, color: u32) void {

        const limit = @max(@min(radius, @divTrunc(@min(area.width, area.height), 2)), 0);
        const clipped = self.clip(area) orelse return;
        const solid = color >> 24 == 0;
        const alpha = opacity(color);
        const r: f32 = @floatFromInt(limit);
        const left: f32 = @floatFromInt(area.x);
        const top: f32 = @floatFromInt(area.y);
        const right: f32 = @floatFromInt(area.right());
        const bottom: f32 = @floatFromInt(area.bottom());

        for (clipped.top..clipped.bottom) |y| {

            const row = self.pixels[y * self.width ..];
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            const dy = fy - std.math.clamp(fy, top + r, bottom - r);

            // Rows between the corners are solid.
            if (dy == 0 and solid) {

                @memset(row[clipped.left..clipped.right], color);
                continue;

            }

            for (clipped.left..clipped.right) |x| {

                const fx = @as(f32, @floatFromInt(x)) + 0.5;
                const dx = fx - std.math.clamp(fx, left + r, right - r);
                const inside = if (dx == 0 and dy == 0) 1 else r - @sqrt(dx * dx + dy * dy) + 0.5;

                blend(&row[x], color, @min(inside, 1) * alpha);

            }

        }

    }

    /// Saves the pixels in the bottom corners of `area` within `limit`, so `trim` can round off what is drawn there next.
    pub fn save(self: *const Canvas, kept: *Corners, area: Rect, radius: i32, limit: Rect) void {

        kept.* = .{

            .area = area,
            .radius = @min(radius, Corners.largest),
            .limit = limit.intersect(self.bounds()) orelse return,

        };

        for (kept.squares(), &kept.pixels) |square, *saved| {

            const visible = square.intersect(kept.limit) orelse continue;

            for (0..@intCast(visible.height)) |y| {

                const row = self.pixels[(@as(usize, @intCast(visible.y)) + y) * self.width + @as(usize, @intCast(visible.x)) ..];

                @memcpy(saved[y * Corners.largest ..][0..@intCast(visible.width)], row[0..@intCast(visible.width)]);

            }

        }

    }

    /// Blends the pixels `save` kept back over everything drawn outside the curve of its corners.
    pub fn trim(self: *Canvas, kept: *const Corners) void {

        const squares = kept.squares();
        const r: f32 = @floatFromInt(squares[0].width);
        const left: f32 = @floatFromInt(kept.area.x);
        const right: f32 = @floatFromInt(kept.area.right());
        const bottom: f32 = @floatFromInt(kept.area.bottom());

        for (squares, &kept.pixels) |square, *saved| {

            const visible = square.intersect(kept.limit) orelse continue;

            for (0..@intCast(visible.height)) |y| {

                for (0..@intCast(visible.width)) |x| {

                    const point = Point{

                        .x = visible.x + @as(i32, @intCast(x)),
                        .y = visible.y + @as(i32, @intCast(y)),

                    };
                    const fx = @as(f32, @floatFromInt(point.x)) + 0.5;
                    const dx = fx - std.math.clamp(fx, left + r, right - r);
                    const dy = @max(@as(f32, @floatFromInt(point.y)) + 0.5 - (bottom - r), 0);

                    blend(self.at(point), saved[y * Corners.largest + x], 1 - std.math.clamp(r - @sqrt(dx * dx + dy * dy) + 0.5, 0, 1));

                }

            }

        }

    }

    /// Draws UTF-8 `string` at `size` pixels with its baseline starting at (`x`, `baseline`).
    pub fn text(self: *Canvas, face: *const font.Font, string: []const u8, size: f32, x: i32, baseline: i32, color: u32) void {

        const scale = size / face.units;
        const visible = self.region() orelse return;
        const alpha = opacity(color);
        var pen: f32 = @floatFromInt(x);
        var previous: u16 = 0;
        var characters = font.decode(string);

        while (characters.next()) |char| {

            const glyph = face.lookup(char);

            pen += face.kerning(previous, glyph) * scale;
            previous = glyph;

            if (face.render(glyph, scale, pen - @floor(pen))) |bitmap| {

                const left = @as(i32, @intFromFloat(@floor(pen))) + bitmap.left;
                const top = baseline + bitmap.top;

                for (0..bitmap.height) |row| {

                    for (0..bitmap.width) |column| {

                        const point = Point{

                            .x = left + @as(i32, @intCast(column)),
                            .y = top + @as(i32, @intCast(row)),

                        };

                        if (visible.contains(point)) blend(self.at(point), color, bitmap.coverage[row * bitmap.width + column] * alpha);

                    }

                }

            }

            pen += face.advance(glyph) * scale;

        }

    }

    /// Draws `string` vertically centered in `area`.
    pub fn label(self: *Canvas, face: *const font.Font, string: []const u8, size: f32, area: Rect, color: u32, alignment: Alignment) void {

        const start = anchor(face, string, size, area, alignment);

        self.text(face, string, size, start.x, start.y, color);

    }

    /// Copies `source`, placed with its corner at `origin`, wherever it overlaps `area`.
    pub fn blit(self: *Canvas, source: *const Canvas, origin: Point, area: Rect) void {

        const placed = Rect{

            .x = origin.x,
            .y = origin.y,
            .width = @intCast(source.width),
            .height = @intCast(source.height),

        };

        const visible = area.intersect(placed) orelse return;
        const clipped = self.clip(visible) orelse return;
        const span = clipped.right - clipped.left;
        const column: usize = @intCast(@as(i64, @intCast(clipped.left)) - origin.x);

        for (clipped.top..clipped.bottom) |y| {

            const row: usize = @intCast(@as(i64, @intCast(y)) - origin.y);

            @memcpy(self.pixels[y * self.width + clipped.left ..][0..span], source.pixels[row * source.width + column ..][0..span]);

        }

    }

    /// Draws premultiplied 0xAARRGGBB `source` stretched over `area`, sampling the nearest pixel.
    pub fn image(self: *Canvas, source: *const Canvas, area: Rect) void {

        const clipped = self.clip(area) orelse return;
        if (source.width == 0 or source.height == 0) return;

        for (clipped.top..clipped.bottom) |y| {

            const row = @divTrunc((@as(i64, @intCast(y)) - area.y) * @as(i64, @intCast(source.height)), area.height);
            const line = source.pixels[@as(usize, @intCast(row)) * source.width ..][0..source.width];

            for (clipped.left..clipped.right) |x| {

                const column = @divTrunc((@as(i64, @intCast(x)) - area.x) * @as(i64, @intCast(source.width)), area.width);
                const pixel = line[@intCast(column)];
                const target = &self.pixels[y * self.width + x];
                const keep = 255 - (pixel >> 24);

                if (keep == 0) {

                    target.* = pixel & 0xffffff;
                    continue;

                }

                var result: u32 = 0;

                for ([_]u5{ 0, 8, 16 }) |shift| result |= @as(u32, @min((pixel >> shift & 0xff) + (target.* >> shift & 0xff) * keep / 255, 255)) << shift;

                target.* = result;

            }

        }

    }

    fn at(self: *Canvas, point: Point) *u32 {

        return &self.pixels[@as(usize, @intCast(point.y)) * self.width + @as(usize, @intCast(point.x))];

    }

    fn region(self: *const Canvas) ?Rect {

        const limit = self.limit orelse return self.bounds();

        return limit.intersect(self.bounds());

    }

    fn clip(self: *const Canvas, area: Rect) ?Bounds {

        const visible = area.intersect(self.region() orelse return null) orelse return null;

        return .{

            .left = @intCast(visible.x),
            .top = @intCast(visible.y),
            .right = @intCast(visible.right()),
            .bottom = @intCast(visible.bottom()),

        };

    }

};

/// Where a label's baseline starts so it sits vertically centred in `area`.
pub fn anchor(face: *const font.Font, string: []const u8, size: f32, area: Rect, alignment: Alignment) Point {

    const scale = size / face.units;
    const span: i32 = @intFromFloat(@ceil(face.measure(string, scale)));
    const height = @as(f32, @floatFromInt(face.capital)) * scale;

    // Capitals, or a whole icon, sit midway down the area.
    return .{

        .x = switch (alignment) {

            .left => area.x,
            .center => area.x + @divTrunc(area.width - span, 2),
            .right => area.right() - span,

        },
        .y = area.y + @as(i32, @intFromFloat(@round((@as(f32, @floatFromInt(area.height)) + height) / 2))),

    };

}

fn blend(pixel: *u32, color: u32, alpha: f32) void {

    if (alpha <= 0) return;
    if (alpha >= 1) {

        pixel.* = color;
        return;

    }

    var result: u32 = 0;

    for ([_]u5{ 0, 8, 16 }) |shift| {

        const under: f32 = @floatFromInt(pixel.* >> shift & 0xff);
        const over: f32 = @floatFromInt(color >> shift & 0xff);

        result |= @as(u32, @intFromFloat(under + (over - under) * alpha + 0.5)) << shift;

    }

    pixel.* = result;

}
