//! Files: browse folders, open files in the app that reads them, and create, rename, copy, or delete entries.

const std = @import("std");

const catalog = @import("catalog.zig");

const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;
pub const panic = api.panic;

const Entry = struct {

    name: []const u8,
    directory: bool,
    size: u64,

};

const control = api.Event.Modifiers{

    .control = true,

};

var window: gui.Window = undefined;
var files = api.Files{};
var arena = std.heap.ArenaAllocator.init(api.pages);

var path_bytes: [512]u8 = undefined;
var path: []const u8 = "/";
var home: []const u8 = "/";
var home_bytes: [64]u8 = undefined;

/// Folders visited before and after the current one.
var back_paths: [16][512]u8 = undefined;
var back_lengths: [16]usize = undefined;
var back_count: usize = 0;
var forward_paths: [16][512]u8 = undefined;
var forward_lengths: [16]usize = undefined;
var forward_count: usize = 0;

/// A file copied with Ctrl+C, pasted into the current folder with Ctrl+V.
var copied_bytes: [512]u8 = undefined;
var copied: []const u8 = "";

var entries: []Entry = &.{};
var lines: []gui.Node = &.{};
var selected: ?usize = null;

/// An entry being dragged to move it, and the folder it would land in, lit up, with whether it was selected before.
var dragging: ?struct { source: usize, drag: gui.Drag } = null;

/// What the tag beside a dragged entry shows, and where.
const Tag = struct {

    icon: gui.Icon,
    words: []const u8,
    area: gui.Rect,

};
var aimed: ?*gui.Node = null;
var lit = false;

var back = gui.tool(.back, &goBack);
var forward = gui.tool(.forward, &goForward);
var up = gui.tool(.up, &goUp);

var location = gui.label("/", .{

    .grow = 1,
    .padding = .axes(0, 6),

});

var folder = gui.tool(.folder_add, &makeFolder);
var document = gui.tool(.new, &makeFile);
var rename = gui.tool(.pencil, &renameEntry);
var remove = gui.tool(.trash, &removeEntry);
var divider = gui.box(theme.divider, &.{});
var refresh = gui.tool(.refresh, &reload);
var tools = [_]*gui.Node{ &back, &forward, &up, &location, &folder, &document, &divider, &rename, &remove, &refresh };
var toolbar = gui.box(theme.bar, &tools);

var dialog = gui.Dialog{};

/// The right-click menus of an entry and of the folder around them.
var entry_menu: gui.Menu(&.{

    .{ .icon = .folder_open, .title = "Open", .hint = "Enter", .run = openChosen },
    gui.menu.separator,
    .{ .icon = .pencil, .title = "Rename", .hint = "F2", .run = renameChosen },
    .{ .icon = .copy, .title = "Copy", .hint = "Ctrl+C", .run = copy, .enabled = copyable },
    .{ .icon = .clipboard, .title = "Copy path", .run = copyPath },
    gui.menu.separator,
    .{ .icon = .monitor, .title = "Add to desktop", .run = pinChosen, .offered = unpinned },
    .{ .icon = .close, .title = "Remove from desktop", .run = unpinChosen, .offered = pinned },
    gui.menu.separator,
    .{ .icon = .trash, .title = "Delete", .hint = "Del", .run = removeChosen },

}) = .{};

var folder_menu: gui.Menu(&.{

    .{ .icon = .folder_add, .title = "New folder", .run = folderChosen },
    .{ .icon = .new, .title = "New file", .run = fileChosen },
    .{ .icon = .paste, .title = "Paste", .hint = "Ctrl+V", .run = paste, .enabled = pasteable },
    gui.menu.separator,
    .{ .icon = .refresh, .title = "Refresh", .hint = "F5", .run = reloadChosen },

}) = .{};

const place = theme.item.with(.{

    .height = 32,

});

var home_icon = gui.icon(.home, theme.icon);
var home_label = gui.label("Home", .{});
var home_parts = [_]*gui.Node{ &home_icon, &home_label };
var home_place = gui.box(place, &home_parts);
var root_icon = gui.icon(.disk, theme.icon);
var root_label = gui.label("Computer", .{});
var root_parts = [_]*gui.Node{ &root_icon, &root_label };
var root_place = gui.box(place, &root_parts);

