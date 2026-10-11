//! The signed-in desktop: wallpaper, top bar, dock, app launcher, and session menu, all surfaces of the login process.

const std = @import("std");

const catalog = @import("catalog.zig");

const api = @import("api");
const gui = @import("gui");

const protocol = api.protocol;
const session = @import("root");
const theme = gui.theme;

/// Rows the top bar keeps, and the dock's button size.
const height = 30;
const slot = 46;
const margin = 8;

const days = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

const glass = gui.shade(0x101010, 232);

const chip = gui.Style{

    .padding = .axes(0, 10),
    .direction = .row,
    .gap = 7,
    .items = .center,

    .radius = theme.radius,

    .hover = .{

        .background = gui.shade(0xffffff, 24),

    },
    .pressed = .{

        .background = gui.shade(0xffffff, 40),

    },
    .selected = .{

        .background = gui.shade(0xffffff, 32),

    },

};

const popup = gui.Style{

    .padding = .all(6),
    .gap = 2,

    .background = theme.raised,
    .border = theme.line,
    .border_width = theme.border,
    .radius = theme.corner,

};

pub var wallpaper: gui.Window = undefined;
var bar: gui.Window = undefined;
var dock: gui.Window = undefined;
var launcher: gui.Window = undefined;
var menu: gui.Window = undefined;

/// The picture behind everything, shared with the lock screen.
pub var backdrop: gui.Image = undefined;
var scenery = gui.picture(&backdrop, .{

    .grow = 1,

});

var files = api.Files{};

// Top bar.
var apps_icon = gui.icon(.grid, theme.icon);
var apps_label = gui.label("Apps", .{

    .size = theme.small,

});
var apps_parts = [_]*gui.Node{ &apps_icon, &apps_label };
var apps = gui.box(chip, &apps_parts);
var title = gui.label("", .{

    .grow = 1,
    .size = theme.small,

});
var time_bytes: [32]u8 = undefined;
var time = gui.label("", .{

    .size = theme.small,

});
var user_icon = gui.icon(.user, theme.icon);
var user_label = gui.label("", .{

    .size = theme.small,

});
var user_parts = [_]*gui.Node{ &user_icon, &user_label };
var user = gui.box(chip, &user_parts);
var bar_parts = [_]*gui.Node{ &apps, &title, &time, &user };
var bar_root = gui.box(.{

    .padding = .axes(0, 4),
    .direction = .row,
    .gap = 4,
    .items = .stretch,

    .background = glass,

}, &bar_parts);

// Dock: one button per app, with a dot under apps that have windows.
var buttons: [catalog.apps.len]gui.Node = undefined;
var dots: [catalog.apps.len]gui.Node = undefined;
var markers: [catalog.apps.len]gui.Node = undefined;
var marker_parts: [catalog.apps.len][1]*gui.Node = undefined;
var slots: [catalog.apps.len]gui.Node = undefined;
var slot_parts: [catalog.apps.len][2]*gui.Node = undefined;
var dock_parts: [catalog.apps.len]*gui.Node = undefined;
var dock_root = gui.box(.{

    .padding = .all(margin),
    .direction = .row,
    .gap = 6,

    .background = glass,
    .border = theme.line,
    .border_width = theme.border,
    .radius = 16,

}, &dock_parts);

// Launcher: a search field over the apps that match it.
var search_bytes: [64]u8 = undefined;
var search_text = gui.Text{

    .buffer = &search_bytes,
    .placeholder = "Search apps",

};
var search = gui.input(&search_text);
var searched: u64 = 0;
var entries: [catalog.apps.len]gui.Node = undefined;
var entry_icons: [catalog.apps.len]gui.Node = undefined;
var entry_titles: [catalog.apps.len]gui.Node = undefined;
var entry_summaries: [catalog.apps.len]gui.Node = undefined;
var entry_texts: [catalog.apps.len]gui.Node = undefined;
var entry_text_parts: [catalog.apps.len][2]*gui.Node = undefined;
var entry_parts: [catalog.apps.len][2]*gui.Node = undefined;
var list_parts: [catalog.apps.len]*gui.Node = undefined;
var list = gui.box(.{

    .grow = 1,
    .gap = 2,
    .scroll = true,

}, &list_parts);
var launcher_parts = [_]*gui.Node{ &search, &list };
var launcher_root = gui.box(popup.with(.{

    .padding = gui.Edges.all(theme.spacing),
    .gap = 10,

}), &launcher_parts);

