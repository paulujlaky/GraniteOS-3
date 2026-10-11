//! Viewer: shows PNG pictures, fitted or zoomed, and steps through the others in their folder.

const std = @import("std");

const catalog = @import("catalog.zig");

const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;
pub const panic = api.panic;

const zooms = [_]f32{ 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 8 };

var window: gui.Window = undefined;
var files = api.Files{};

var picture: ?gui.Image = null;
var path_bytes: [512]u8 = undefined;
var path: []const u8 = "";

/// Fitting the window when null, else an index into `zooms`; and how far the picture is panned.
var zoom: ?usize = null;
var pan = gui.Point{};

var previous = gui.tool(.left, &stepBack);
var next = gui.tool(.right, &stepOn);
var name = gui.label("", .{

    .grow = 1,
    .padding = .axes(0, 6),

});
var smaller = gui.tool(.zoom_out, &zoomOut);
var scale_bytes: [16]u8 = undefined;
var scale = gui.label("Fit", theme.caption.with(.{

    .width = 48,
    .text_align = .center,

}));
var larger = gui.tool(.zoom_in, &zoomIn);
var fit = gui.tool(.zoom_fit, &fitWindow);
var tools = [_]*gui.Node{ &previous, &next, &name, &smaller, &scale, &larger, &fit };
var toolbar = gui.box(theme.bar, &tools);
var canvas = gui.custom(&paint, .{

    .grow = 1,

});
var message = gui.label("Open a picture from Files to see it here.", theme.caption.with(.{

    .grow = 1,
    .text_align = .center,

}));
var parts = [_]*gui.Node{ &toolbar, &canvas, &message };
var root = gui.box(.{

    .background = 0x101010,

}, &parts);

var title_bytes: [96]u8 = undefined;

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .application);

    var argument_bytes: [256]u8 = undefined;
    const argument = api.argument(&argument_bytes);
    const opened = catalog.picture(argument) and load(argument);

    // A picture sets the window's first size, within reason.
    const size = if (picture) |shown| gui.Rect{

        .width = std.math.clamp(@as(i32, @intCast(shown.width)), 420, 1000),
        .height = std.math.clamp(@as(i32, @intCast(shown.height)) + theme.bar.height.?, 320, 680),

    } else gui.Rect{

        .width = 560,
        .height = 380,

    };

    window = gui.Window.open(&root, .{

        .title = "Viewer",
        .application = .viewer,
        .width = size.width,
        .height = size.height,

    }) catch api.exit(3);

    if (!opened and argument.len != 0 and catalog.picture(argument)) message.content.label = "That picture could not be read.";
    sync();

    while (true) {

        const event = window.next(500) orelse continue;

        if (event.kind == .close) window.quit();
        react(event);

    }

}

fn react(event: api.Event) void {

    if (event.kind == .button and (event.code == 3 or event.code == 4)) return if (event.code == 3) zoomIn(&larger) else zoomOut(&smaller);
    if (event.kind != .key or !event.pressed) return;

    const nudge = 60;

    switch (event.key()) {

        .left => if (zoom == null) stepBack(&previous) else move(nudge, 0),
        .right => if (zoom == null) stepOn(&next) else move(-nudge, 0),
        .up => move(0, nudge),
        .down => move(0, -nudge),
        .page_up => stepBack(&previous),
        .page_down => stepOn(&next),
        .character => switch (event.char) {

            '+', '=' => zoomIn(&larger),
            '-' => zoomOut(&smaller),
            '0' => fitWindow(&fit),
            '1' => setZoom(3),
            else => {

            },

        },
        else => {

        },

    }

}

/// Decodes the PNG at `target` and shows it; false when it cannot be read.
fn load(target: []const u8) bool {

    var arena = std.heap.ArenaAllocator.init(api.pages);
    defer arena.deinit();

    const bytes = files.load(arena.allocator(), target) catch return false;
    const size = gui.png.size(bytes) catch return false;
    var fresh = gui.Image.init(size.width, size.height) catch return false;

    _ = gui.png.decode(arena.allocator(), bytes, fresh.pixels()) catch {

        fresh.deinit();
        return false;

    };

    fresh.publish() catch {

        fresh.deinit();
        return false;

    };

    if (picture) |*old| old.deinit();

    picture = fresh;
    path = std.fmt.bufPrint(&path_bytes, "{s}", .{target}) catch "";
    zoom = null;
    pan = .{};

    return true;

}