var places_title = gui.label("Places", theme.caption.with(.{

    .padding = gui.Edges.axes(4, 10),

}));

var places_parts = [_]*gui.Node{ &places_title, &home_place, &root_place };

var places = gui.box(.{

    .width = 170,
    .padding = .all(theme.gap),
    .gap = 2,

    .background = theme.pane,

}, &places_parts);

var name_heading = gui.label("Name", theme.caption.with(.{

    .grow = 1,
    .padding = .{

        .left = 38,

    },

}));

var size_heading = gui.label("Size", theme.caption.with(.{

    .width = 90,
    .text_align = .right,

}));

var heading_parts = [_]*gui.Node{ &name_heading, &size_heading };

var heading = gui.box(.{

    .height = 28,
    .padding = .axes(0, 20),

    .direction = .row,
    .items = .center,

}, &heading_parts);

var list = gui.box(.{

    .grow = 1,
    .padding = .axes(0, theme.gap),
    .gap = 1,

    .scroll = true,

}, &.{});

var empty = gui.label("This folder is empty.", theme.caption.with(.{

    .grow = 1,
    .text_align = .center,

}));

var status = gui.label("", theme.caption.with(.{

    .padding = gui.Edges.axes(0, theme.spacing),
    .height = 26,

}));

var main_parts = [_]*gui.Node{ &heading, &list, &empty, &status };

var main = gui.box(.{

    .grow = 1,

}, &main_parts);

var body_parts = [_]*gui.Node{ &places, &main };

var body = gui.box(.{

    .grow = 1,
    .direction = .row,

}, &body_parts);

var root_parts_all = [_]*gui.Node{ &toolbar, &body };
var root = gui.box(.{}, &root_parts_all);

/// A tag following the pointer while an entry is dragged, saying where it would go.
var carried = gui.custom(&paintCarried, .{});
var scene_parts = [_]*gui.Node{ &root, &carried };

var scene = gui.box(.{

    .direction = .stack,

}, &scene_parts);

var status_bytes: [96]u8 = undefined;

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .application);
    dialog.init();

    var argument_bytes: [256]u8 = undefined;
    const argument = api.argument(&argument_bytes);

    home = std.fmt.bufPrint(&home_bytes, "{s}", .{catalog.home(argument) orelse "/"}) catch "/";
    home_place.action = &goHome;
    root_place.action = &goRoot;

    window = gui.Window.open(&scene, .{

        .title = "Files",
        .application = .explorer,

        .width = 780,
        .height = 500,

    }) catch api.exit(3);

    entry_menu.init(&window);
    folder_menu.init(&window);
    main.menu = &offerFolder;

    visit(if (argument.len != 0) argument else home, false);

    while (true) {

        const event = window.next(500) orelse continue;

        if (event.kind == .close) window.quit();
        react(event);

    }

}

fn react(event: api.Event) void {

    if (event.kind != .key or !event.pressed or dialog.open()) return;

    if (event.chord(control, 'c')) return copy();
    if (event.chord(control, 'v')) return paste();

    switch (event.key()) {

        .up => choose(if (selected) |index| index -| 1 else 0),
        .down => choose(if (selected) |index| @min(index + 1, entries.len -| 1) else 0),
        .enter => if (selected) |index| open(index),
        .backspace => goUp(&up),
        .delete => removeEntry(&remove),
        .f2 => renameEntry(&rename),
        .f5 => reload(&refresh),
        else => {

        },

    }

}

/// Shows folder `target`, remembering the current one for Back unless `quiet`.
fn visit(target: []const u8, quiet: bool) void {

    var listed: [32]api.files.Entry = undefined;

    if (files.list(target, 0, listed[0..1])) |_| {} else |err| return report(err);

    if (!quiet and !std.mem.eql(u8, target, path)) {

        remember(&back_paths, &back_lengths, &back_count, path);
        forward_count = 0;

    }

    path = std.fmt.bufPrint(&path_bytes, "{s}", .{target}) catch return;
    selected = null;
    reload(&refresh);

}

