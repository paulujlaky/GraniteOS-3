//! The signed-in desktop: wallpaper and its items, top bar, dock, app launcher, menus, notifications, window switcher,
//! clipboard history, quick settings, and snips, all surfaces of the login process.

const std = @import("std");

const about = @import("about.zig");
const catalog = @import("catalog.zig");
const clips = @import("clips.zig");
const controls = @import("controls.zig");
const dock = @import("dock.zig");
const launcher = @import("launcher.zig");
const notices = @import("notices.zig");
const pins = @import("pins.zig");
const shortcuts = @import("shortcuts.zig");
const snip = @import("snip.zig");
const switcher = @import("switcher.zig");

const api = @import("api");
const gui = @import("gui");

const protocol = api.protocol;
const session = @import("root");
const theme = gui.theme;

/// Rows the top bar keeps.
pub const height = 30;
const margin = 8;

// Children span the bar's height, so text and icons centre on their capitals rather than on their line boxes.
const chip = gui.Style{

    .padding = .axes(0, 10),
    .direction = .row,
    .gap = 7,
    .items = .stretch,

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

/// Every surface of the desktop, for the event loop.
var surfaces: [14]*gui.Window = undefined;

/// The picture behind everything, shared with the lock screen.
pub var backdrop: gui.Image = undefined;

var painting = gui.picture(&backdrop, .{

    .grow = 1,

});

var scenery_parts = [_]*gui.Node{ &painting, &shortcuts.node };

var scenery = gui.box(.{

    .direction = .stack,

}, &scenery_parts);

var files = api.Files{};

/// The `desktop` config, where Settings saves the wallpaper as `wallpaper=PATH`, and `quartz=off` when Quartz draws solid.
var preferences = api.Config{};

/// Whether Quartz shows what lies behind it, as the user chose.
var translucent = true;

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

/// The date and time, which open the quick settings.
var clock_parts = [_]*gui.Node{ &time };
var clock = gui.box(chip, &clock_parts);

var user_icon = gui.icon(.user, theme.icon);

var user_label = gui.label("", .{

    .size = theme.small,

});

var user_parts = [_]*gui.Node{ &user_icon, &user_label };
var user = gui.box(chip, &user_parts);
var bar_parts = [_]*gui.Node{ &apps, &title, &clock, &user };

var bar_root = gui.box(.{

    .padding = .axes(0, 4),
    .direction = .row,
    .gap = 4,
    .items = .stretch,

    .background = theme.quartz,
    .quartz = true,

}, &bar_parts);

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

/// The windows on the screen, bottom first, as last read.
pub var listed: [64]api.display.Window = undefined;
pub var count: usize = 0;

/// The window that had focus when the list was last read.
var leader: ?u32 = null;

var home_bytes: [48]u8 = undefined;
pub var home: []const u8 = "";
var minute: u64 = std.math.maxInt(u64);

/// The display restarts already seen.
var restarted: u64 = 0;

/// Opens every surface: the wallpaper now, the rest hidden until a session starts.
pub fn init() void {

    apps.action = &toggle;
    clock.action = &settle;
    user.action = &reveal;

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

    dock.init();

    launcher.init(.{

        .x = margin,
        .y = height + margin,

    });

    account_menu.init(null);
    desktop_menu.init(null);
    pins.init();
    shortcuts.init();
    notices.init(screen, height);
    switcher.init(screen);
    clips.init(screen);
    controls.init();
    about.init();
    snip.init();
    surfaces = .{ &wallpaper, &bar, &dock.window, &launcher.window, &account_menu.window, &desktop_menu.window, &pins.app_menu.window, &shortcuts.menu.window, &notices.window, &switcher.window, &clips.window, &controls.window, &about.window, &snip.window };

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
    dock.window.show();
    reload(.all);
    claim();
    refresh();

}

/// Keeps the rows of the bar and dock out of maximised windows' way, and Quartz as the user chose.
fn claim() void {

    gui.display.reserve(height, dock.reach) catch {

    };

    gui.display.quartz(translucent) catch {

    };

}

/// Hides the desktop when the session ends.
pub fn stop() void {

    dismiss();
    snip.cancel();
    notices.clear();
    about.hide();
    bar.hide();
    dock.window.hide();
    pins.load("");

    gui.display.reserve(0, 0) catch {

    };

    if (backdrop.width != wallpaper.surface.list.width or backdrop.height != wallpaper.surface.list.height) replace(null);

}

/// Keeps the clock and the launcher's search current; call it every pass of the event loop.
pub fn tick() void {

    launcher.tick();
    notices.tick();
    snip.tick();

    // A restarted display forgot the rows the bar keeps, so once the bar is back it keeps them again.
    if (restarted != gui.lost.* and bar.surface.attached) {

        restarted = gui.lost.*;
        claim();

    }

    controls.tick();

    const now = api.clock();
    if (now / 60 == minute or bar.surface.hidden) return;

    const date = api.Date.init(now);
    var day_bytes: [16]u8 = undefined;
    var hour_bytes: [16]u8 = undefined;

    minute = now / 60;
    time.content.label = std.fmt.bufPrint(&time_bytes, "{s}   {s}", .{ date.short(&day_bytes), date.clock(&hour_bytes, false) }) catch "";
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
        .key => {

            if (!event.pressed) return true;
            if (window == &wallpaper and !event.modifiers.super and shortcuts.react(event)) return true;

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

                reload(std.enums.fromInt(catalog.Reload, protocol.value(request.second)) orelse .all);
                break :blk 0;

            },
            .notify => notify(request),
            .snip => snip.ask(request, home),
            .pin => pins.serve(request),
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

/// Puts the bar, dock, items, and menus where a `screen`-sized display wants them.
fn place(screen: gui.Rect) void {

    bar.move(.{

        .width = screen.width,
        .height = height,

    });

    dock.place(screen);
    shortcuts.redraw();
    notices.place(screen, height);
    switcher.place(screen);
    clips.place(screen);

}

/// Reads the window list again and updates the dock and the bar's title.
fn refresh() void {

    count = gui.display.windows(&listed) catch 0;
    title.content.label = "";

    for (listed[0..count]) |*window| {

        if (window.state.focused) title.content.label = window.name();

    }

    // A window taking focus means the pointer went elsewhere, so open menus close; other changes, such as a menu opening, leave them.
    const now = if (focused()) |window| window.id else null;

    if (now != null and now != leader) dismiss();
    leader = now;

    bar.refresh();
    dock.arrange();

}

pub fn focused() ?*const api.display.Window {

    for (listed[0..count]) |*window| {

        if (window.state.focused) return window;

    }

    return null;

}

/// Whether app `image` has a window open.
pub fn running(image: api.abi.Image) bool {

    for (listed[0..count]) |*window| {

        if (window.application == @intFromEnum(image)) return true;

    }

    return false;

}

/// Raises the bottom window, so repeated presses walk through them all.
fn cycle() void {

    if (count == 0) return;

    gui.display.activate(listed[0].id, .raise) catch {

    };

}

pub fn start_app(image: api.abi.Image, argument: []const u8) void {

    dismiss();

    catalog.start(image, argument) catch {

    };

}

fn toggle(_: *gui.Node) void {

    if (launcher.shown()) return dismiss();

    dismiss();
    apps.selected = true;
    launcher.show();
    bar.refresh();

}

/// Opens the quick settings under the date and time, or closes them.
fn settle(_: *gui.Node) void {

    if (controls.shown()) return dismiss();

    dismiss();
    clock.selected = true;
    controls.show(.{ .x = wallpaper.surface.list.width - margin, .y = height + margin });
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

/// Opens the wallpaper's menu at `at`.
pub fn offer(at: gui.Point) void {

    desktop_menu.show(at);

}

/// Closes the launcher, the menus, the clipboard history, and the quick settings.
pub fn dismiss() void {

    launcher.hide();
    account_menu.hide();
    desktop_menu.hide();
    pins.app_menu.hide();
    shortcuts.menu.hide();
    clips.hide();
    controls.hide();

    apps.selected = false;
    clock.selected = false;
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

/// Shows Quartz and, unless only that changed, the wallpaper as the user chose in Settings: granite when there is none or it will
/// not load.
fn reload(what: catalog.Reload) void {

    preferences.open(user_label.content.label, "desktop");
    translucent = !std.mem.eql(u8, preferences.get("quartz") orelse "", "off");

    gui.display.quartz(translucent) catch {

    };

    if (what == .quartz) return;

    replace(preferences.get("wallpaper"));
    pins.load(user_label.content.label);

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
