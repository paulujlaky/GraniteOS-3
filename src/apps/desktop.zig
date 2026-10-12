//! The signed-in desktop: wallpaper, top bar, dock, app launcher, menus, notifications, window switcher, clipboard history, and snips, all surfaces of the login process.

const std = @import("std");

const about = @import("about.zig");
const catalog = @import("catalog.zig");
const clips = @import("clips.zig");
const notices = @import("notices.zig");
const snip = @import("snip.zig");
const switcher = @import("switcher.zig");

const api = @import("api");
const gui = @import("gui");

const protocol = api.protocol;
const session = @import("root");
const theme = gui.theme;

/// Rows the top bar keeps, and the dock's button size.
const height = 30;
const slot = 46;
const margin = 8;

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

pub var wallpaper: gui.Window = undefined;
var bar: gui.Window = undefined;
var dock: gui.Window = undefined;
var launcher: gui.Window = undefined;

/// Every surface of the desktop, for the event loop.
var surfaces: [11]*gui.Window = undefined;

/// The picture behind everything, shared with the lock screen.
pub var backdrop: gui.Image = undefined;

var painting = gui.picture(&backdrop, .{

    .grow = 1,

});

/// The area the pointer sweeps out over the wallpaper while the button is held, for picking desktop items once there are some.
var swath = gui.custom(&paint_swath, .{});
var scenery_parts = [_]*gui.Node{ &painting, &swath };

var scenery = gui.box(.{

    .direction = .stack,

}, &scenery_parts);

/// Where a sweep began and where the pointer is.
var swept: ?gui.Point = null;
var reach = gui.Point{};

var files = api.Files{};

/// The `desktop` config, where Settings saves the wallpaper as `wallpaper=PATH`.
var preferences = api.Config{};

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

    .background = theme.glass,

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

    .background = theme.glass,
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

var launcher_root = gui.box(theme.popup.with(.{

    .padding = gui.Edges.all(theme.spacing),
    .gap = 10,

}), &launcher_parts);

/// The session menu under the account name, and the wallpaper's right-click menu.
var account_menu: gui.Menu(&.{

    .{ .icon = .lock, .title = "Lock", .run = session.lock },
    .{ .icon = .logout, .title = "Log out", .run = session.logout },
    .{ .icon = .restart, .title = "Restart", .run = restart },
    .{ .icon = .power, .title = "Shut down", .run = shutdown },

}) = .{};

var desktop_menu: gui.Menu(&.{

    .{ .icon = .folder, .title = "Files", .run = files_open },
    .{ .icon = .terminal, .title = "Terminal", .run = terminal_open },
    .{ .icon = .wallpaper, .title = "Change wallpaper", .run = settings_open },
    .{ .icon = .image, .title = "Take screenshot", .hint = "Super+S", .run = screenshot },
    .{ .icon = .info, .title = "About GraniteOS", .run = about_open },

}) = .{};

var listed: [64]api.display.Window = undefined;
var count: usize = 0;

/// The window that had focus when the list was last read.
var leader: ?u32 = null;

var home_bytes: [48]u8 = undefined;
var home: []const u8 = "";
var minute: u64 = std.math.maxInt(u64);

/// The display restarts already seen.
var restarted: u64 = 0;

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

    apps.action = &toggle;
    swath.track = &sweep;
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
        .tuck = true,

    }) catch api.exit(3);

    launcher = gui.Window.open(&launcher_root, .{

        .layer = .panel,

        .x = margin,
        .y = height + margin,
        .width = 440,
        .height = 420,

        .hidden = true,
        .motion = .drop,
        .shadow = true,

    }) catch api.exit(3);

    account_menu.init(null);
    desktop_menu.init(null);
    notices.init(screen, height);
    switcher.init(screen);
    clips.init(screen);
    about.init();
    snip.init();
    surfaces = .{ &wallpaper, &bar, &dock, &launcher, &account_menu.window, &desktop_menu.window, &notices.window, &switcher.window, &clips.window, &about.window, &snip.window };

    place(screen);

}

/// Every surface, for the event loop.
pub fn windows() []const *gui.Window {

    return &surfaces;

}

/// Shows the desktop for `name`, whose home is `/home/NAME`.
pub fn start(name: []const u8) void {

    home = std.fmt.bufPrint(&home_bytes, "/home/{s}", .{name}) catch "/";
    user_label.content.label = name;
    minute = std.math.maxInt(u64);

    bar.show();
    dock.show();
    claim();
    reload();
    refresh();

}

/// Keeps the rows of the bar and dock out of maximised windows' way.
fn claim() void {

    gui.display.reserve(height, slot + 4 * margin) catch {

    };

}

/// Hides the desktop when the session ends.
pub fn stop() void {

    dismiss();
    snip.cancel();
    notices.clear();
    about.hide();
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

    notices.tick();
    snip.tick();

    // A restarted display forgot the rows the bar keeps, so once the bar is back it keeps them again.
    if (restarted != gui.lost.* and bar.surface.attached) {

        restarted = gui.lost.*;
        claim();

    }

    const now = api.clock();
    if (now / 60 == minute or bar.surface.hidden) return;

    const date = api.Date.init(now);

    minute = now / 60;
    time.content.label = std.fmt.bufPrint(&time_bytes, "{s} {d} {s}   {d:0>2}:{d:0>2}", .{ api.time.days[date.weekday][0..3], date.day, api.time.months[date.month - 1][0..3], date.hour, date.minute }) catch "";
    bar.refresh();

}

