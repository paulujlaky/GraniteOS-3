//! What the session keeps pinned: apps on the dock in the order people put them, and apps, folders, and files on the desktop
//! in grid cells; kept in the `pins` config, which only the desktop writes.

const std = @import("std");

const catalog = @import("catalog.zig");
const desktop = @import("desktop.zig");
const dock = @import("dock.zig");
const notices = @import("notices.zig");
const shortcuts = @import("shortcuts.zig");

const api = @import("api");
const gui = @import("gui");

const protocol = api.protocol;
const Image = api.abi.Image;

/// A desktop item, with its own copy of its target.
pub const Item = struct {

    column: u8,
    row: u8,
    selected: bool = false,

    bytes: [longest]u8 = undefined,
    length: usize = 0,

    pub fn target(self: *const Item) []const u8 {

        return self.bytes[0..self.length];

    }

};

pub const most = 64;

/// The longest target an item keeps.
const longest = 256;

pub var items: [most]Item = undefined;
pub var count: usize = 0;

/// The dock's apps, left to right.
pub var docked: [catalog.apps.len]Image = undefined;
pub var docked_count: usize = 0;

var config = api.Config{};
var files = api.Files{};

/// The app the app menu is open for.
var chosen: Image = .explorer;

/// The right-click menu of an app on the dock or in the launcher.
pub var app_menu: gui.Menu(&.{

    .{ .icon = .app, .title = "Open", .run = open_chosen, .offered = idle },
    .{ .icon = .plus, .title = "New window", .run = open_chosen, .offered = running },
    gui.menu.separator,
    .{ .icon = .plus, .title = "Pin to dock", .run = dock_chosen, .offered = undocked },
    .{ .icon = .close, .title = "Unpin from dock", .run = dock_chosen, .offered = chosen_docked },
    .{ .icon = .monitor, .title = "Add to desktop", .run = place_chosen, .offered = unplaced },
    .{ .icon = .close, .title = "Remove from desktop", .run = place_chosen, .offered = chosen_placed },

}) = .{};

pub fn init() void {

    app_menu.init(null);

}

/// Reads the pins of user `owner`, or clears them for none; files and folders gone since are left off.
pub fn load(owner: []const u8) void {

    config.open(owner, catalog.pins);
    docked_count = 0;
    count = 0;

    if (owner.len != 0) {

        var names = std.mem.tokenizeScalar(u8, config.get("dock") orelse catalog.docked, ',');

        while (names.next()) |name| {

            const app = catalog.application(name) orelse continue;
            if (docks(app.image)) continue;

            docked[docked_count] = app.image;
            docked_count += 1;

        }

        var lines = config.all("item");

        while (lines.next()) |line| {

            const item = catalog.Item.parse(line) orelse continue;
            if (count == most or find(item.target) != null or !exists(item.target)) continue;

            add(item.target, item.column, item.row);

        }

    }

    changed();

}

pub fn docks(image: Image) bool {

    return std.mem.indexOfScalar(Image, docked[0..docked_count], image) != null;

}

/// Moves docked app `image` to `to` places from the left, as a drag along the dock does; `save` keeps it.
pub fn shift(image: Image, to: usize) void {

    const from = std.mem.indexOfScalar(Image, docked[0..docked_count], image) orelse return;
    if (from == to or to >= docked_count) return;

    std.mem.copyForwards(Image, docked[from .. docked_count - 1], docked[from + 1 .. docked_count]);
    std.mem.copyBackwards(Image, docked[to + 1 .. docked_count], docked[to .. docked_count - 1]);
    docked[to] = image;
    dock.arrange();

}

/// The desktop item showing `target`.
pub fn find(target: []const u8) ?usize {

    for (items[0..count], 0..) |*item, index| {

        if (std.mem.eql(u8, item.target(), target)) return index;

    }

    return null;

}

/// Puts `target` on the desktop in the first free cell; false when there is no room for it.
pub fn place(target: []const u8) bool {

    if (find(target) != null) return true;
    if (count == most or target.len > longest) return false;

    const cell = shortcuts.vacant(.{}) orelse return false;

    add(target, cell.column, cell.row);

    if (!write()) {

        count -= 1;
        save();

        return false;

    }

    changed();

    return true;

}

