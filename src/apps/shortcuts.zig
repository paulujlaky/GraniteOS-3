//! Desktop items: apps, folders, and files pinned over the wallpaper in grid cells, which a click or a swept area selects, a
//! drag moves together, a double-click opens, and a right-click offers to open or take off.

const std = @import("std");

const catalog = @import("catalog.zig");
const desktop = @import("desktop.zig");
const dock = @import("dock.zig");
const pins = @import("pins.zig");

const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;

/// Each item's cell, and how far the grid keeps from the screen's edges and the top bar.
const wide = 88;
const tall = 84;
const inset = 8;
const top = desktop.height + inset;

pub const Cell = struct {

    column: u8 = 0,
    row: u8 = 0,

};

/// Draws the items and the area being swept over the wallpaper, and takes the pointer there.
pub var node = gui.custom(&paint, .{});

/// A press on the wallpaper, on an item or between them, which becomes a drag of the selection or a sweep.
var press: ?struct { drag: gui.Drag, item: ?usize } = null;

pub var menu: gui.Menu(&.{

    .{ .icon = .folder_open, .title = "Open", .hint = "Enter", .run = open_selected },
    gui.menu.separator,
    .{ .icon = .close, .title = "Remove from desktop", .hint = "Del", .run = remove_selected },

}) = .{};

pub fn init() void {

    node.track = &follow;
    node.open = &launch;
    node.menu = &offer;
    node.cursor = .arrow;
    menu.init(null);

}

/// Repaints after the items change.
pub fn redraw() void {

    desktop.wallpaper.refresh();

}

/// Opens or takes off the selected items for Enter and Delete, and drops the selection on Escape; true when the key was theirs.
pub fn react(event: api.Event) bool {

    switch (event.key()) {

        .enter => open_selected(),
        .delete => remove_selected(),
        .escape => {

            // Escape goes on to close the desktop's pop-ups too.
            choose(null);
            return false;

        },
        else => return false,

    }

    return true;

}

/// The first free cell from `from` on, down each column then across, wrapping round; null when every cell is taken.
pub fn vacant(from: Cell) ?Cell {

    const fits = grid();
    const total = @as(usize, fits.column) * fits.row;
    const start = @as(usize, @min(from.column, fits.column - 1)) * fits.row + @min(from.row, fits.row - 1);

    for (0..total) |step| {

        const index = (start + step) % total;

        const candidate = Cell{

            .column = @intCast(index / fits.row),
            .row = @intCast(index % fits.row),

        };

        if (!taken(candidate)) return candidate;

    }

    return null;

}

/// How many columns and rows of cells fit on the screen, clear of the bar and the dock.
fn grid() Cell {

    const screen = desktop.wallpaper.surface.list.bounds();

    return .{

        .column = @intCast(std.math.clamp(@divTrunc(screen.width - 2 * inset, wide), 1, 255)),
        .row = @intCast(std.math.clamp(@divTrunc(screen.height - top - dock.reach, tall), 1, 255)),

    };

}

fn taken(cell: Cell) bool {

    for (pins.items[0..pins.count]) |*item| {

        if (item.column == cell.column and item.row == cell.row) return true;

    }

    return false;

}

/// Where `cell` lies on the screen, kept on it when the screen has shrunk since.
fn spot(cell: Cell) gui.Rect {

    const fits = grid();

    return .{

        .x = inset + @as(i32, @min(cell.column, fits.column - 1)) * wide,
        .y = top + @as(i32, @min(cell.row, fits.row - 1)) * tall,
        .width = wide,
        .height = tall,

    };

}

/// Where item `index` shows, carried along by a drag under way.
fn area(index: usize) gui.Rect {

    const item = &pins.items[index];

    const at = spot(.{

        .column = item.column,
        .row = item.row,

    }).inset(4);

    const held = press orelse return at;

    return if (item.selected and held.item != null and held.drag.moved) gui.draw.move(at, held.drag.offset()) else at;

}

/// The item at `point`, topmost first.
fn hit(point: gui.Point) ?usize {

    var index = pins.count;

    while (index > 0) {

        index -= 1;
        if (area(index).contains(point)) return index;

    }

    return null;

}

/// The area swept out so far, once a press between the items has moved far enough.
fn swept() ?gui.Rect {

    const held = press orelse return null;

    return if (held.item == null and held.drag.moved) gui.Rect.spanning(held.drag.start, held.drag.at) else null;

}

/// What can change as the pointer moves: the swept area and the selected items where they show.
fn extent() gui.Rect {

    var result = swept() orelse gui.Rect{};

    for (pins.items[0..pins.count], 0..) |*item, index| {

        if (item.selected) result = result.join(area(index));

    }

    return result;

}

