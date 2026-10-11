//! Clock: an analog face for local time, the time in cities around the world, a stopwatch with laps, and a countdown timer that notifies when it runs out.

const std = @import("std");

const catalog = @import("catalog.zig");

const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;
const time = api.time;
pub const panic = api.panic;

/// Ticks in a second.
const second = 100;

const Tab = enum {

    clock,
    world,
    stopwatch,
    timer,

};

const tab_icons = [_]gui.Icon{ .clock, .globe, .timer, .hourglass };
const tab_titles = [_][]const u8{ "Clock", "World", "Stopwatch", "Timer" };

var window: gui.Window = undefined;
var files = api.Files{};
var tab = Tab.clock;

var home_bytes: [64]u8 = undefined;
var home: []const u8 = "";

var tab_nodes: [tab_titles.len]gui.Node = undefined;
var tab_marks: [tab_titles.len]gui.Node = undefined;
var tab_labels: [tab_titles.len]gui.Node = undefined;
var tab_parts: [tab_titles.len][2]*gui.Node = undefined;
var tab_list: [tab_titles.len]*gui.Node = undefined;
var tabs = gui.box(theme.bar.with(.{

    .gap = 4,

}), &tab_list);

// Clock: the face, and the time and date in words.
var dial = gui.Figure{

    .paint = &face,

};
var dial_node: gui.Node = undefined;
var digital_bytes: [16]u8 = undefined;
var digital = gui.label("", .{

    .face = .mono,
    .size = 34,
    .text_align = .center,

});
var date_bytes: [48]u8 = undefined;
var date = gui.label("", theme.caption.with(.{

    .text_align = .center,

}));
var clock_parts = [_]*gui.Node{ &dial_node, &digital, &date };
var clock_page = gui.box(.{

    .grow = 1,
    .padding = .all(theme.spacing),
    .gap = 4,

}, &clock_parts);

// World: cities by their offset from UTC and their daylight saving rule, and the user's own offset.
const Rule = enum {

    none,

    /// Second Sunday of March to first Sunday of November.
    america,

    /// Last Sunday of March to last Sunday of October.
    europe,

    /// First Sunday of October to first Sunday of April.
    australia,

    /// Last Sunday of September to first Sunday of April.
    zealand,

};

const City = struct {

    name: []const u8,

    /// Minutes ahead of UTC outside daylight saving.
    offset: i32,
    rule: Rule = .none,

};

const cities = [_]City{

    .{ .name = "Honolulu", .offset = -600 },
    .{ .name = "Los Angeles", .offset = -480, .rule = .america },
    .{ .name = "Chicago", .offset = -360, .rule = .america },
    .{ .name = "New York", .offset = -300, .rule = .america },
    .{ .name = "S\u{00e3}o Paulo", .offset = -180 },
    .{ .name = "London", .offset = 0, .rule = .europe },
    .{ .name = "Paris", .offset = 60, .rule = .europe },
    .{ .name = "Athens", .offset = 120, .rule = .europe },
    .{ .name = "Dubai", .offset = 240 },
    .{ .name = "Mumbai", .offset = 330 },
    .{ .name = "Singapore", .offset = 480 },
    .{ .name = "Tokyo", .offset = 540 },
    .{ .name = "Sydney", .offset = 600, .rule = .australia },
    .{ .name = "Auckland", .offset = 720, .rule = .zealand },

};

/// Minutes the system clock runs ahead of UTC, as the user set it.
var offset: i32 = 0;

var zone_label = gui.label("Your time zone", .{

    .grow = 1,

});
var zone_bytes: [16]u8 = undefined;
var zone = gui.label("", .{

    .face = .mono,
    .size = theme.small,

});
var zone_down = gui.tool(.minimize, &zone_earlier);
var zone_up = gui.tool(.plus, &zone_later);
var zone_parts = [_]*gui.Node{ &zone_label, &zone, &zone_down, &zone_up };
var zone_row = gui.box(theme.panel.with(.{

    .padding = gui.Edges.axes(4, theme.spacing),
    .direction = .row,
    .gap = 4,
    .items = .center,

}), &zone_parts);