/// The most ticks the event loop may wait for input, so a delayed snip starts on time.
pub fn patience(longest: u64) u64 {

    return snip.patience(longest);

}

/// Handles input the desktop's surfaces did not; true when it was theirs.
pub fn react(input: gui.Input) bool {

    const event = input.event;
    const window = input.window;

    if (std.mem.indexOfScalar(*gui.Window, &surfaces, window) == null) return false;
    if (snip.react(input)) return true;

    // Alt+Tab reaches whichever desktop surface the display hands it to.
    if (switcher.react(event)) return true;

    switch (event.kind) {

        .notice => switch (@as(api.Event.Notice, @enumFromInt(event.code))) {

            .windows => refresh(),
            .clipboard => clips.copied(),
            _ => {

            },

        },
        .resize => if (window == &wallpaper) place(.{

            .width = event.x,
            .height = event.y,

        }),
        .close => if (window == &about.window) about.hide(),
        .button => if (event.pressed and window == &wallpaper) {

            dismiss();

            // The right button opens the wallpaper's menu where it was pressed.
            if (event.code == 1) desktop_menu.show(.{

                .x = event.x,
                .y = event.y,

            });

        },
        .key => {

            if (!event.pressed) return true;

            if (event.key() == .escape) {

                dismiss();

            } else if (event.modifiers.super and event.key() == .character) {

                switch (event.char | 0x20) {

                    ' ', 'a' => toggle(&apps),
                    'l' => session.lock(),
                    's' => snip.take(if (event.modifiers.shift) .region else .screen, home),
                    'e' => start_app(.explorer, home),
                    't' => start_app(.terminal, home),
                    'v' => {

                        const shown = !clips.window.surface.hidden;

                        dismiss();
                        if (!shown) clips.toggle();

                    },
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

/// Answers apps the session launched, such as Settings asking for the wallpaper to reload, a timer showing a notification, or Screenshots asking for a snip.
pub fn serve() void {

    while (true) {

        const request = api.receive(false) catch return;

        const result: ?u64 = switch (protocol.operation(request.second)) {

            .reload => blk: {

                reload();
                break :blk 0;

            },
            .notify => notify(request),
            .snip => snip.ask(request, home),
            else => protocol.invalid,

        };

        // A snip answers once it is saved or cancelled.
        if (result) |value| api.reply(request, value) catch {

        };

    }

}

/// Shows the notification an app sent as its title, a NUL, and its detail.
fn notify(request: api.Request) u64 {

    var bytes: [64 + 1 + 192]u8 = undefined;
    if (request.fourth > bytes.len) return protocol.invalid;

    api.fetch(request, 0, bytes[0..request.fourth]) catch return protocol.invalid;

    const message = bytes[0..request.fourth];
    const split = std.mem.indexOfScalar(u8, message, 0) orelse message.len;

    notices.post(.bell, message[0..split], message[@min(split + 1, message.len)..], null);

    return 0;

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

    notices.place(screen, height);
    switcher.place(screen);
    clips.place(screen);

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

    // A window taking focus means the pointer went elsewhere, so open menus close; other changes, such as a menu opening, leave them.
    const now = if (focused()) |window| window.id else null;

    if (now != null and now != leader) dismiss();
    leader = now;

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

    catalog.start(image, argument) catch {

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

    if (account_menu.shown()) return dismiss();

    dismiss();
    user.selected = true;

    account_menu.show(.{

        .x = wallpaper.surface.list.width,
        .y = height + margin,

    });

    bar.refresh();

}

/// Closes the launcher, the menus, and the clipboard history.
pub fn dismiss() void {

    if (!launcher.surface.hidden) launcher.hide();
    account_menu.hide();
    desktop_menu.hide();
    clips.hide();

    apps.selected = false;
    user.selected = false;
    bar.refresh();

}

fn files_open() void {

    start_app(.explorer, home);

}

fn terminal_open() void {

    start_app(.terminal, home);

}

fn settings_open() void {

    start_app(.settings, home);

}

fn about_open() void {

    about.show(user_label.content.label);

}

/// Follows a press on the wallpaper, sweeping out an area until the button comes up.
fn sweep(_: *gui.Node, track: gui.Track) void {

    const before = swept_area();

    switch (track.phase) {

        .down => {

            dismiss();
            swept = track.at;

        },
        .move => {

        },
        .up => swept = null,

    }

    reach = track.at;

    // Only around the area before and after repaints, its soft edge included.
    for ([_]?gui.Rect{ before, swept_area() }) |entry| {

        if (entry) |area| wallpaper.damage = wallpaper.damage.join(area.inset(-2));

    }

}

/// The area swept out so far, once the pointer has moved from where the press began.
fn swept_area() ?gui.Rect {

    const from = swept orelse return null;

    return if (std.meta.eql(from, reach)) null else gui.Rect.spanning(from, reach);

}

fn paint_swath(_: *gui.Node, target: *gui.List) void {

    target.sweep(swept_area() orelse return);

}

fn screenshot() void {

    snip.take(.screen, home);

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

    preferences.open(user_label.content.label, "desktop");
    replace(preferences.get("wallpaper"));

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

    return gui.Image.decode(allocator, try files.load(allocator, path));

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