/// Reads the current folder again and rebuilds the list.
fn reload(_: *gui.Node) void {

    // The rows are built afresh, so the selection carries over by name, and is gone with an entry deleted or renamed.
    var kept: [256]u8 = undefined;
    var chosen: ?[]const u8 = null;

    if (selected) |index| if (entries[index].name.len <= kept.len) {

        @memcpy(kept[0..entries[index].name.len], entries[index].name);
        chosen = kept[0..entries[index].name.len];

    };

    selected = null;

    _ = arena.reset(.free_all);

    const allocator = arena.allocator();
    var found: std.ArrayList(Entry) = .empty;
    var listed: [32]api.files.Entry = undefined;
    var index: u56 = 0;

    while (true) {

        const count = files.list(path, index, &listed) catch |err| {

            report(err);
            break;

        };

        if (count == 0) break;

        for (listed[0..count]) |entry| {

            found.append(allocator, .{

                .name = allocator.dupe(u8, entry.name) catch break,
                .directory = entry.kind == .directory,
                .size = entry.size,

            }) catch break;

        }

        index += @intCast(count);

    }

    entries = found.items;
    std.mem.sort(Entry, entries, {}, before);

    build(allocator) catch {

        entries = &.{};

    };

    location.content.label = path;
    window.retitle(if (std.mem.eql(u8, path, "/")) "Files" else std.fs.path.basename(path));
    window.view(&scene);
    summarize();
    if (chosen) |name| select(name);

}

/// Directories first, then by name regardless of case.
fn before(_: void, left: Entry, right: Entry) bool {

    if (left.directory != right.directory) return left.directory;

    return std.ascii.lessThanIgnoreCase(left.name, right.name);

}

fn build(allocator: std.mem.Allocator) !void {

    const rows = try allocator.alloc(gui.Node, entries.len);
    const icons = try allocator.alloc(gui.Node, entries.len);
    const names = try allocator.alloc(gui.Node, entries.len);
    const sizes = try allocator.alloc(gui.Node, entries.len);
    const parts = try allocator.alloc([3]*gui.Node, entries.len);
    const children = try allocator.alloc(*gui.Node, entries.len);

    for (entries, 0..) |entry, index| {

        icons[index] = gui.icon(catalog.symbol(entry.name, entry.directory), theme.icon);

        names[index] = gui.label(entry.name, .{

            .grow = 1,

        });

        sizes[index] = gui.label(if (entry.directory) "" else try catalog.amount(allocator, entry.size), theme.caption.with(.{

            .width = 90,
            .text_align = .right,

        }));

        parts[index] = .{ &icons[index], &names[index], &sizes[index] };
        rows[index] = gui.box(theme.item, &parts[index]);
        rows[index].action = &pick;
        rows[index].open = &launch;
        rows[index].track = &drag;
        rows[index].menu = &offerEntry;
        rows[index].data = index;
        children[index] = &rows[index];

    }

    lines = rows;
    list.content.box = children;
    list.offset = 0;
    empty.hidden = entries.len != 0;
    list.hidden = entries.len == 0;

}

fn summarize() void {

    const usage = files.usage() catch null;
    const count = entries.len;

    status.content.label = if (usage) |volume| std.fmt.bufPrint(&status_bytes, "{d} {s}    {d} MB free of {d} MB", .{

        count, if (count == 1) "item" else "items", volume.free >> 20, volume.total >> 20,

    }) catch "" else std.fmt.bufPrint(&status_bytes, "{d} items", .{count}) catch "";

    window.refresh();

}

fn report(err: api.ServiceError) void {

    status.content.label = catalog.reason(err);
    window.refresh();

}

fn choose(index: usize) void {

    if (entries.len == 0) return;
    if (selected) |old| lines[old].selected = false;

    selected = index;
    lines[index].selected = true;
    window.focus(&lines[index]);
    window.refresh();

}

fn pick(row: *gui.Node) void {

    choose(row.data);

}

fn launch(row: *gui.Node) void {

    open(row.data);

}