var city_names: [cities.len]gui.Node = undefined;
var city_notes: [cities.len]gui.Node = undefined;
var city_note_bytes: [cities.len][40]u8 = undefined;
var city_words: [cities.len][2]*gui.Node = undefined;
var city_texts: [cities.len]gui.Node = undefined;
var city_times: [cities.len]gui.Node = undefined;
var city_time_bytes: [cities.len][8]u8 = undefined;
var city_parts: [cities.len][2]*gui.Node = undefined;
var city_rows: [cities.len]gui.Node = undefined;
var city_list: [cities.len]*gui.Node = undefined;
var city_table = gui.box(.{

    .grow = 1,
    .gap = 2,
    .scroll = true,

}, &city_list);
var world_parts = [_]*gui.Node{ &zone_row, &city_table };
var world_page = gui.box(.{

    .grow = 1,
    .padding = .all(theme.spacing),
    .gap = theme.gap,

}, &world_parts);

// Stopwatch: the time run so far, and laps, newest first.
var watch_started: u64 = 0;
var watch_banked: u64 = 0;
var watch_running = false;

const lap_most = 50;

var laps: [lap_most]u64 = undefined;
var lap_count: usize = 0;

var watch_bytes: [16]u8 = undefined;
var watch = gui.label("00:00.00", .{

    .face = .mono,
    .size = 52,
    .text_align = .center,

});
var watch_go = gui.button("Start", &watch_toggle);
var watch_lap = gui.button("Lap", &watch_mark);
var watch_button_parts = [_]*gui.Node{ &watch_lap, &watch_go };
var watch_buttons = gui.box(.{

    .direction = .row,
    .gap = theme.gap,
    .justify = .center,

}, &watch_button_parts);
var lap_rows: [lap_most]gui.Node = undefined;
var lap_bytes: [lap_most][48]u8 = undefined;
var lap_list: [lap_most]*gui.Node = undefined;
var lap_table = gui.box(.{

    .grow = 1,
    .gap = 2,
    .scroll = true,

}, &lap_list);
var watch_parts = [_]*gui.Node{ &watch, &watch_buttons, &lap_table };
var watch_page = gui.box(.{

    .grow = 1,
    .padding = .all(theme.spacing),
    .gap = theme.spacing,

}, &watch_parts);

// Timer: a length to count down, the ring showing what is left, and quick lengths.
const presets = [_]u32{ 1, 3, 5, 10, 15, 25, 30, 60 };

var timer_length: u64 = 5 * 60 * second;
var timer_left: u64 = 5 * 60 * second;
var timer_due: u64 = 0;
var timer_running = false;

/// The timer ran out, and says so until reset.
var timer_done = false;

var ring = gui.Figure{

    .paint = &progress,

};
var ring_node: gui.Node = undefined;
var left_bytes: [16]u8 = undefined;
var length_text_bytes: [16]u8 = undefined;
var left_label = gui.label("05:00", .{

    .face = .mono,
    .size = 40,
    .text_align = .center,

});
var length_bytes: [24]u8 = undefined;
var length_label = gui.label("", theme.caption.with(.{

    .text_align = .center,

}));
var readout_parts = [_]*gui.Node{ &left_label, &length_label };
var readout = gui.box(.{

    .gap = 2,
    .justify = .center,

}, &readout_parts);
var dial_stack_parts = [_]*gui.Node{ &ring_node, &readout };
var dial_stack = gui.box(.{

    .grow = 1,
    .direction = .stack,

}, &dial_stack_parts);
var less = gui.tool(.minimize, &timer_less);
var timer_go = gui.button("Start", &timer_toggle);
var timer_reset = gui.button("Reset", &timer_clear);
var more = gui.tool(.plus, &timer_more);
var timer_button_parts = [_]*gui.Node{ &less, &timer_reset, &timer_go, &more };
var timer_buttons = gui.box(.{

    .direction = .row,
    .gap = theme.gap,
    .justify = .center,
    .items = .center,

}, &timer_button_parts);
var preset_nodes: [presets.len]gui.Node = undefined;
var preset_bytes: [presets.len][8]u8 = undefined;
var preset_list: [presets.len]*gui.Node = undefined;
var preset_row = gui.box(.{

    .direction = .row,
    .gap = 4,
    .justify = .center,

}, &preset_list);
var timer_parts = [_]*gui.Node{ &dial_stack, &timer_buttons, &preset_row };
var timer_page = gui.box(.{

    .grow = 1,
    .padding = .all(theme.spacing),
    .gap = theme.spacing,

}, &timer_parts);