fn sync() void {

    const shown = picture != null;

    canvas.hidden = !shown;
    message.hidden = shown;
    name.content.label = if (shown) std.fs.path.basename(path) else "";
    scale.content.label = if (zoom) |index| std.fmt.bufPrint(&scale_bytes, "{d:.0}%", .{zooms[index] * 100}) catch "" else "Fit";
    window.retitle(if (shown) std.fmt.bufPrint(&title_bytes, "{s} - Viewer", .{std.fs.path.basename(path)}) catch "Viewer" else "Viewer");
    window.refresh();

}

fn paint(node: *gui.Node, target: *gui.List) void {

    const shown = picture orelse return;
    const area = node.rect;
    const index = zoom orelse return target.image(shown.handle, shown.place(area.inset(theme.spacing)));
    const width: i32 = @intFromFloat(@as(f32, @floatFromInt(shown.width)) * zooms[index]);
    const height: i32 = @intFromFloat(@as(f32, @floatFromInt(shown.height)) * zooms[index]);
    var placed = area.centered(width, height);

    placed.x += pan.x;
    placed.y += pan.y;
    target.image(shown.handle, placed);

}

fn move(dx: i32, dy: i32) void {

    const shown = picture orelse return;
    const index = zoom orelse return;
    const area = canvas.rect;
    const width: i32 = @intFromFloat(@as(f32, @floatFromInt(shown.width)) * zooms[index]);
    const height: i32 = @intFromFloat(@as(f32, @floatFromInt(shown.height)) * zooms[index]);

    // A picture pans only as far as it overhangs the window.
    const reach_x: i32 = @max(@divTrunc(width - area.width, 2), 0);
    const reach_y: i32 = @max(@divTrunc(height - area.height, 2), 0);

    pan.x = std.math.clamp(pan.x + dx, -reach_x, reach_x);
    pan.y = std.math.clamp(pan.y + dy, -reach_y, reach_y);
    window.invalidate(&canvas);

}

/// The zoom closest to how fitting shows the picture now.
fn fitted() usize {

    const shown = picture orelse return 3;
    const area = shown.place(canvas.rect.inset(theme.spacing));
    const ratio = @as(f32, @floatFromInt(area.width)) / @as(f32, @floatFromInt(shown.width));
    var best: usize = 0;

    for (zooms, 0..) |value, index| {

        if (@abs(value - ratio) < @abs(zooms[best] - ratio)) best = index;

    }

    return best;

}

fn setZoom(index: usize) void {

    zoom = index;
    pan = .{};
    sync();

}

fn zoomIn(_: *gui.Node) void {

    setZoom(@min((zoom orelse fitted()) + 1, zooms.len - 1));

}

fn zoomOut(_: *gui.Node) void {

    setZoom((zoom orelse fitted()) -| 1);

}

fn fitWindow(_: *gui.Node) void {

    zoom = null;
    pan = .{};
    sync();

}

fn stepBack(_: *gui.Node) void {

    step(-1);

}

fn stepOn(_: *gui.Node) void {

    step(1);

}

/// Shows the picture `direction` places along in its folder, by name, wrapping around.
fn step(direction: i2) void {

    if (path.len == 0) return;

    const folder = std.fs.path.dirnamePosix(path) orelse "/";
    const current = std.fs.path.basename(path);
    var arena = std.heap.ArenaAllocator.init(api.pages);
    defer arena.deinit();

    var names: std.ArrayList([]const u8) = .empty;
    var listed: [32]api.files.Entry = undefined;
    var index: u56 = 0;

    while (true) {

        const count = files.list(folder, index, &listed) catch break;
        if (count == 0) break;

        for (listed[0..count]) |entry| {

            if (entry.kind == .file and catalog.picture(entry.name)) names.append(arena.allocator(), arena.allocator().dupe(u8, entry.name) catch break) catch break;

        }

        index += @intCast(count);

    }

    if (names.items.len < 2) return;

    std.mem.sort([]const u8, names.items, {}, ordered);

    const position = for (names.items, 0..) |entry, place| {

        if (std.mem.eql(u8, entry, current)) break place;

    } else 0;
    const length = names.items.len;
    const chosen = names.items[(position + length + @as(usize, if (direction < 0) length - 1 else 1)) % length];

    var target: [512]u8 = undefined;
    const full = std.fmt.bufPrint(&target, "{s}{s}{s}", .{ folder, if (std.mem.endsWith(u8, folder, "/")) "" else "/", chosen }) catch return;

    if (load(full)) sync();

}

fn ordered(_: void, left: []const u8, right: []const u8) bool {

    return std.ascii.lessThanIgnoreCase(left, right);

}