/// Follows a row dragged by the pointer, lighting up the folder it would move into, and moves it there when dropped.
fn drag(row: *gui.Node, track: gui.Track) void {

    var earlier_bytes: [300]u8 = undefined;
    const earlier = tagged(&earlier_bytes);

    switch (track.phase) {

        .down => dragging = .{

            .source = row.data,
            .drag = .init(track.at),

        },
        .move => if (dragging) |*held| {

            if (!held.drag.follow(track.at)) return;

            row.cursor = .grabbing;
            aim(destination(window.root.hit(track.at), held.source));

        },
        .up => {

            const held = dragging orelse return;
            const target = aimed;

            dragging = null;
            row.cursor = null;
            aim(null);
            if (earlier) |shown| window.damage = window.damage.join(shown.area);
            if (held.drag.moved) if (target) |node| move(held.source, node);

            return;

        },

    }

    // Only where the tag was and is repaints.
    var after_bytes: [300]u8 = undefined;

    for ([_]?Tag{ earlier, tagged(&after_bytes) }) |entry| {

        if (entry) |shown| window.damage = window.damage.join(shown.area);

    }

}

/// The tag of the drag under way, just below and right of the pointer: the entry, and where it would move once over a folder.
fn tagged(out: []u8) ?Tag {

    const held = dragging orelse return null;
    if (!held.drag.moved) return null;

    const entry = entries[held.source];
    const words = if (aimed) |node| std.fmt.bufPrint(out, "Move {s} to {s}", .{ entry.name, named(node) }) catch entry.name else entry.name;
    const icon = catalog.symbol(entry.name, entry.directory);

    return .{

        .icon = icon,
        .words = words,
        .area = gui.draw.tagged(icon, words, .{

            .x = held.drag.at.x + 14,
            .y = held.drag.at.y + 12,

        }, false),

    };

}

fn paintCarried(_: *gui.Node, target: *gui.List) void {

    var bytes: [300]u8 = undefined;
    const shown = tagged(&bytes) orelse return;

    target.tag(shown.icon, shown.words, shown.area);

}

/// What people call the folder `node` stands for as a drop target.
fn named(node: *gui.Node) []const u8 {

    if (node == &home_place) return "Home";
    if (node == &root_place) return "Computer";

    if (node == &up) {

        const parent = std.fs.path.dirnamePosix(path) orelse "/";

        return if (std.mem.eql(u8, parent, "/")) "Computer" else std.fs.path.basename(parent);

    }

    return entries[node.data].name;

}

/// `found`, when entry `source` may be dropped on it: another folder in the list, a place, or the Up button for the parent folder.
fn destination(found: ?*gui.Node, source: usize) ?*gui.Node {

    const node = found orelse return null;
    if (node == &home_place or node == &root_place or node == &up) return node;

    for (lines, 0..) |*line, index| {

        if (line == node) return if (index != source and entries[index].directory) node else null;

    }

    return null;

}

/// Lights up `node` as where a drop would land, giving the last one its own look back.
fn aim(node: ?*gui.Node) void {

    if (aimed == node) return;

    if (aimed) |old| {

        old.selected = lit;
        window.invalidate(old);

    }

    aimed = node;

    if (node) |new| {

        lit = new.selected;
        new.selected = true;
        window.invalidate(new);

    }

}

/// Moves entry `source` into the folder `node` stands for.
fn move(source: usize, node: *gui.Node) void {

    var inside_bytes: [512]u8 = undefined;
    var from_bytes: [512]u8 = undefined;
    var to_bytes: [512]u8 = undefined;
    const name = entries[source].name;

    const inside = if (node == &home_place) home else if (node == &root_place) "/" else if (node == &up) std.fs.path.dirnamePosix(path) orelse "/" else join(&inside_bytes, entries[node.data].name) orelse return;
    const from = join(&from_bytes, name) orelse return;

    if (std.mem.eql(u8, inside, path)) return;

    // A folder cannot go inside itself.
    if (std.mem.startsWith(u8, inside, from) and (inside.len == from.len or inside[from.len] == '/')) return report(error.Invalid);

    const to = std.fmt.bufPrint(&to_bytes, "{s}{s}{s}", .{ inside, if (std.mem.endsWith(u8, inside, "/")) "" else "/", name }) catch return;

    files.rename(from, to) catch |err| return report(err);
    repin(from, to, entries[source].directory);
    reload(&refresh);

}

fn open(index: usize) void {

    var target: [512]u8 = undefined;
    const full = join(&target, entries[index].name) orelse return;

    if (entries[index].directory) return visit(full, false);

    catalog.start(catalog.opener(full), full) catch |err| report(err);

}

