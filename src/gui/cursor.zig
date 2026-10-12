//! Pointer looks and their images in one style, white inside a black outline, which the display shows above everything.

const canvas = @import("canvas.zig");
const image = @import("image.zig");

const api = @import("api");

const Point = canvas.Point;

/// What the pointer looks like: the display picks it over window frames, and each client over its surfaces' content.
pub const Cursor = enum(u8) {

    arrow,

    /// Over something that does what it shows when clicked, such as a button.
    hand,

    /// Over text that can be typed or selected.
    text,

    crosshair,

    /// Over something that can be dragged, and while dragging it.
    grab,
    grabbing,

    /// An app was launched and has not shown a window yet.
    busy,

    /// Resizing sideways, up and down, along the top-left to bottom-right diagonal, and along the other.
    horizontal,
    vertical,
    falling,
    rising,

    _,

};

/// Shows the pointer busy, after launching an app, until its window appears.
pub fn busy() void {

    image.display.cursor(api.display.Spec.none, @intFromEnum(Cursor.busy)) catch {

    };

}

/// A pointer image: premultiplied 0xAARRGGBB pixels row after row, and the pixel that points.
pub const Sprite = struct {

    width: u32,
    height: u32,
    hotspot: Point,
    pixels: []const u32,

};

/// The image `look` shows; an unknown look shows the arrow.
pub fn sprite(look: Cursor) *const Sprite {

    return switch (look) {

        .hand => &hand,
        .text => &beam,
        .crosshair => &crosshair,
        .grab => &grab,
        .grabbing => &grabbing,
        .busy => &waiting,
        .horizontal => &horizontal,
        .vertical => &vertical,
        .falling => &falling,
        .rising => &rising,
        else => &arrow,

    };

}

const arrow_rows = [_][]const u8{

    "X...........",
    "XX..........",
    "XOX.........",
    "XOOX........",
    "XOOOX.......",
    "XOOOOX......",
    "XOOOOOX.....",
    "XOOOOOOX....",
    "XOOOOOOOX...",
    "XOOOOOOOOX..",
    "XOOOOOOOOOX.",
    "XOOOOOOXXXXX",
    "XOOOXOOX....",
    "XOOX.XOOX...",
    "XOX..XOOX...",
    "XX....XOOX..",
    "X.....XOOX..",
    ".......XX...",

};

const hourglass_rows = [_][]const u8{

    "XXXXXXXXX",
    "XOOOOOOOX",
    "XXOOOOOXX",
    ".XOOOOOX.",
    "..XOOOX..",
    "...XOX...",
    "...XOX...",
    "..XOOOX..",
    ".XOOOOOX.",
    "XXOOOOOXX",
    "XOOOOOOOX",
    "XXXXXXXXX",

};

const hand_rows = [_][]const u8{

    "....XX..........",
    "...XOOX.........",
    "...XOOX.........",
    "...XOOX.........",
    "...XOOX.........",
    "...XOOXXX.......",
    "...XOOXOOXXX....",
    "...XOOXOOXOOXX..",
    "XX.XOOXOOXOOXOX.",
    "XOXXOOOOOOOOXOOX",
    "XOOXOOOOOOOOOOOX",
    ".XOXOOOOOOOOOOOX",
    "..XOOOOOOOOOOOOX",
    "..XOOOOOOOOOOOX.",
    "...XOOOOOOOOOOX.",
    "...XOOOOOOOOOX..",
    "....XOOOOOOOOX..",
    "....XOOOOOOOOX..",
    "....XXXXXXXXXX..",

};

const beam_rows = [_][]const u8{

    "XXX.XXX",
    "XOOXOOX",
    "XXXOXXX",
    "..XOX..",
    "..XOX..",
    "..XOX..",
    "..XOX..",
    "..XOX..",
    "..XOX..",
    "..XOX..",
    "..XOX..",
    "..XOX..",
    "..XOX..",
    "..XOX..",
    "..XOX..",
    "XXXOXXX",
    "XOOXOOX",
    "XXX.XXX",

};

const crosshair_rows = [_][]const u8{

    "......XXX......",
    "......XOX......",
    "......XOX......",
    "......XOX......",
    "......XOX......",
    "......XOX......",
    "XXXXXXXOXXXXXXX",
    "XOOOOOOOOOOOOOX",
    "XXXXXXXOXXXXXXX",
    "......XOX......",
    "......XOX......",
    "......XOX......",
    "......XOX......",
    "......XOX......",
    "......XXX......",

};

const grab_rows = [_][]const u8{

    "........XX.......",
    ".....XXXOOXXX....",
    "....XOOXOOXOOXXX.",
    "....XOOXOOXOOXOOX",
    "....XOOXOOXOOXOOX",
    "....XOOXOOXOOXOOX",
    ".XX.XOOXOOXOOXOOX",
    "XOOXXOOOOOOOOOOOX",
    "XOOOXOOOOOOOOOOOX",
    ".XOOOOOOOOOOOOOOX",
    "..XOOOOOOOOOOOOOX",
    "...XOOOOOOOOOOOX.",
    "....XOOOOOOOOOOX.",
    ".....XOOOOOOOOX..",
    ".....XOOOOOOOOX..",
    ".....XXXXXXXXXX..",

};

