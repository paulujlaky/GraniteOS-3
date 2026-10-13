//! Screenshots: takes snips through the desktop, by area, window, or whole screen after an optional delay, and keeps the
//! pictures in `~/Screenshots`, newest first, to look at, open, edit, rename, or delete.

const std = @import("std");

const catalog = @import("catalog.zig");

const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;
pub const panic = api.panic;

const control = api.Event.Modifiers{

    .control = true,

};

const Mode = struct {

    kind: api.Snip,
    icon: gui.Icon,
    title: []const u8,

};

const modes = [_]Mode{

    .{ .kind = .region, .icon = .rectangle, .title = "Area" },
    .{ .kind = .window, .icon = .app, .title = "Window" },
    .{ .kind = .screen, .icon = .monitor, .title = "Screen" },

};

/// Seconds a snip may wait, so menus can be opened first.
const delays = [_]u8{ 0, 3, 5, 10 };
const delay_titles = [_][]const u8{ "No delay", "3 s delay", "5 s delay", "10 s delay" };

/// A toolbar toggle showing an icon beside its name.
const chip = gui.Style{

    .height = theme.control,
    .padding = .axes(0, 10),
    .direction = .row,
    .gap = 6,
    .items = .center,

    .radius = theme.radius,

    .hover = .{

        .background = theme.hover,

    },
    .pressed = .{

        .background = theme.selected,

    },
    .selected = .{

        .background = theme.selected,

    },

};

const Shot = struct {

    name: []const u8,
    size: u64,

};

var window: gui.Window = undefined;
var files = api.Files{};
var arena = std.heap.ArenaAllocator.init(api.pages);
var dialog = gui.Dialog{};

/// The `screenshots` config, which keeps the mode and delay last picked.
var preferences = api.Config{};

var folder_bytes: [96]u8 = undefined;
var folder: []const u8 = "";

var kind: api.Snip = .region;
var delay: usize = 0;

var shots: []Shot = &.{};
var lines: []gui.Node = &.{};
var selected: ?usize = null;

/// The selected picture, shown fitted beside the list.
var shown: ?gui.Image = null;

var snip = gui.button("New snip", &snipNow);
var mode_icons: [modes.len]gui.Node = undefined;
var mode_labels: [modes.len]gui.Node = undefined;
var mode_parts: [modes.len][2]*gui.Node = undefined;
var mode_chips: [modes.len]gui.Node = undefined;
var timing_icon = gui.icon(.timer, theme.icon);

var timing_label = gui.label(delay_titles[0], .{

    .size = theme.small,

});

var timing_parts = [_]*gui.Node{ &timing_icon, &timing_label };
var timing = gui.box(chip, &timing_parts);
var spring = gui.box(theme.spring, &.{});
var view = gui.tool(.image, &openShot);
var edit = gui.tool(.brush, &editShot);
var rename = gui.tool(.pencil, &renameShot);
var remove = gui.tool(.trash, &removeShot);
var divider = gui.box(theme.divider, &.{});
var refresh = gui.tool(.refresh, &reload);
var tools = [_]*gui.Node{ &snip, &mode_chips[0], &mode_chips[1], &mode_chips[2], &timing, &spring, &view, &edit, &divider, &rename, &remove, &refresh };
var toolbar = gui.box(theme.bar, &tools);

var shot_menu: gui.Menu(&.{

    .{ .icon = .image, .title = "Open", .hint = "Enter", .run = openChosen },
    .{ .icon = .brush, .title = "Edit in Drawing", .run = editChosen },
    gui.menu.separator,
    .{ .icon = .pencil, .title = "Rename", .hint = "F2", .run = renameChosen },
    .{ .icon = .trash, .title = "Delete", .hint = "Del", .run = removeChosen },

}) = .{};

var list = gui.box(.{

    .width = 280,
    .padding = .all(theme.gap),
    .gap = 1,

    .background = theme.pane,
    .scroll = true,

}, &.{});