fn goBack(_: *gui.Node) void {

    if (back_count == 0) return;

    remember(&forward_paths, &forward_lengths, &forward_count, path);
    back_count -= 1;
    visit(back_paths[back_count][0..back_lengths[back_count]], true);

}

fn goForward(_: *gui.Node) void {

    if (forward_count == 0) return;

    remember(&back_paths, &back_lengths, &back_count, path);
    forward_count -= 1;
    visit(forward_paths[forward_count][0..forward_lengths[forward_count]], true);

}

fn goUp(_: *gui.Node) void {

    if (std.mem.eql(u8, path, "/")) return;

    var target: [512]u8 = undefined;
    const parent = std.fs.path.dirnamePosix(path) orelse "/";

    @memcpy(target[0..parent.len], parent);
    visit(target[0..parent.len], false);

}

fn goHome(_: *gui.Node) void {

    visit(home, false);

}

fn goRoot(_: *gui.Node) void {

    visit("/", false);

}

fn remember(paths: *[16][512]u8, lengths: *[16]usize, count: *usize, value: []const u8) void {

    // A full history forgets its oldest entry.
    if (count.* == paths.len) {

        std.mem.copyForwards([512]u8, paths[0 .. paths.len - 1], paths[1..]);
        std.mem.copyForwards(usize, lengths[0 .. paths.len - 1], lengths[1..]);
        count.* -= 1;

    }

    @memcpy(paths[count.*][0..value.len], value);
    lengths[count.*] = value.len;
    count.* += 1;

}

/// `name` inside the current folder, written into `out`.
fn join(out: []u8, name: []const u8) ?[]const u8 {

    const separator = if (std.mem.endsWith(u8, path, "/")) "" else "/";

    return std.fmt.bufPrint(out, "{s}{s}{s}", .{ path, separator, name }) catch null;

}

fn makeFolder(_: *gui.Node) void {

    dialog.ask(&window, "New folder", "New folder", "Create", &createFolder);

}

fn makeFile(_: *gui.Node) void {

    dialog.ask(&window, "New file", "Untitled.txt", "Create", &createFile);

}

fn createFolder(name: []const u8) void {

    create(name, true);

}

fn createFile(name: []const u8) void {

    create(name, false);

}

fn create(name: []const u8, directory: bool) void {

    var target: [512]u8 = undefined;

    if (!catalog.valid(name)) return dialog.refuse(catalog.unnamed);

    const full = join(&target, name) orelse return dialog.refuse(catalog.unnamed);
    const result = if (directory) files.directory(full) else files.create(full);

    result catch |err| {

        return dialog.refuse(catalog.reason(err));

    };

    reload(&refresh);
    select(name);

}

fn renameEntry(_: *gui.Node) void {

    const index = selected orelse return;

    dialog.ask(&window, "Rename to", entries[index].name, "Rename", &applyRename);

}

fn applyRename(name: []const u8) void {

    const index = selected orelse return;
    var from: [512]u8 = undefined;
    var to: [512]u8 = undefined;

    if (!catalog.valid(name)) return dialog.refuse(catalog.unnamed);

    const old = join(&from, entries[index].name) orelse return;
    const new = join(&to, name) orelse return;

    files.rename(old, new) catch |err| {

        return dialog.refuse(catalog.reason(err));

    };

    repin(old, new, entries[index].directory);

    var kept: [256]u8 = undefined;
    const copy_name = kept[0..name.len];

    @memcpy(copy_name, name);
    reload(&refresh);
    select(copy_name);

}

fn removeEntry(_: *gui.Node) void {

    const index = selected orelse return;
    var message: [300]u8 = undefined;

    dialog.check(&window, std.fmt.bufPrint(&message, "Delete \"{s}\"?", .{entries[index].name}) catch "Delete it?", "This can't be undone.", "Delete", &applyRemove);

}

fn applyRemove(_: []const u8) void {

    const index = selected orelse return;
    var target: [512]u8 = undefined;

    const full = join(&target, entries[index].name) orelse return;

    files.remove(full) catch |err| return report(err);
    repin(full, null, entries[index].directory);
    reload(&refresh);

}