var pages = [_]*gui.Node{ &clock_page, &world_page, &watch_page, &timer_page };
var page_box = gui.box(.{

    .grow = 1,

}, &pages);
var root_parts = [_]*gui.Node{ &tabs, &page_box };
var root = gui.box(.{}, &root_parts);

/// The second last shown, so the clock and world pages change once a second.
var shown_second: u64 = 0;

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .application);

    var argument_bytes: [256]u8 = undefined;

    home = std.fmt.bufPrint(&home_bytes, "{s}", .{catalog.home(api.argument(&argument_bytes)) orelse ""}) catch "";
    load();

    dial_node = gui.figure(&dial, .{

        .grow = 1,

    });
    ring_node = gui.figure(&ring, .{

        .grow = 1,

    });

    for (&tab_nodes, 0..) |*node, index| {

        tab_marks[index] = gui.icon(tab_icons[index], theme.icon);
        tab_labels[index] = gui.label(tab_titles[index], .{

            .size = theme.small,

        });
        tab_parts[index] = .{ &tab_marks[index], &tab_labels[index] };
        node.* = gui.box(theme.item.with(.{

            .grow = 1,
            .height = 32,
            .gap = 6,
            .justify = .center,

        }), &tab_parts[index]);
        node.action = &choose;
        node.data = index;
        tab_list[index] = node;

    }

    for (cities, 0..) |city, index| {

        city_names[index] = gui.label(city.name, .{});
        city_notes[index] = gui.label("", theme.caption);
        city_words[index] = .{ &city_names[index], &city_notes[index] };
        city_texts[index] = gui.box(.{

            .grow = 1,
            .gap = 2,
            .justify = .center,

        }, &city_words[index]);
        city_times[index] = gui.label("", .{

            .face = .mono,
            .size = 22,

        });
        city_parts[index] = .{ &city_texts[index], &city_times[index] };
        city_rows[index] = gui.box(theme.item.with(.{

            .height = 52,

        }), &city_parts[index]);
        city_list[index] = &city_rows[index];

    }

    for (&lap_rows, 0..) |*row, index| {

        row.* = gui.label("", theme.item.with(.{

            .height = 30,
            .face = .mono,
            .size = theme.small,

        }));
        row.hidden = true;
        lap_list[index] = row;

    }

    for (presets, 0..) |minutes, index| {

        preset_nodes[index] = gui.button(std.fmt.bufPrint(&preset_bytes[index], "{d}m", .{minutes}) catch "", &preset);
        preset_nodes[index].style = preset_nodes[index].style.with(.{

            .padding = gui.Edges.axes(0, 10),
            .size = theme.small,

        });
        preset_nodes[index].data = minutes;
        preset_list[index] = &preset_nodes[index];

    }

    timer_go.style = theme.primary;
    watch_go.style = theme.primary;
    watch_lap.style = watch_lap.style.with(.{

        .width = 96,

    });
    watch_go.style = watch_go.style.with(.{

        .width = 96,

    });
    for (&pages, 0..) |page, index| page.hidden = index != 0;
    tab_nodes[0].selected = true;

    window = gui.Window.open(&root, .{

        .title = "Clock",
        .application = .clock,
        .width = 400,
        .height = 520,

    }) catch api.exit(3);

    show(.clock);

    while (true) {

        const now = api.ticks();

        tick(now);

        const event = window.next(wait(now)) orelse continue;

        if (event.kind == .close) window.quit();

    }

}

/// Ticks until something on the screen next changes, or the timer runs out.
fn wait(now: u64) u64 {

    var result: u64 = 25;

    if (tab == .stopwatch and watch_running) result = 3;
    if (timer_running) result = @min(result, timer_due -| now + 1);

    return @max(result, 1);

}

/// Moves whatever runs on to `now`, redrawing only what changed.
fn tick(now: u64) void {

    if (timer_running and now >= timer_due) finish();

    switch (tab) {

        .clock, .world => {

            const seconds = api.clock();
            if (seconds == shown_second) return;

            shown_second = seconds;
            if (tab == .clock) clock_fill(seconds) else world_fill(seconds);

        },
        .stopwatch => if (watch_running) watch_fill(now),
        .timer => if (timer_running) timer_fill(now),

    }

}

fn show(which: Tab) void {

    tab = which;
    shown_second = 0;

    for (&tab_nodes, &pages, 0..) |*node, page, index| {

        node.selected = index == @intFromEnum(which);
        page.hidden = !node.selected;

    }

    watch_fill(api.ticks());
    timer_fill(api.ticks());

}

