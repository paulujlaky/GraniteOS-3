//! Quick settings under the bar's date and time: the time and date, the weather where Weather last looked, a month calendar
//! to page through, and a switch for each setting, starting with the network.

const std = @import("std");

const days = @import("days.zig");
const desktop = @import("desktop.zig");
const forecast = @import("forecast.zig");

const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;
const time = api.time;
const Day = days.Day;

const width = 320;

/// A switch the panel offers: what it shows, how it reads its state into a short detail, and how it flips.
const Tile = struct {

    icon: gui.Icon,
    title: []const u8,

    /// Whether it is on, with its detail written into `bytes`; null hides the switch, as when there is nothing to switch.
    read: *const fn (bytes: []u8) ?State,
    flip: *const fn (on: bool) void,

};

const State = struct {

    on: bool,
    detail: []const u8,

};

const tiles = [_]Tile{

    .{ .icon = .globe, .title = "Network", .read = network, .flip = power },

};

/// A group of the panel's contents, raised a little from it.
const card = gui.Style{

    .padding = .all(10),
    .gap = 6,

    .radius = theme.corner,
    .background = gui.shade(0xffffff, 10),

};

/// A day of the month: its number over a holiday's dot.
const day_style = gui.Style{

    .grow = 1,
    .height = 32,
    .direction = .stack,

    .radius = 16,

};

const row_style = gui.Style{

    .height = 48,
    .padding = .axes(0, 8),
    .direction = .row,
    .gap = 12,
    .items = .center,

    .radius = theme.radius,

    .hover = .{

        .background = theme.hover,

    },

};

// The time and date.
var hour_bytes: [8]u8 = undefined;

var hour = gui.label("", .{

    .size = 40,

});

var half = gui.label("", .{

    .padding = .{

        .bottom = 7,

    },
    .size = 17,
    .color = theme.muted,

});

var hour_parts = [_]*gui.Node{ &hour, &half };

var hour_row = gui.box(.{

    .direction = .row,
    .gap = 6,
    .items = .end,

}, &hour_parts);

var date_bytes: [48]u8 = undefined;
var date = gui.label("", theme.caption);
var header_parts = [_]*gui.Node{ &hour_row, &date };

var header = gui.box(.{

    .padding = .{

        .top = 6,
        .right = 6,
        .bottom = 2,
        .left = 6,

    },
    .gap = 2,

}, &header_parts);

// The weather, which opens Weather.
var place = gui.label("", theme.caption);
var degrees_bytes: [16]u8 = undefined;

var degrees = gui.label("", .{

    .size = 28,

});

var sky = gui.label("", .{

    .padding = .{

        .bottom = 4,

    },
    .color = theme.muted,

});

var reading_parts = [_]*gui.Node{ &degrees, &sky };

var reading = gui.box(.{

    .direction = .row,
    .gap = 8,
    .items = .end,

}, &reading_parts);

var outlook_parts = [_]*gui.Node{ &place, &reading };

var outlook = gui.box(.{

    .grow = 1,
    .gap = 2,

}, &outlook_parts);

var sky_icon = gui.icon(.sun, theme.icon.with(.{

    .width = 44,
    .height = 44,
    .size = 34,

}));

var weather_parts = [_]*gui.Node{ &outlook, &sky_icon };

var weather = gui.box(card.with(.{

    .padding = gui.Edges.axes(10, 12),
    .direction = .row,
    .gap = 10,
    .items = .center,

    .hover = .{

        .background = gui.shade(0xffffff, 18),

    },

}), &weather_parts);

/// Whose brief the card shows, empty while no one is signed in, and the unit they read it in.
var owner: []const u8 = "";
var brief: ?forecast.Brief = null;
var unit = forecast.Unit.fahrenheit;
var settings = api.Config{};

/// When Weather was last started to refresh the brief, in `api.clock` seconds.
var asked: u64 = 0;

// The calendar.
var month_bytes: [24]u8 = undefined;