// Session menu.
const Choice = struct {

    icon: gui.Icon,
    title: []const u8,
    run: *const fn () void,

};

const choices = [_]Choice{

    .{ .icon = .lock, .title = "Lock", .run = session.lock },
    .{ .icon = .logout, .title = "Log out", .run = session.logout },
    .{ .icon = .restart, .title = "Restart", .run = restart },
    .{ .icon = .power, .title = "Shut down", .run = shutdown },

};

var choice_icons: [choices.len]gui.Node = undefined;
var choice_labels: [choices.len]gui.Node = undefined;
var choice_parts: [choices.len][2]*gui.Node = undefined;
var choice_rows: [choices.len]gui.Node = undefined;
var menu_parts: [choices.len]*gui.Node = undefined;
var menu_root = gui.box(popup, &menu_parts);

var listed: [64]api.display.Window = undefined;
var count: usize = 0;

var home_bytes: [48]u8 = undefined;
var home: []const u8 = "";
var minute: u64 = std.math.maxInt(u64);

/// Opens every surface: the wallpaper now, the rest hidden until a session starts.
pub fn init() void {

    for (catalog.apps, 0..) |app, index| {

        buttons[index] = gui.tool(app.icon, &pick);
        buttons[index].style = buttons[index].style.with(.{

            .width = slot,
            .height = slot,
            .size = 22,
            .radius = 12,

        });
        buttons[index].data = index;
        dots[index] = gui.box(.{

            .width = 4,
            .height = 4,

            .background = theme.accent,
            .radius = 2,

        }, &.{});
        marker_parts[index] = .{&dots[index]};
        markers[index] = gui.box(.{

            .padding = .{

                .bottom = 1,

            },
            .justify = .end,
            .items = .center,

        }, &marker_parts[index]);
        slot_parts[index] = .{ &buttons[index], &markers[index] };
        slots[index] = gui.box(.{

            .width = slot,
            .height = slot,
            .direction = .stack,

        }, &slot_parts[index]);
        dock_parts[index] = &slots[index];

        entry_icons[index] = gui.icon(app.icon, theme.icon.with(.{

            .width = 32,
            .size = 22,

        }));
        entry_titles[index] = gui.label(app.title, .{});
        entry_summaries[index] = gui.label(app.summary, theme.caption);
        entry_text_parts[index] = .{ &entry_titles[index], &entry_summaries[index] };
        entry_texts[index] = gui.box(.{

            .gap = 2,
            .justify = .center,

        }, &entry_text_parts[index]);
        entry_parts[index] = .{ &entry_icons[index], &entry_texts[index] };
        entries[index] = gui.box(theme.item.with(.{

            .height = 54,

        }), &entry_parts[index]);
        entries[index].action = &open;
        entries[index].data = index;
        list_parts[index] = &entries[index];

    }

    for (choices, 0..) |choice, index| {

        choice_icons[index] = gui.icon(choice.icon, theme.icon);
        choice_labels[index] = gui.label(choice.title, .{});
        choice_parts[index] = .{ &choice_icons[index], &choice_labels[index] };
        choice_rows[index] = gui.box(theme.item, &choice_parts[index]);
        choice_rows[index].action = &choose;
        choice_rows[index].data = index;
        menu_parts[index] = &choice_rows[index];

    }

    apps.action = &toggle;
    user.action = &reveal;
    search.action = &first;

    const screen = while (true) break gui.screen() catch {

        api.sleep(50);
        continue;

    };

    backdrop = gui.Image.init(@intCast(screen.width), @intCast(screen.height)) catch api.exit(3);
    backdrop.fit = .cover;
    granite(&backdrop);
    backdrop.publish() catch {

    };

    wallpaper = gui.Window.open(&scenery, .{

        .layer = .background,

    }) catch api.exit(3);
    bar = gui.Window.open(&bar_root, .{

        .layer = .panel,
        .width = screen.width,
        .height = height,
        .hidden = true,

    }) catch api.exit(3);
    dock = gui.Window.open(&dock_root, .{

        .layer = .panel,
        .width = 1,
        .height = 1,
        .hidden = true,

    }) catch api.exit(3);
    launcher = gui.Window.open(&launcher_root, .{

        .layer = .panel,
        .x = margin,
        .y = height + margin,
        .width = 440,
        .height = 420,
        .hidden = true,
        .motion = .drop,

    }) catch api.exit(3);
    menu = gui.Window.open(&menu_root, .{

        .layer = .panel,
        .width = 200,
        .height = @intCast(choices.len * 34 + 12 + (choices.len - 1) * 2),
        .hidden = true,
        .motion = .drop,

    }) catch api.exit(3);

    place(screen);

}