fn choose(node: *gui.Node) void {

    show(@enumFromInt(node.data));
    tick(api.ticks());

}

// Clock.

fn clock_fill(seconds: u64) void {

    const today = api.Date.init(seconds);

    digital.content.label = std.fmt.bufPrint(&digital_bytes, "{d:0>2}:{d:0>2}:{d:0>2}", .{ today.hour, today.minute, today.second }) catch "";
    date.content.label = std.fmt.bufPrint(&date_bytes, "{s}, {d} {s} {d}", .{ time.days[today.weekday], today.day, time.months[today.month - 1], today.year }) catch "";
    dial.invalidate();
    window.refresh();

}

/// Paints the face: a disc with minute and hour marks, and the hands at the current time.
fn face(_: *gui.Figure, target: *gui.Sketch) void {

    const width: f32 = @floatFromInt(target.width);
    const height: f32 = @floatFromInt(target.height);
    const x = width / 2;
    const y = height / 2;
    const radius = @min(width, height) / 2 - 6;

    if (radius < 24) return;

    const now = api.Date.init(api.clock());
    const minutes = @as(f32, @floatFromInt(now.minute)) + @as(f32, @floatFromInt(now.second)) / 60;
    const hours = @as(f32, @floatFromInt(now.hour % 12)) + minutes / 60;

    target.disc(x, y, radius, theme.raised);
    target.ring(x, y, radius - 0.75, 1.5, theme.line);

    for (0..60) |mark| {

        const major = mark % 5 == 0;
        const outer = radius * 0.9;
        const inner = outer - radius * @as(f32, if (major) 0.1 else 0.04);

        spoke(target, x, y, @as(f32, @floatFromInt(mark)) / 60, inner, outer, if (major) 2.4 else 1.2, if (major) theme.text else theme.faint);

    }

    spoke(target, x, y, hours / 12, -radius * 0.08, radius * 0.5, 5, theme.text);
    spoke(target, x, y, minutes / 60, -radius * 0.08, radius * 0.74, 3.5, theme.text);
    spoke(target, x, y, @as(f32, @floatFromInt(now.second)) / 60, -radius * 0.14, radius * 0.82, 1.5, theme.muted);
    target.disc(x, y, 5, theme.text);
    target.disc(x, y, 2, theme.raised);

}

/// A line along turn `turn` of a circle centred at (`x`, `y`), from `inner` to `outer` pixels out.
fn spoke(target: *gui.Sketch, x: f32, y: f32, turn: f32, inner: f32, outer: f32, width: f32, color: u32) void {

    const sine = @sin(turn * std.math.tau);
    const cosine = @cos(turn * std.math.tau);

    target.line(x + sine * inner, y - cosine * inner, x + sine * outer, y - cosine * outer, width, color);

}

// World.

fn world_fill(seconds: u64) void {

    const utc: i64 = @as(i64, @intCast(seconds)) - @as(i64, offset) * 60;
    const today = api.Date.init(seconds);

    zone.content.label = utc_text(&zone_bytes, offset);

    for (cities, 0..) |city, index| {

        const minutes = city.offset + if (summer(city, utc)) @as(i32, 60) else 0;
        const there = api.Date.init(@intCast(@max(utc + @as(i64, minutes) * 60, 0)));
        const difference = minutes - offset;
        const day = if (there.day == today.day) "Today" else if (there.year > today.year or (there.year == today.year and (there.month > today.month or (there.month == today.month and there.day > today.day)))) "Tomorrow" else "Yesterday";

        city_times[index].content.label = std.fmt.bufPrint(&city_time_bytes[index], "{d:0>2}:{d:0>2}", .{ there.hour, there.minute }) catch "";
        city_notes[index].content.label = if (difference == 0) std.fmt.bufPrint(&city_note_bytes[index], "{s}, same time", .{day}) catch "" else std.fmt.bufPrint(&city_note_bytes[index], "{s}, {s}{d}{s} h", .{

            day,
            if (difference > 0) "+" else "\u{2212}",
            @abs(difference) / 60,
            if (@mod(@abs(difference), 60) == 30) ".5" else if (@mod(@abs(difference), 60) == 45) ".75" else "",

        }) catch "";

    }

    window.refresh();

}