var month = gui.label("", .{

    .grow = 1,
    .padding = .axes(0, 6),

    .radius = theme.radius,

    .hover = .{

        .background = theme.hover,

    },

});

var back = gui.tool(.left, &earlier);
var forward = gui.tool(.right, &later);
var month_parts = [_]*gui.Node{ &month, &back, &forward };

var month_row = gui.box(.{

    .direction = .row,
    .gap = 2,
    .items = .center,

}, &month_parts);

var heads: [7]gui.Node = undefined;
var head_list: [7]*gui.Node = undefined;

var head_row = gui.box(.{

    .direction = .row,
    .gap = 2,

}, &head_list);

var marks: [42]gui.Node = undefined;
var mark_rows: [42]gui.Node = undefined;
var mark_parts: [42][1]*gui.Node = undefined;
var numbers: [42]gui.Node = undefined;
var dots: [42]gui.Node = undefined;
var dot_rows: [42]gui.Node = undefined;
var dot_parts: [42][1]*gui.Node = undefined;
var cell_parts: [42][3]*gui.Node = undefined;
var cells: [42]gui.Node = undefined;
var week_parts: [6][7]*gui.Node = undefined;
var weeks: [6]gui.Node = undefined;
var week_list: [6]*gui.Node = undefined;

var grid = gui.box(.{

    .gap = 2,

}, &week_list);

var calendar_parts = [_]*gui.Node{ &month_row, &head_row, &grid };
var calendar = gui.box(card, &calendar_parts);

// The switches.
var icons: [tiles.len]gui.Node = undefined;
var titles: [tiles.len]gui.Node = undefined;
var details: [tiles.len]gui.Node = undefined;
var detail_bytes: [tiles.len][32]u8 = undefined;
var lit = [_]bool{false} ** tiles.len;
var words: [tiles.len][2]*gui.Node = undefined;
var texts: [tiles.len]gui.Node = undefined;
var knobs: [tiles.len]gui.Node = undefined;
var knob_parts: [tiles.len][1]*gui.Node = undefined;
var tracks: [tiles.len]gui.Node = undefined;
var row_parts: [tiles.len][3]*gui.Node = undefined;
var rows: [tiles.len]gui.Node = undefined;
var row_list: [tiles.len]*gui.Node = undefined;

var switches = gui.box(card.with(.{

    .padding = gui.Edges.all(4),
    .gap = 2,

}), &row_list);

var root_parts = [_]*gui.Node{ &header, &weather, &calendar, &switches };

var root = gui.box(theme.popup.with(.{

    .padding = gui.Edges.all(theme.spacing),
    .gap = 10,

}), &root_parts);

pub var window: gui.Window = undefined;

/// The month the calendar shows, by its first day, and today.
var page = Day{ .year = 1970, .month = 1, .day = 1 };
var now = Day{ .year = 1970, .month = 1, .day = 1 };

/// Where the panel's top right corner goes.
var corner = gui.Point{};

/// When an open panel next reads the time and its switches again.
var due: u64 = 0;