var preview = gui.custom(&paint, .{

    .grow = 1,

});

var detail = gui.label("", theme.caption.with(.{

    .height = 26,
    .text_align = .center,

}));

var empty = gui.label("No screenshots yet. Take one with New snip, or Super+Shift+S anywhere.", theme.caption.with(.{

    .grow = 1,
    .text_align = .center,

}));

var status = gui.label("", theme.caption.with(.{

    .padding = gui.Edges.axes(0, theme.spacing),
    .height = 26,

}));

var stage_parts = [_]*gui.Node{ &preview, &detail, &empty };

var stage = gui.box(.{

    .grow = 1,
    .padding = .all(theme.spacing),

    .background = 0x101010,

}, &stage_parts);

var body_parts = [_]*gui.Node{ &list, &stage };

var body = gui.box(.{

    .grow = 1,
    .direction = .row,

}, &body_parts);

var root_parts = [_]*gui.Node{ &toolbar, &body, &status };
var root = gui.box(.{}, &root_parts);

var detail_bytes: [96]u8 = undefined;

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .application);
    dialog.init();

    var argument_bytes: [256]u8 = undefined;
    const argument = api.argument(&argument_bytes);
    const home = catalog.home(argument) orelse "";

    folder = std.fmt.bufPrint(&folder_bytes, "{s}/{s}", .{ home, catalog.screenshots }) catch "";
    preferences.open(std.fs.path.basename(home), "screenshots");
    kind = std.meta.stringToEnum(api.Snip, preferences.get("mode") orelse "") orelse .region;
    delay = std.mem.indexOfScalar(u8, &delays, preferences.number(u8, "delay") orelse 0) orelse 0;

    snip.style = theme.primary;
    timing.action = &cycleDelay;

    for (modes, 0..) |mode, index| {

        mode_icons[index] = gui.icon(mode.icon, theme.icon);

        mode_labels[index] = gui.label(mode.title, .{

            .size = theme.small,

        });

        mode_parts[index] = .{ &mode_icons[index], &mode_labels[index] };
        mode_chips[index] = gui.box(chip, &mode_parts[index]);
        mode_chips[index].action = &pick;
        mode_chips[index].data = index;

    }

    window = gui.Window.open(&root, .{

        .title = "Screenshots",
        .application = .screenshots,

        .width = 820,
        .height = 520,

    }) catch api.exit(3);

    shot_menu.init(&window);
    sync();
    reload(&refresh);

    // Opened from a notification, the snip it told of comes up first.
    if (catalog.picture(argument)) select(std.fs.path.basename(argument));

    while (true) {

        const event = window.next(500) orelse continue;

        if (event.kind == .close) window.quit();
        react(event);

    }

}

fn react(event: api.Event) void {

    if (event.kind != .key or !event.pressed or dialog.open()) return;

    if (event.chord(control, 'n')) return snipNow(&snip);

    switch (event.key()) {

        .up => choose(if (selected) |index| index -| 1 else 0),
        .down => choose(if (selected) |index| @min(index + 1, shots.len -| 1) else 0),
        .enter => openShot(&view),
        .delete => removeShot(&remove),
        .f2 => renameShot(&rename),
        .f5 => reload(&refresh),
        else => {

        },

    }

}

/// Asks the desktop for a snip, the window tucked away until it is taken, then shows it.
fn snipNow(_: *gui.Node) void {

    var path_bytes: [256]u8 = undefined;

    const saved = api.snip(kind, delays[delay], window.surface.id, &path_bytes) catch |err| return report(switch (err) {

        error.Busy => "A snip is already under way.",
        else => "The desktop could not take a snip.",

    });

    reload(&refresh);
    if (saved) |path| select(std.fs.path.basename(path));

}

fn pick(chosen: *gui.Node) void {

    kind = modes[chosen.data].kind;
    _ = preferences.set("mode", @tagName(kind));
    keep();

}