/// Every surface, for the event loop.
pub fn windows() [5]*gui.Window {

    return .{ &wallpaper, &bar, &dock, &launcher, &menu };

}

/// Shows the desktop for `name`, whose home is `/home/NAME`.
pub fn start(name: []const u8) void {

    home = std.fmt.bufPrint(&home_bytes, "/home/{s}", .{name}) catch "/";
    user_label.content.label = name;
    minute = std.math.maxInt(u64);

    bar.show();
    dock.show();
    gui.display.reserve(height, slot + 4 * margin) catch {

    };
    reload();
    refresh();

}

/// Hides the desktop when the session ends.
pub fn stop() void {

    dismiss();
    bar.hide();
    dock.hide();
    gui.display.reserve(0, 0) catch {

    };

    if (backdrop.width != wallpaper.surface.list.width or backdrop.height != wallpaper.surface.list.height) replace(null);

}

/// Keeps the clock and the launcher's search current; call it every pass of the event loop.
pub fn tick() void {

    // The search field takes its own keys, so a changed text is how typing shows.
    if (search_text.version != searched) filter();

    const now = api.clock();
    if (now / 60 == minute or bar.surface.hidden) return;

    const date = api.Date.init(now);

    minute = now / 60;
    time.content.label = std.fmt.bufPrint(&time_bytes, "{s} {d} {s}   {d:0>2}:{d:0>2}", .{ days[date.weekday], date.day, months[date.month - 1], date.hour, date.minute }) catch "";
    bar.refresh();

}

/// Handles input the desktop's surfaces did not; true when it was theirs.
pub fn react(input: gui.Input) bool {

    const event = input.event;
    const window = input.window;

    if (window != &wallpaper and window != &bar and window != &dock and window != &launcher and window != &menu) return false;

    switch (event.kind) {

        .notice => refresh(),
        .resize => if (window == &wallpaper) place(.{

            .width = event.x,
            .height = event.y,

        }),
        .button => if (event.pressed and window == &wallpaper) dismiss(),
        .key => {

            if (!event.pressed) return true;

            if (event.key() == .escape) {

                dismiss();

            } else if (event.modifiers.super and event.key() == .character) {

                switch (event.char | 0x20) {

                    ' ', 'a' => toggle(&apps),
                    'l' => session.lock(),
                    's' => screenshot(),
                    'e' => start_app(.explorer, home),
                    't' => start_app(.terminal, home),
                    else => {

                    },

                }

            } else if (event.modifiers.super and event.key() == .tab) {

                cycle();

            }

        },
        else => {

        },

    }

    return true;

}

/// Answers apps the session launched, such as Settings asking for the wallpaper to reload.
pub fn serve() void {

    while (true) {

        const request = api.receive(false) catch return;
        const known = protocol.operation(request.second) == .reload;

        if (known) reload();
        api.reply(request, if (known) 0 else protocol.invalid) catch {

        };

    }

}

/// Puts the bar, dock, and menus where a `screen`-sized display wants them.
fn place(screen: gui.Rect) void {

    const width = catalog.apps.len * slot + (catalog.apps.len - 1) * 6 + 2 * margin;
    const tall = slot + 2 * margin;

    bar.move(.{

        .width = screen.width,
        .height = height,

    });
    dock.move(.{

        .x = @divTrunc(screen.width - @as(i32, width), 2),
        .y = screen.height - tall - margin,
        .width = width,
        .height = tall,

    });

    var area = menu.surface.list.bounds();

    area.x = screen.width - area.width - margin;
    area.y = height + margin;
    menu.move(area);

}

/// Reads the window list again and updates the dock's dots and the bar's title.
fn refresh() void {

    count = gui.display.windows(&listed) catch 0;
    title.content.label = "";

    for (catalog.apps, 0..) |app, index| {

        dots[index].hidden = true;

        for (listed[0..count]) |window| {

            if (window.application == @intFromEnum(app.image)) dots[index].hidden = false;

        }

    }

    for (listed[0..count]) |*window| {

        if (window.state.focused) title.content.label = window.name();

    }

    // A window taking focus means the pointer went elsewhere, so open menus close.
    if (focused() != null) dismiss();

    bar.refresh();
    dock.refresh();

}