pub fn init() void {

    month.action = &current;
    weather.action = &look;

    for (&heads, 0..) |*head, index| {

        head.* = gui.label(time.days[(index + 1) % 7][0..2], theme.caption.with(.{

            .grow = 1,
            .color = theme.faint,
            .text_align = .center,

        }));

        head_list[index] = head;

    }

    for (&weeks, 0..) |*week, line| {

        for (0..7) |column| {

            const index = line * 7 + column;

            // Today's circle, centred under the number, as the cell is wider than it is tall.
            marks[index] = gui.box(.{

                .width = 30,
                .height = 30,

                .radius = 15,

            }, &.{});

            mark_parts[index] = .{&marks[index]};

            mark_rows[index] = gui.box(.{

                .direction = .row,
                .justify = .center,
                .items = .center,

            }, &mark_parts[index]);

            numbers[index] = gui.label("", .{

                .size = theme.small,
                .text_align = .center,

            });

            dots[index] = gui.box(.{

                .width = 3,
                .height = 3,

                .radius = 2,

            }, &.{});

            dot_parts[index] = .{&dots[index]};

            dot_rows[index] = gui.box(.{

                .padding = .{

                    .bottom = 4,

                },
                .justify = .end,
                .items = .center,

            }, &dot_parts[index]);

            cell_parts[index] = .{ &mark_rows[index], &numbers[index], &dot_rows[index] };
            cells[index] = gui.box(day_style, &cell_parts[index]);
            week_parts[line][column] = &cells[index];

        }

        week.* = gui.box(.{

            .direction = .row,
            .gap = 2,

        }, &week_parts[line]);

        week_list[line] = week;

    }

    for (tiles, 0..) |tile, index| {

        icons[index] = gui.icon(tile.icon, theme.icon.with(.{

            .width = 30,
            .height = 30,

            .radius = 15,

        }));

        titles[index] = gui.label(tile.title, .{});
        details[index] = gui.label("", theme.caption);
        words[index] = .{ &titles[index], &details[index] };

        texts[index] = gui.box(.{

            .grow = 1,
            .gap = 2,

        }, &words[index]);

        knobs[index] = gui.box(.{

            .width = 16,
            .height = 16,

            .radius = 8,

        }, &.{});

        knob_parts[index] = .{&knobs[index]};

        tracks[index] = gui.box(.{

            .width = 36,
            .height = 20,
            .padding = .all(2),
            .direction = .row,
            .items = .center,

            .radius = 10,

        }, &knob_parts[index]);

        row_parts[index] = .{ &icons[index], &texts[index], &tracks[index] };
        rows[index] = gui.box(row_style, &row_parts[index]);
        rows[index].action = &choose;
        rows[index].data = index;
        row_list[index] = &rows[index];

    }

    window = gui.Window.open(&root, .{

        .layer = .panel,

        .width = width,
        .height = 100,

        .hidden = true,
        .motion = .drop,
        .shadow = true,

    }) catch api.exit(3);

}

/// Opens the panel on this month, with its top right corner at `at`.
pub fn show(at: gui.Point) void {

    corner = at;
    now = Day.today();
    page = first(now);
    renew(10 * 60, 60);
    refresh();
    window.show();

}

/// Reads the brief and unit of user `name` again, as after Weather changed them; an empty name clears the card.
pub fn load(name: []const u8) void {

    owner = name;
    brief = if (name.len == 0) null else forecast.Brief.load(name);
    settings.open(name, forecast.config);
    unit = forecast.Unit.read(&settings);
    if (shown()) refresh();

}

pub fn hide() void {

    if (shown()) window.hide();

}

pub fn shown() bool {

    return !window.surface.hidden;

}

/// Keeps an open panel's time and switches current, every second, and the brief fresh; call it every pass of the event loop.
pub fn tick() void {

    renew(30 * 60, 10 * 60);
    if (shown() and api.ticks() >= due) refresh();

}

/// Starts Weather without a window to refresh the brief once it is `age` seconds old, at most once every `gap` seconds.
fn renew(age: u64, gap: u64) void {

    const moment = api.clock();

    if (owner.len == 0 or moment < asked + gap) return;
    if (brief) |known| if (moment < known.updated + age) return;

    asked = moment;

    const state = api.net.status() catch return;
    if (!state.online()) return;

    var argument: [80]u8 = undefined;

    _ = api.launch(@tagName(api.abi.Image.weather), std.fmt.bufPrint(&argument, "{s}{s}", .{ forecast.quiet, desktop.home }) catch return) catch {

    };

}