/// Whether `city` keeps daylight saving at `utc` seconds, judged by its standard date; changes land within a day of the true hour.
fn summer(city: City, utc: i64) bool {

    if (city.rule == .none) return false;

    const local = api.Date.init(@intCast(@max(utc + @as(i64, city.offset) * 60, 0)));
    const day = @as(u16, local.month) * 100 + local.day;

    return switch (city.rule) {

        .none => false,
        .america => day >= 300 + sunday(local.year, 3, 2) and day < 1100 + sunday(local.year, 11, 1),
        .europe => day >= 300 + last_sunday(local.year, 3) and day < 1000 + last_sunday(local.year, 10),
        .australia => day >= 1000 + sunday(local.year, 10, 1) or day < 400 + sunday(local.year, 4, 1),
        .zealand => day >= 900 + last_sunday(local.year, 9) or day < 400 + sunday(local.year, 4, 1),

    };

}

/// The day of the `nth` Sunday of `month`.
fn sunday(year: u16, month: u8, nth: u8) u16 {

    const first = time.weekday(year, month, 1);

    return 1 + (7 - first) % 7 + (nth - 1) * 7;

}

fn last_sunday(year: u16, month: u8) u16 {

    const last = time.length(year, month);

    return last - time.weekday(year, month, last);

}

fn utc_text(out: []u8, minutes: i32) []const u8 {

    if (minutes == 0) return "UTC";

    return std.fmt.bufPrint(out, "UTC{s}{d}{s}", .{

        if (minutes > 0) "+" else "\u{2212}",
        @abs(minutes) / 60,
        if (@mod(@abs(minutes), 60) == 30) ":30" else if (@mod(@abs(minutes), 60) == 45) ":45" else "",

    }) catch "";

}

fn zone_earlier(_: *gui.Node) void {

    move_zone(-30);

}

fn zone_later(_: *gui.Node) void {

    move_zone(30);

}

fn move_zone(by: i32) void {

    offset = std.math.clamp(offset + by, -12 * 60, 14 * 60);
    save();
    world_fill(api.clock());

}

/// Reads the offset saved in `~/.clock` as `offset=MINUTES`.
fn load() void {

    var path_bytes: [96]u8 = undefined;
    const path = std.fmt.bufPrint(&path_bytes, "{s}/.clock", .{home}) catch return;
    const bytes = files.read(path, 0, files.window.len) catch return;
    var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");

    while (lines.next()) |line| {

        if (std.mem.startsWith(u8, line, "offset=")) offset = std.math.clamp(std.fmt.parseInt(i32, line[7..], 10) catch 0, -12 * 60, 14 * 60);

    }

}

fn save() void {

    var path_bytes: [96]u8 = undefined;
    var line_bytes: [32]u8 = undefined;
    const path = std.fmt.bufPrint(&path_bytes, "{s}/.clock", .{home}) catch return;
    const line = std.fmt.bufPrint(&line_bytes, "offset={d}\n", .{offset}) catch return;

    files.create(path) catch return;
    files.write(path, 0, line) catch {

    };

}

// Stopwatch.

fn watch_elapsed(now: u64) u64 {

    return watch_banked + if (watch_running) now - watch_started else 0;

}

fn watch_fill(now: u64) void {

    watch.content.label = span(&watch_bytes, watch_elapsed(now), true);
    watch_go.content.label = if (watch_running) "Stop" else if (watch_elapsed(now) == 0) "Start" else "Resume";
    watch_lap.content.label = if (watch_running or watch_elapsed(now) == 0) "Lap" else "Reset";
    window.refresh();

}

fn watch_toggle(_: *gui.Node) void {

    const now = api.ticks();

    if (watch_running) watch_banked += now - watch_started else watch_started = now;
    watch_running = !watch_running;
    watch_fill(now);

}

/// Marks a lap while running; resets once stopped.
fn watch_mark(_: *gui.Node) void {

    const now = api.ticks();

    if (!watch_running) {

        watch_banked = 0;
        lap_count = 0;
        for (&lap_rows) |*row| row.hidden = true;

        return watch_fill(now);

    }

    const total = watch_elapsed(now);
    var index: usize = @min(lap_count, lap_most - 1);

    while (index > 0) : (index -= 1) laps[index] = laps[index - 1];

    laps[0] = total;
    lap_count = @min(lap_count + 1, lap_most);

    for (0..lap_count) |row| {

        const lap = laps[row] - if (row + 1 < lap_count) laps[row + 1] else 0;
        var lap_text: [16]u8 = undefined;
        var total_text: [16]u8 = undefined;

        lap_rows[row].content.label = std.fmt.bufPrint(&lap_bytes[row], "Lap {d: <4}  {s}   {s}", .{ lap_count - row, span(&lap_text, lap, true), span(&total_text, laps[row], true) }) catch "";
        lap_rows[row].hidden = false;

    }

    watch_fill(now);

}