/// What the desktop calls entry `index` when it is pinned there: its full path, ending in `/` for a folder.
fn pinning(out: []u8, index: usize) ?[]const u8 {

    const full = join(out[0 .. out.len - 1], entries[index].name) orelse return null;

    if (!entries[index].directory) return full;

    out[full.len] = '/';

    return out[0 .. full.len + 1];

}

/// Keeps the desktop's item for `from` pointing at it once it moves to `to`, or takes it off once deleted.
fn repin(from: []const u8, to: ?[]const u8, directory: bool) void {

    var old_bytes: [514]u8 = undefined;
    var new_bytes: [514]u8 = undefined;
    const slash = if (directory) "/" else "";
    const old = std.fmt.bufPrint(&old_bytes, "{s}{s}", .{ from, slash }) catch return;

    if (!catalog.placed(owner(), old)) return;

    api.pin(old, false) catch {

    };

    api.pin(std.fmt.bufPrint(&new_bytes, "{s}{s}", .{ to orelse return, slash }) catch return, true) catch {

    };

}

/// The user whose home Files opened in.
fn owner() []const u8 {

    return if (catalog.home(home) != null) std.fs.path.basenamePosix(home) else "";

}

/// Remembers the selected file for pasting; folders are not copied.
fn copy() void {

    const index = selected orelse return;
    if (entries[index].directory) return report(error.Invalid);

    copied = join(&copied_bytes, entries[index].name) orelse return;
    status.content.label = "Copied. Paste into another folder with Ctrl+V.";
    window.refresh();

}

fn paste() void {

    if (copied.len == 0) return;

    var scratch = std.heap.ArenaAllocator.init(api.pages);
    defer scratch.deinit();

    var target: [512]u8 = undefined;
    var name = std.fs.path.basename(copied);
    var renamed: [256]u8 = undefined;

    // Pasting beside the original keeps both, as `copy of NAME`.
    for (entries) |entry| {

        if (!std.mem.eql(u8, entry.name, name)) continue;

        name = std.fmt.bufPrint(&renamed, "copy of {s}", .{name}) catch return;
        break;

    }

    const full = join(&target, name) orelse return;
    const bytes = files.load(scratch.allocator(), copied) catch |err| return report(err);

    files.save(scratch.allocator(), full, bytes) catch |err| return report(err);
    reload(&refresh);
    select(name);

}

fn select(name: []const u8) void {

    for (entries, 0..) |entry, index| {

        if (std.mem.eql(u8, entry.name, name)) return choose(index);

    }

}

fn offerEntry(row: *gui.Node, at: gui.Point) void {

    choose(row.data);
    entry_menu.show(at);

}

fn offerFolder(_: *gui.Node, at: gui.Point) void {

    folder_menu.show(at);

}

fn openChosen() void {

    if (selected) |index| open(index);

}

fn renameChosen() void {

    renameEntry(&rename);

}

fn removeChosen() void {

    removeEntry(&remove);

}

fn folderChosen() void {

    makeFolder(&folder);

}

fn fileChosen() void {

    makeFile(&document);

}

fn reloadChosen() void {

    reload(&refresh);

}

/// Puts the selected entry's full path on the clipboard.
fn copyPath() void {

    const index = selected orelse return;
    var target: [512]u8 = undefined;

    gui.display.copy(join(&target, entries[index].name) orelse return) catch |err| return report(err);
    status.content.label = "Path copied.";
    window.refresh();

}

fn pinChosen() void {

    pin(true);

}

fn unpinChosen() void {

    pin(false);

}

fn pin(on: bool) void {

    var target: [514]u8 = undefined;

    // The desktop says itself when it is full.
    api.pin(pinning(&target, selected orelse return) orelse return, on) catch |err| if (err != error.Full) report(err);

}

fn pinned() bool {

    var target: [514]u8 = undefined;

    return catalog.placed(owner(), pinning(&target, selected orelse return false) orelse return false);

}

fn unpinned() bool {

    return !pinned();

}

/// Only files can be copied, so a folder greys Copy out.
fn copyable() bool {

    const index = selected orelse return false;

    return !entries[index].directory;

}

fn pasteable() bool {

    return copied.len != 0;

}