/// Reads the time and every switch again, lays the month out, and fits the panel to it all.
fn refresh() void {

    const today = api.Date.init(api.clock());

    due = api.ticks() + 100;
    hour.content.label = std.fmt.bufPrint(&hour_bytes, "{d}:{d:0>2}", .{ today.twelve(), today.minute }) catch "";
    half.content.label = today.half();
    date.content.label = today.long(&date_bytes, true);

    // Past midnight, an open panel still on the old month moves to the new one.
    if (!now.same(Day.today())) {

        if (page.same(first(now))) page = first(Day.today());
        now = Day.today();

    }

    fill();
    weather.hidden = brief == null;

    if (brief) |*known| {

        const seen = forecast.sky(known.code, known.day);

        sky_icon.content.label = seen.icon.text();
        degrees.content.label = unit.temperature(&degrees_bytes, known.temperature);
        sky.content.label = seen.title;
        place.content.label = api.metrics.text(&known.place);

    }

    for (tiles, 0..) |tile, index| {

        const state = tile.read(&detail_bytes[index]);
        const on = if (state) |known| known.on else false;

        lit[index] = on;
        rows[index].hidden = state == null;
        details[index].content.label = if (state) |known| known.detail else "";
        icons[index].style.background = if (on) theme.accent else theme.hover;
        icons[index].style.color = if (on) theme.background else theme.text;
        tracks[index].style.background = if (on) theme.accent else theme.selected;
        tracks[index].style.justify = if (on) .end else .start;
        knobs[index].style.background = if (on) theme.background else theme.muted;

    }

    switches.hidden = for (rows) |row| {

        if (!row.hidden) break false;

    } else true;

    const size = root.measure();

    window.move(.{

        .x = corner.x - width,
        .y = corner.y,
        .width = width,
        .height = size.height,

    });

    window.refresh();

}

/// Lays out the month shown: Monday first, days of the months around it faint, today filled, holidays dotted.
fn fill() void {

    const lead = page.weekday();
    const lines = (lead + time.length(page.year, page.month) + 6) / 7;

    month.content.label = std.fmt.bufPrint(&month_bytes, "{s} {d}", .{ time.months[page.month - 1], page.year }) catch "";

    for (0..cells.len) |index| {

        const day = page.add(@as(i32, @intCast(index)) - lead);
        const inside = day.month == page.month;
        const today = day.same(now);

        numbers[index].content.label = days.numerals[day.day];
        numbers[index].style.color = if (today) theme.background else if (!inside) theme.faint else if (index % 7 >= 5) theme.muted else theme.text;
        marks[index].style.background = if (today) theme.accent else null;
        dots[index].hidden = today or days.holiday(day) == null;
        dots[index].style.background = if (inside) theme.accent else theme.faint;

    }

    for (&weeks, 0..) |*week, line| week.hidden = line >= lines;

}

fn first(day: Day) Day {

    return .{

        .year = day.year,
        .month = day.month,
        .day = 1,

    };

}

fn earlier(_: *gui.Node) void {

    page = page.shift(-1);
    refresh();

}

fn later(_: *gui.Node) void {

    page = page.shift(1);
    refresh();

}

/// Back to this month, from the month's title.
fn current(_: *gui.Node) void {

    page = first(now);
    refresh();

}

/// Brings Weather forward, starting it when it is not open.
fn look(_: *gui.Node) void {

    desktop.dismiss();

    for (desktop.listed[0..desktop.count]) |*listed| {

        if (listed.application != @intFromEnum(api.abi.Image.weather)) continue;

        gui.display.activate(listed.id, .raise) catch {

        };

        return;

    }

    desktop.start_app(.weather, desktop.home);

}

fn choose(node: *gui.Node) void {

    tiles[node.data].flip(!lit[node.data]);
    refresh();

}

fn network(_: []u8) ?State {

    const state = api.net.status() catch return null;

    if (state.off) return .{ .on = false, .detail = "Off" };
    if (state.speed == 0) return .{ .on = true, .detail = "Disconnected" };
    if (state.address.empty()) return .{ .on = true, .detail = "Connecting" };

    return .{ .on = true, .detail = "Connected" };

}

fn power(on: bool) void {

    api.net.power(on) catch {

    };

}