fn focused() ?*const api.display.Window {

    for (listed[0..count]) |*window| {

        if (window.state.focused) return window;

    }

    return null;

}

/// Starts app `image` on `argument`, or brings its windows forward from the dock.
fn pick(node: *gui.Node) void {

    const app = catalog.apps[node.data];
    var newest: ?*const api.display.Window = null;
    var oldest: ?*const api.display.Window = null;

    dismiss();

    for (listed[0..count]) |*window| {

        if (window.application != @intFromEnum(app.image)) continue;

        if (oldest == null) oldest = window;
        newest = window;

    }

    const top = newest orelse return start_app(app.image, home);
    const current = focused();

    // Clicking the app already in front shows its next window, or tucks away its only one.
    if (current != null and current.?.application == @intFromEnum(app.image) and !top.state.minimized) {

        if (oldest.? == top) gui.display.activate(top.id, .minimize) catch {

        } else gui.display.activate(oldest.?.id, .raise) catch {

        };

        return;

    }

    gui.display.activate(top.id, .raise) catch {

    };

}

/// Raises the bottom window, so repeated presses walk through them all.
fn cycle() void {

    if (count == 0) return;

    gui.display.activate(listed[0].id, .raise) catch {

    };

}

fn start_app(image: api.abi.Image, argument: []const u8) void {

    dismiss();
    _ = api.launch(@tagName(image), argument) catch {

    };

}

fn open(node: *gui.Node) void {

    start_app(catalog.apps[node.data].image, home);

}

/// Launches the first app the search still shows.
fn first(_: *gui.Node) void {

    for (&entries) |*entry| {

        if (!entry.hidden) return open(entry);

    }

}

fn filter() void {

    const query = search_text.text();

    searched = search_text.version;

    for (catalog.apps, 0..) |app, index| {

        entries[index].hidden = query.len != 0 and std.ascii.indexOfIgnoreCase(app.title, query) == null and std.ascii.indexOfIgnoreCase(app.summary, query) == null;

    }

    launcher.refresh();

}

fn toggle(_: *gui.Node) void {

    if (!launcher.surface.hidden) return dismiss();

    dismiss();
    search_text.clear();
    filter();
    apps.selected = true;
    launcher.show();
    launcher.focus(&search);
    bar.refresh();

}

fn reveal(_: *gui.Node) void {

    if (!menu.surface.hidden) return dismiss();

    dismiss();
    user.selected = true;
    menu.show();
    bar.refresh();

}

/// Closes the launcher and the session menu.
pub fn dismiss() void {

    if (!launcher.surface.hidden) launcher.hide();
    if (!menu.surface.hidden) menu.hide();

    apps.selected = false;
    user.selected = false;
    bar.refresh();

}

fn choose(node: *gui.Node) void {

    dismiss();
    choices[node.data].run();

}

var saved_bytes: [96]u8 = undefined;

/// Saves the screen as `~/Screenshot DATE.png` and says so in the bar.
fn screenshot() void {

    var arena = std.heap.ArenaAllocator.init(api.pages);
    defer arena.deinit();

    const allocator = arena.allocator();
    const area = wallpaper.surface.list.bounds();
    const pixels = allocator.alloc(u32, @intCast(area.width * area.height)) catch return;
    const size = gui.display.capture(pixels) catch return;
    const bytes = gui.png.encode(allocator, pixels, @intCast(size.width), @intCast(size.height)) catch return;
    const date = api.Date.init(api.clock());
    var path_bytes: [128]u8 = undefined;
    const name = std.fmt.bufPrint(&saved_bytes, "Screenshot {d}-{d:0>2}-{d:0>2} {d:0>2}.{d:0>2}.{d:0>2}.png", .{ date.year, date.month, date.day, date.hour, date.minute, date.second }) catch return;
    const path = std.fmt.bufPrint(&path_bytes, "{s}/{s}", .{ home, name }) catch return;

    files.save(allocator, path, bytes) catch {

        title.content.label = "Could not save the screenshot.";
        return bar.refresh();

    };

    title.content.label = name;
    bar.refresh();

}

fn restart() void {

    _ = api.call(0, protocol.pack(.power, 0)) catch {

    };

}