/// Takes `target` off the desktop, or every selected item for null.
pub fn prune(target: ?[]const u8) void {

    var kept: usize = 0;

    for (items[0..count]) |*item| {

        const gone = if (target) |name| std.mem.eql(u8, item.target(), name) else item.selected;
        if (gone) continue;

        items[kept] = item.*;
        kept += 1;

    }

    count = kept;
    save();
    changed();

}

/// Writes the pins back, as many as fit in the file.
pub fn save() void {

    _ = write();

}

/// Writes the pins back; false when they no longer fit in the file.
fn write() bool {

    var names: [catalog.apps.len * 16]u8 = undefined;
    var length: usize = 0;

    for (docked[0..docked_count], 0..) |image, index| {

        length += (std.fmt.bufPrint(names[length..], "{s}{s}", .{ if (index == 0) "" else ",", @tagName(image) }) catch return false).len;

    }

    if (!config.set("dock", names[0..length])) return false;

    config.erase("item");

    for (items[0..count]) |*item| {

        var line: [300]u8 = undefined;

        if (!config.add("item", std.fmt.bufPrint(&line, "{d},{d},{s}", .{ item.column, item.row, item.target() }) catch return false)) return false;

    }

    // An unwritable file keeps the pins until the session ends.
    config.save() catch {

    };

    return true;

}

/// Answers an app, such as Files, asking to put a path on the desktop or take it off.
pub fn serve(request: api.Request) u64 {

    var bytes: [256]u8 = undefined;
    if (request.fourth < 2 or request.fourth > bytes.len) return protocol.invalid;

    api.fetch(request, 0, bytes[0..request.fourth]) catch return protocol.invalid;

    const target = bytes[0..request.fourth];
    if (target[0] != '/') return protocol.invalid;

    if (protocol.value(request.second) == 0) {

        prune(target);
        return 0;

    }

    if (place(target)) return 0;

    full();

    return protocol.full;

}

/// Opens the app menu for `image` at `at` on the screen.
pub fn offer(image: Image, at: gui.Point) void {

    chosen = image;
    app_menu.show(at);

}

fn add(target: []const u8, column: u8, row: u8) void {

    items[count] = .{

        .column = column,
        .row = row,

    };

    @memcpy(items[count].bytes[0..target.len], target);
    items[count].length = target.len;
    count += 1;

}

/// Whether `target` is still there; only a missing file or folder counts as gone, so a busy file service loses nothing.
fn exists(target: []const u8) bool {

    if (catalog.application(target) != null) return true;
    if (target.len < 2 or target[0] != '/' or target.len > longest) return false;

    if (catalog.folder(target)) {

        var none: [0]api.files.Entry = .{};

        _ = files.list(target[0 .. target.len - 1], 0, &none) catch |err| return err != error.Missing;

        return true;

    }

    _ = files.read(target, 0, 1) catch |err| return err != error.Missing;

    return true;

}

fn changed() void {

    dock.arrange();
    shortcuts.redraw();

}

fn full() void {

    notices.post(.warning, "The desktop is full", "Take something off the desktop to make room.", null);

}

fn open_chosen() void {

    desktop.start_app(chosen, desktop.home);

}

fn dock_chosen() void {

    if (std.mem.indexOfScalar(Image, docked[0..docked_count], chosen)) |index| {

        std.mem.copyForwards(Image, docked[index .. docked_count - 1], docked[index + 1 .. docked_count]);
        docked_count -= 1;

    } else {

        docked[docked_count] = chosen;
        docked_count += 1;

    }

    save();
    changed();

}

fn place_chosen() void {

    const target = @tagName(chosen);

    if (find(target) != null) return prune(target);
    if (!place(target)) full();

}

fn running() bool {

    return desktop.running(chosen);

}

fn idle() bool {

    return !running();

}

fn chosen_docked() bool {

    return docks(chosen);

}

fn undocked() bool {

    return !docks(chosen);

}

fn chosen_placed() bool {

    return find(@tagName(chosen)) != null;

}

fn unplaced() bool {

    return !chosen_placed();

}