const grabbing_rows = [_][]const u8{

    ".....XX.XX.XX....",
    "....XOOXOOXOOXXX.",
    "....XOOXOOXOOXOOX",
    "..XXXOOOOOOOOOOOX",
    ".XOOXOOOOOOOOOOOX",
    ".XOOOOOOOOOOOOOOX",
    "..XOOOOOOOOOOOOOX",
    "...XOOOOOOOOOOOX.",
    "....XOOOOOOOOOOX.",
    ".....XOOOOOOOOX..",
    ".....XOOOOOOOOX..",
    ".....XXXXXXXXXX..",

};

/// A double arrow on its side; turned across the diagonal, it stands upright.
const sideways_rows = [_][]const u8{

    "....XX.........XX....",
    "...XOX.........XOX...",
    "..XOOXXXXXXXXXXXOOX..",
    ".XOOOOOOOOOOOOOOOOOX.",
    "XOOOOOOOOOOOOOOOOOOOX",
    ".XOOOOOOOOOOOOOOOOOX.",
    "..XOOXXXXXXXXXXXOOX..",
    "...XOX.........XOX...",
    "....XX.........XX....",

};

/// A double arrow from top left to bottom right; mirrored, it runs the other way.
const diagonal_rows = [_][]const u8{

    "XXXXXXX........",
    "XOOOOX.........",
    "XOOOX..........",
    "XOOOOX.........",
    "XOXOOOX........",
    "XX.XOOOX.......",
    "X...XOOOX......",
    ".....XOOOX.....",
    "......XOOOX...X",
    ".......XOOOX.XX",
    "........XOOOXOX",
    ".........XOOOOX",
    "..........XOOOX",
    ".........XOOOOX",
    "........XXXXXXX",

};

const arrow = paint(&.{.{ .rows = &arrow_rows }}, .{});
const waiting = paint(&.{ .{ .rows = &arrow_rows }, .{ .rows = &hourglass_rows, .x = 13, .y = 6 } }, .{});
const hand = paint(&.{.{ .rows = &hand_rows }}, .{ .x = 4 });
const beam = paint(&.{.{ .rows = &beam_rows }}, .{ .x = 3, .y = 9 });
const crosshair = paint(&.{.{ .rows = &crosshair_rows }}, .{ .x = 7, .y = 7 });
const grab = paint(&.{.{ .rows = &grab_rows }}, .{ .x = 8, .y = 8 });
const grabbing = paint(&.{.{ .rows = &grabbing_rows }}, .{ .x = 8, .y = 6 });
const horizontal = paint(&.{.{ .rows = &sideways_rows }}, .{ .x = 10, .y = 4 });
const vertical = paint(&.{.{ .rows = &sideways_rows, .turn = .transpose }}, .{ .x = 4, .y = 10 });
const falling = paint(&.{.{ .rows = &diagonal_rows }}, .{ .x = 7, .y = 7 });
const rising = paint(&.{.{ .rows = &diagonal_rows, .turn = .mirror }}, .{ .x = 7, .y = 7 });

/// Rows of '.' clear, 'X' black, and 'O' white, laid at (`x`, `y`) of the sprite, turned as `turn` says.
const Layer = struct {

    rows: []const []const u8,
    x: usize = 0,
    y: usize = 0,
    turn: enum {

        none,
        transpose,
        mirror,

    } = .none,

    fn width(self: Layer) usize {

        return if (self.turn == .transpose) self.rows.len else self.rows[0].len;

    }

    fn height(self: Layer) usize {

        return if (self.turn == .transpose) self.rows[0].len else self.rows.len;

    }

    /// The character at (`x`, `y`) once turned.
    fn at(self: Layer, x: usize, y: usize) u8 {

        return switch (self.turn) {

            .none => self.rows[y][x],
            .transpose => self.rows[x][y],
            .mirror => self.rows[y][self.rows[0].len - 1 - x],

        };

    }

};

/// Lays `layers` in order, each over the last wherever it is not clear, at build time.
fn paint(comptime layers: []const Layer, comptime hotspot: Point) Sprite {

    const size = comptime extent(layers);
    const pixels = comptime fill(layers, size);

    return .{

        .width = size[0],
        .height = size[1],
        .hotspot = hotspot,
        .pixels = &pixels,

    };

}

fn extent(comptime layers: []const Layer) [2]u32 {

    var size = [2]u32{ 0, 0 };

    for (layers) |layer| {

        for (layer.rows) |row| if (row.len != layer.rows[0].len) @compileError("Cursor rows differ in length");

        size[0] = @max(size[0], layer.x + layer.width());
        size[1] = @max(size[1], layer.y + layer.height());

    }

    return size;

}

fn fill(comptime layers: []const Layer, comptime size: [2]u32) [size[0] * size[1]]u32 {

    @setEvalBranchQuota(100_000);

    var pixels = [_]u32{0} ** (size[0] * size[1]);

    for (layers) |layer| {

        for (0..layer.height()) |y| {

            for (0..layer.width()) |x| {

                pixels[(layer.y + y) * size[0] + layer.x + x] = switch (layer.at(x, y)) {

                    '.' => continue,
                    'X' => 0xff000000,
                    'O' => 0xffffffff,
                    else => @compileError("Cursor rows hold only '.', 'X', and 'O'"),

                };

            }

        }

    }

    return pixels;

}