// Timer.

fn timer_fill(now: u64) void {

    if (timer_running) timer_left = timer_due -| now;

    left_label.content.label = if (timer_done) "Done" else span(&left_bytes, timer_left + second - 1, false);
    length_label.content.label = std.fmt.bufPrint(&length_bytes, "of {s}", .{span(&length_text_bytes, timer_length, false)}) catch "";
    timer_go.content.label = if (timer_running) "Pause" else if (timer_left != timer_length and !timer_done) "Resume" else "Start";
    less.hidden = timer_running;
    more.hidden = timer_running;
    ring.invalidate();
    window.refresh();

}

/// Paints the ring: a faint track and an arc of what is left.
fn progress(_: *gui.Figure, target: *gui.Sketch) void {

    const width: f32 = @floatFromInt(target.width);
    const height: f32 = @floatFromInt(target.height);
    const radius = @min(width, height) / 2 - 10;

    if (radius < 24) return;

    const fraction = if (timer_length == 0) 0 else @as(f32, @floatFromInt(timer_left)) / @as(f32, @floatFromInt(timer_length));

    target.ring(width / 2, height / 2, radius, 8, theme.field);
    if (timer_done) return target.ring(width / 2, height / 2, radius, 8, theme.accent);
    target.arc(width / 2, height / 2, radius, 8, 1 - fraction, 1, theme.accent);

}

fn timer_toggle(_: *gui.Node) void {

    const now = api.ticks();

    if (timer_done) timer_clear(&timer_reset);

    if (timer_running) {

        timer_left = timer_due -| now;

    } else {

        timer_due = now + timer_left;

    }

    timer_running = !timer_running;
    timer_fill(now);

}

fn timer_clear(_: *gui.Node) void {

    timer_running = false;
    timer_done = false;
    timer_left = timer_length;
    timer_fill(api.ticks());

}

fn timer_less(_: *gui.Node) void {

    set_length(timer_length -| 60 * second);

}

fn timer_more(_: *gui.Node) void {

    set_length(timer_length + 60 * second);

}

fn preset(node: *gui.Node) void {

    set_length(node.data * 60 * second);

}

fn set_length(ticks: u64) void {

    timer_length = std.math.clamp(ticks, 60 * second, 24 * 60 * 60 * second);
    timer_running = false;
    timer_done = false;
    timer_left = timer_length;
    timer_fill(api.ticks());

}

/// The countdown ran out: says so on the ring and as a notification.
fn finish() void {

    var detail_bytes: [48]u8 = undefined;
    var length_text: [16]u8 = undefined;

    timer_running = false;
    timer_done = true;
    timer_left = 0;
    timer_fill(api.ticks());

    api.notify("Timer finished", std.fmt.bufPrint(&detail_bytes, "Your {s} timer is up.", .{span(&length_text, timer_length, false)}) catch "") catch {

    };

}

/// `ticks` as minutes and seconds, with hundredths when `fine`, and hours in front once there are any.
fn span(out: []u8, ticks: u64, fine: bool) []const u8 {

    const seconds = ticks / second;
    const hours = seconds / 3600;

    if (fine) {

        if (hours > 0) return std.fmt.bufPrint(out, "{d}:{d:0>2}:{d:0>2}.{d:0>2}", .{ hours, seconds / 60 % 60, seconds % 60, ticks % second }) catch "";

        return std.fmt.bufPrint(out, "{d:0>2}:{d:0>2}.{d:0>2}", .{ seconds / 60, seconds % 60, ticks % second }) catch "";

    }

    if (hours > 0) return std.fmt.bufPrint(out, "{d}:{d:0>2}:{d:0>2}", .{ hours, seconds / 60 % 60, seconds % 60 }) catch "";

    return std.fmt.bufPrint(out, "{d:0>2}:{d:0>2}", .{ seconds / 60, seconds % 60 }) catch "";

}