fn shutdown() void {

    _ = api.call(0, protocol.pack(.power, 1)) catch {

    };

}

/// Shows the wallpaper the user chose in Settings, or granite when there is none or it will not load.
fn reload() void {

    var path_bytes: [256]u8 = undefined;
    const path = preference(&path_bytes) orelse return replace(null);

    replace(path);

}

/// The wallpaper path saved in `~/.desktop` as `wallpaper=PATH`.
fn preference(out: []u8) ?[]const u8 {

    var name_bytes: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_bytes, "{s}/.desktop", .{home}) catch return null;
    const bytes = files.read(name, 0, files.window.len) catch return null;
    var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");

    while (lines.next()) |line| {

        if (!std.mem.startsWith(u8, line, "wallpaper=") or line.len - 10 > out.len) continue;

        @memcpy(out[0 .. line.len - 10], line[10..]);

        return out[0 .. line.len - 10];

    }

    return null;

}

/// Swaps the backdrop for the PNG at `path`, or fresh granite when null or unreadable.
fn replace(path: ?[]const u8) void {

    var arena = std.heap.ArenaAllocator.init(api.pages);
    defer arena.deinit();

    const screen = wallpaper.surface.list.bounds();
    var next = load(arena.allocator(), path orelse "") catch blk: {

        var fresh = gui.Image.init(@intCast(screen.width), @intCast(screen.height)) catch return;

        granite(&fresh);
        break :blk fresh;

    };

    next.fit = .cover;
    next.publish() catch {

        next.deinit();
        return;

    };

    backdrop.deinit();
    backdrop = next;
    wallpaper.refresh();
    session.redraw();

}

fn load(allocator: std.mem.Allocator, path: []const u8) !gui.Image {

    if (path.len == 0) return error.Missing;

    const bytes = try files.load(allocator, path);
    const size = try gui.png.size(bytes);
    var picture = try gui.Image.init(size.width, size.height);

    errdefer picture.deinit();
    _ = try gui.png.decode(allocator, bytes, picture.pixels());

    return picture;

}

/// Paints dark granite: light falling from the top left over mottled stone, flecked lighter and darker.
pub fn granite(picture: *gui.Image) void {

    const pixels = picture.pixels();
    const width: f32 = @floatFromInt(picture.width);
    const tall: f32 = @floatFromInt(picture.height);

    for (0..picture.height) |y| {

        for (0..picture.width) |x| {

            const fx: f32 = @floatFromInt(x);
            const fy: f32 = @floatFromInt(y);
            const light = 1 - (fx / width * 0.55 + fy / tall * 0.45);
            const stone = noise(fx / 240, fy / 240) * 9 + noise(fx / 70, fy / 70) * 5;
            const grain = noise(fx / 1.7 + 91, fy / 1.7 + 17);
            const fleck: f32 = if (grain > 0.7) 34 * (grain - 0.7) / 0.3 else if (grain < -0.75) -6 else 0;
            const level = std.math.clamp(19 + 22 * light * light + stone + fleck, 0, 255);
            const value: u32 = @intFromFloat(level);

            pixels[y * picture.width + x] = 0xff000000 | value << 16 | value << 8 | value;

        }

    }

}

/// Smooth value noise in -1..1 over a lattice of random heights.
fn noise(x: f32, y: f32) f32 {

    const left = @floor(x);
    const top = @floor(y);
    const u = smooth(x - left);
    const v = smooth(y - top);
    const column: i32 = @intFromFloat(left);
    const row: i32 = @intFromFloat(top);

    const upper = lattice(column, row) + (lattice(column + 1, row) - lattice(column, row)) * u;
    const lower = lattice(column, row + 1) + (lattice(column + 1, row + 1) - lattice(column, row + 1)) * u;

    return upper + (lower - upper) * v;

}

fn smooth(t: f32) f32 {

    return t * t * (3 - 2 * t);

}

fn lattice(x: i32, y: i32) f32 {

    var hash = @as(u32, @bitCast(x)) *% 0x9e3779b1 ^ @as(u32, @bitCast(y)) *% 0x85ebca77;

    hash = (hash ^ (hash >> 15)) *% 0x2c1b3c6d;
    hash = (hash ^ (hash >> 12)) *% 0x297a2d39;
    hash ^= hash >> 15;

    return @as(f32, @floatFromInt(hash & 0xffff)) / 32767.5 - 1;

}