/// Selects item `index` alone, or nothing.
fn choose(index: ?usize) void {

    for (pins.items[0..pins.count], 0..) |*item, other| {

        if (item.selected == (other == index)) continue;

        item.selected = other == index;
        touch(area(other));

    }

}

fn touch(changed: gui.Rect) void {

    if (changed.width > 0) desktop.wallpaper.damage = desktop.wallpaper.damage.join(changed.inset(-2));

}

/// Follows a press on the wallpaper: dragging the selection when it began on an item, else sweeping out an area to select.
fn follow(_: *gui.Node, track: gui.Track) void {

    const before = extent();

    switch (track.phase) {

        .down => {

            const found = hit(track.at);

            desktop.dismiss();

            // A press on a selected item keeps the others selected, to drag them all.
            if (found == null or !pins.items[found.?].selected) choose(found);

            press = .{

                .drag = .init(track.at),
                .item = found,

            };

        },
        .move => if (press) |*held| {

            if (!held.drag.follow(track.at)) return;

            if (held.item != null) {

                node.cursor = .grabbing;

            } else if (swept()) |sweep| {

                for (pins.items[0..pins.count], 0..) |*item, index| {

                    const inside = area(index).intersect(sweep) != null;

                    if (item.selected != inside) touch(area(index));
                    item.selected = inside;

                }

            }

        },
        .up => {

            const held = press orelse return;
            const moved = held.drag.moved;

            node.cursor = .arrow;

            if (held.item) |index| {

                if (moved) return drop(held.drag.offset());

                // A click on one of several selected items selects it alone.
                choose(index);

            }

            press = null;

        },

    }

    touch(before);
    touch(extent());

}

/// Moves the selected items by `offset`, each to the nearest cell, or the next free one along when that is taken.
fn drop(offset: gui.Point) void {

    const fits = grid();
    var wanted: [pins.most]Cell = undefined;

    // Every selected item lifts before any lands, so they can trade cells among themselves.
    for (pins.items[0..pins.count], 0..) |*item, index| {

        if (!item.selected) continue;

        const at = gui.draw.move(spot(.{

            .column = item.column,
            .row = item.row,

        }), offset);

        wanted[index] = .{

            .column = @intCast(std.math.clamp(@divFloor(at.x - inset + wide / 2, wide), 0, fits.column - 1)),
            .row = @intCast(std.math.clamp(@divFloor(at.y - top + tall / 2, tall), 0, fits.row - 1)),

        };

        item.column = std.math.maxInt(u8);
        item.row = std.math.maxInt(u8);

    }

    press = null;

    for (pins.items[0..pins.count], 0..) |*item, index| {

        if (!item.selected) continue;

        const cell = vacant(wanted[index]) orelse wanted[index];

        item.column = cell.column;
        item.row = cell.row;

    }

    pins.save();
    redraw();

}

fn paint(_: *gui.Node, target: *gui.List) void {

    for (pins.items[0..pins.count], 0..) |*item, index| {

        const box = area(index);
        const name = catalog.named(item.target());
        var bytes: [64]u8 = undefined;

        const symbol = gui.Rect{

            .x = box.x,
            .y = box.y + 8,
            .width = box.width,
            .height = 40,

        };

        const words = gui.Rect{

            .x = box.x + 4,
            .y = box.y + 50,
            .width = box.width - 8,
            .height = 20,

        };

        const shown = gui.draw.shorten(name, .sans, theme.small, words.width, &bytes);

        if (item.selected) target.round(box, theme.radius, gui.shade(0xffffff, 36));

        // A shadow keeps both readable over light wallpapers.
        for ([_]u32{ gui.shade(0x000000, 160), theme.text }, [_]i32{ 1, 0 }) |color, drop_by| {

            target.icon(catalog.badge(item.target()), 30, gui.draw.move(symbol, .{ .y = drop_by }), color);
            target.label(shown, .sans, theme.small, gui.draw.move(words, .{ .y = drop_by }), color, .center);

        }

    }

    target.sweep(swept() orelse return);

}

/// Opens the item double-clicked.
fn launch(_: *gui.Node) void {

    const held = press orelse return;

    open(held.item orelse return);

}

fn open(index: usize) void {

    desktop.dismiss();

    catalog.open(pins.items[index].target(), desktop.home) catch {

    };

}

fn open_selected() void {

    for (pins.items[0..pins.count], 0..) |*item, index| {

        if (item.selected) open(index);

    }

}

fn remove_selected() void {

    pins.prune(null);

}

/// Offers the selected items' menu over an item, else the wallpaper's own.
fn offer(_: *gui.Node, at: gui.Point) void {

    const found = hit(at);

    desktop.dismiss();

    if (found == null or !pins.items[found.?].selected) choose(found);
    if (found == null) return desktop.offer(at);

    menu.show(at);

}