fn cycleDelay(_: *gui.Node) void {

    delay = (delay + 1) % delays.len;
    _ = preferences.set("delay", delays[delay]);
    keep();

}

/// Saves the mode and delay, then shows them.
fn keep() void {

    preferences.save() catch {

    };

    sync();

}

fn sync() void {

    for (modes, &mode_chips) |mode, *node| node.selected = mode.kind == kind;

    timing_label.content.label = delay_titles[delay];
    window.refresh();

}

/// Reads the folder again and rebuilds the list, newest first, keeping the selection by name.
fn reload(_: *gui.Node) void {

    var kept: [256]u8 = undefined;
    var chosen: ?[]const u8 = null;

    if (selected) |index| if (shots[index].name.len <= kept.len) {

        @memcpy(kept[0..shots[index].name.len], shots[index].name);
        chosen = kept[0..shots[index].name.len];

    };

    selected = null;
    _ = arena.reset(.free_all);

    const allocator = arena.allocator();
    var found: std.ArrayList(Shot) = .empty;
    var listed: [32]api.files.Entry = undefined;
    var index: u56 = 0;

    while (files.list(folder, index, &listed)) |count| {

        if (count == 0) break;

        for (listed[0..count]) |entry| {

            if (entry.kind != .file or !catalog.picture(entry.name)) continue;

            found.append(allocator, .{

                .name = allocator.dupe(u8, entry.name) catch break,
                .size = entry.size,

            }) catch break;

        }

        index += @intCast(count);

    } else |err| if (err != error.Missing) report(catalog.reason(err));

    shots = found.items;
    std.mem.sort(Shot, shots, {}, newer);

    build(allocator) catch {

        shots = &.{};

    };

    window.view(&root);
    if (chosen) |name| select(name) else if (shots.len != 0) choose(0) else show(null);

}

/// By name, latest first: snips are named by when they were taken.
fn newer(_: void, left: Shot, right: Shot) bool {

    return std.mem.order(u8, left.name, right.name) == .gt;

}

fn build(allocator: std.mem.Allocator) !void {

    const rows = try allocator.alloc(gui.Node, shots.len);
    const icons = try allocator.alloc(gui.Node, shots.len);
    const names = try allocator.alloc(gui.Node, shots.len);
    const parts = try allocator.alloc([2]*gui.Node, shots.len);
    const children = try allocator.alloc(*gui.Node, shots.len);

    for (shots, 0..) |shot, index| {

        icons[index] = gui.icon(.image, theme.icon);

        names[index] = gui.label(shot.name[0 .. shot.name.len - 4], .{

            .grow = 1,

        });

        parts[index] = .{ &icons[index], &names[index] };
        rows[index] = gui.box(theme.item, &parts[index]);
        rows[index].action = &pickRow;
        rows[index].open = &openRow;
        rows[index].menu = &offerRow;
        rows[index].data = index;
        children[index] = &rows[index];

    }

    lines = rows;
    list.content.box = children;
    list.offset = 0;

}

fn choose(index: usize) void {

    if (shots.len == 0) return;
    if (selected) |old| lines[old].selected = false;

    selected = index;
    lines[index].selected = true;
    window.focus(&lines[index]);
    show(index);

}

fn select(name: []const u8) void {

    for (shots, 0..) |shot, index| {

        if (std.mem.eql(u8, shot.name, name)) return choose(index);

    }

}

/// Shows picture `index` beside the list, or nothing.
fn show(index: ?usize) void {

    if (shown) |*old| old.deinit();
    shown = null;

    if (index) |chosen| shown = load(shots[chosen].name);

    const picture = shown;

    preview.hidden = picture == null;
    detail.hidden = picture == null;
    empty.hidden = picture != null;
    empty.content.label = if (shots.len == 0) "No screenshots yet. Take one with New snip, or Super+Shift+S anywhere." else "That picture could not be read.";

    if (picture) |image| {

        const size = catalog.amount(arena.allocator(), shots[index.?].size) catch "";

        detail.content.label = std.fmt.bufPrint(&detail_bytes, "{d} x {d}    {s}", .{ image.width, image.height, size }) catch "";

    }

    for ([_]*gui.Node{ &view, &edit, &rename, &remove }) |tool| tool.hidden = index == null;
    divider.hidden = index == null;
    window.retitle(if (index) |chosen| shots[chosen].name else "Screenshots");
    window.refresh();

}

fn load(name: []const u8) ?gui.Image {

    var scratch = std.heap.ArenaAllocator.init(api.pages);
    defer scratch.deinit();

    var path_bytes: [512]u8 = undefined;
    const bytes = files.load(scratch.allocator(), locate(&path_bytes, name) orelse return null) catch return null;
    var picture = gui.Image.decode(scratch.allocator(), bytes) catch return null;

    picture.publish() catch {

        picture.deinit();
        return null;

    };

    return picture;

}

fn paint(node: *gui.Node, target: *gui.List) void {

    const picture = shown orelse return;

    target.image(picture.handle, picture.place(node.rect));

}

fn locate(out: []u8, name: []const u8) ?[]const u8 {

    return std.fmt.bufPrint(out, "{s}/{s}", .{ folder, name }) catch null;

}

fn report(message: []const u8) void {

    status.content.label = message;
    window.refresh();

}

fn pickRow(row: *gui.Node) void {

    choose(row.data);

}

fn openRow(row: *gui.Node) void {

    choose(row.data);
    openShot(&view);

}

fn offerRow(row: *gui.Node, at: gui.Point) void {

    choose(row.data);
    shot_menu.show(at);

}

fn openShot(_: *gui.Node) void {

    launch(.viewer);

}

fn editShot(_: *gui.Node) void {

    launch(.drawing);

}

/// Opens the selected picture in `image`, such as the Viewer.
fn launch(image: api.abi.Image) void {

    const index = selected orelse return;
    var path_bytes: [512]u8 = undefined;

    catalog.start(image, locate(&path_bytes, shots[index].name) orelse return) catch report("That app could not be started.");

}

fn renameShot(_: *gui.Node) void {

    const index = selected orelse return;

    dialog.ask(&window, "Rename to", shots[index].name, "Rename", &applyRename);

}

fn applyRename(name: []const u8) void {

    const index = selected orelse return;
    var from: [512]u8 = undefined;
    var to: [512]u8 = undefined;
    var named: [256]u8 = undefined;

    if (!catalog.valid(name)) return dialog.refuse(catalog.unnamed);

    // Only pictures show here, so a new name keeps the extension.
    const full = if (catalog.picture(name)) name else std.fmt.bufPrint(&named, "{s}.png", .{name}) catch return dialog.refuse(catalog.unnamed);

    files.rename(locate(&from, shots[index].name) orelse return, locate(&to, full) orelse return) catch |err| return dialog.refuse(catalog.reason(err));

    var kept: [256]u8 = undefined;
    const copy = kept[0..full.len];

    @memcpy(copy, full);
    reload(&refresh);
    select(copy);

}

fn removeShot(_: *gui.Node) void {

    const index = selected orelse return;
    var message: [300]u8 = undefined;

    dialog.check(&window, std.fmt.bufPrint(&message, "Delete \"{s}\"?", .{shots[index].name}) catch "Delete it?", "This can't be undone.", "Delete", &applyRemove);

}

fn applyRemove(_: []const u8) void {

    const index = selected orelse return;
    var target: [512]u8 = undefined;
    const next = index;

    files.remove(locate(&target, shots[index].name) orelse return) catch |err| return report(catalog.reason(err));

    selected = null;
    reload(&refresh);
    if (shots.len != 0) choose(@min(next, shots.len - 1));

}

fn openChosen() void {

    openShot(&view);

}

fn editChosen() void {

    editShot(&edit);

}

fn renameChosen() void {

    renameShot(&rename);

}

fn removeChosen() void {

    removeShot(&remove);

}
