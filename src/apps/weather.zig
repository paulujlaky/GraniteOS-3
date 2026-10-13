//! Weather: conditions, the day hour by hour, and the week ahead where you are and at places you keep, from Open-Meteo.
//! Started with `forecast.quiet` before a home, it only refreshes the brief the quick settings show, then quits.

const std = @import("std");

const catalog = @import("catalog.zig");
const forecast = @import("forecast.zig");

const api = @import("api");
const gui = @import("gui");

const metrics = api.metrics;
const protocol = api.protocol;
const theme = gui.theme;
const Forecast = forecast.Forecast;
const Found = forecast.Found;
pub const panic = api.panic;

/// Most places kept besides the current location, and found by one search.
const most = 12;
const results = 8;

/// Ticks between forecasts while the window is open, between asks while the location is still being found, and the longest
/// one forecast or search may take.
const fresh = 15 * 60 * 100;
const soon = 300;
const longest = 30 * 100;

const Trouble = api.http.HttpError || error{ Locating, Unlocated };

/// A place to forecast and the name the brief gives it.
const Spot = struct {

    latitude: f64,
    longitude: f64,
    name: []const u8,

};

/// A line in the sidebar: a place's icon, name, and region.
const Row = struct {

    icon: gui.Node,
    title: gui.Node,
    detail: gui.Node,
    words: [2]*gui.Node,
    text: gui.Node,
    parts: [2]*gui.Node,
    node: gui.Node,

    fn init(self: *Row, action: *const fn (*gui.Node) void, index: usize) void {

        self.icon = gui.icon(.place, theme.icon);
        self.title = gui.label("", .{});
        self.detail = gui.label("", theme.caption);
        self.words = .{ &self.title, &self.detail };

        self.text = gui.box(.{

            .grow = 1,
            .gap = 2,

        }, &self.words);

        self.parts = .{ &self.icon, &self.text };

        self.node = gui.box(theme.item.with(.{

            .height = 48,

        }), &self.parts);

        self.node.action = action;
        self.node.data = index;

    }

    fn set(self: *Row, icon: gui.Icon, title: []const u8, detail: []const u8) void {

        self.icon.content.label = icon.text();
        self.title.content.label = title;
        self.detail.content.label = detail;
        self.detail.hidden = detail.len == 0;
        self.node.hidden = false;

    }

};

/// A reading of the weather now, in a card of its own.
const Stat = struct {

    icon: gui.Node,
    title: gui.Node,
    head_parts: [2]*gui.Node,
    head: gui.Node,
    value: gui.Node,
    detail: gui.Node,
    parts: [3]*gui.Node,
    node: gui.Node,
    bytes: [24]u8 = undefined,

    fn init(self: *Stat, icon: gui.Icon, title: []const u8) void {

        self.icon = gui.icon(icon, theme.icon.with(.{

            .color = theme.muted,

        }));

        self.title = gui.label(title, theme.caption);
        self.head_parts = .{ &self.icon, &self.title };

        self.head = gui.box(.{

            .direction = .row,
            .gap = 6,
            .items = .center,

        }, &self.head_parts);

        self.value = gui.label("", .{

            .size = 22,

        });

        self.detail = gui.label("", theme.caption);
        self.parts = .{ &self.head, &self.value, &self.detail };

        self.node = gui.box(theme.panel.with(.{

            .grow = 1,
            .gap = 6,

        }), &self.parts);

    }

};

/// A day of the week to pick: its name, its sky, and its highest and lowest.
const Chip = struct {

    name: gui.Node,
    icon: gui.Node,
    range: gui.Node,
    parts: [3]*gui.Node,
    node: gui.Node,
    bytes: [24]u8 = undefined,

    fn init(self: *Chip, index: usize) void {

        self.name = gui.label("", theme.caption.with(.{

            .text_align = .center,

        }));

        self.icon = gui.icon(.sun, theme.icon.with(.{

            .width = null,
            .height = 30,
            .size = 22,

        }));

        self.range = gui.label("", .{

            .size = theme.small,
            .text_align = .center,

        });

        self.parts = .{ &self.name, &self.icon, &self.range };

        self.node = gui.box(theme.button.with(.{

            .height = null,
            .grow = 1,
            .padding = gui.Edges.all(10),
            .gap = 4,

        }), &self.parts);

        self.node.action = &pick;
        self.node.data = index;

    }

};

/// A label over a value, for the picked day's details and the hours under the graph.
const Fact = struct {

    title: gui.Node,
    icon: gui.Node,
    value: gui.Node,
    parts: [3]*gui.Node,
    node: gui.Node,
    bytes: [32]u8 = undefined,

    fn init(self: *Fact, title: []const u8, icon: ?gui.Icon, centred: bool) void {

        const alignment: gui.style.Alignment = if (centred) .center else .left;

        self.title = gui.label(title, theme.caption.with(.{

            .text_align = alignment,

        }));

        self.icon = gui.icon(icon orelse .sun, theme.icon.with(.{

            .width = null,
            .height = 24,

        }));

        self.icon.hidden = icon == null;

        self.value = gui.label("", .{

            .size = theme.small,
            .text_align = alignment,

        });

        self.parts = .{ &self.title, &self.icon, &self.value };

        // No width of its own, so a row of them shares its width evenly.
        self.node = gui.box(.{

            .width = 0,
            .grow = 1,
            .gap = 4,

        }, &self.parts);

    }

};

var window: gui.Window = undefined;
var opened = false;
var settings = api.Config{};
var unit = forecast.Unit.fahrenheit;

/// The desktop that launched us, told when the brief changes.
var session: u64 = 0;
var user: []const u8 = "";
var home: []const u8 = "/";
var home_bytes: [64]u8 = undefined;

var kept: [most]Found = undefined;
var kept_count: usize = 0;
var found: [results]Found = undefined;
var found_count: usize = 0;

/// The place on show: 0 for the current location, then each kept one.
var shown: usize = 0;
var here = metrics.Place{};
var weather: ?Forecast = null;
var updated: u64 = 0;
var day: usize = 0;
var hour: ?usize = null;

/// UTC seconds when the forecast was last shown, for the graph's mark for now.
var instant: i64 = 0;

// A forecast or search runs the event loop while it waits, so what nodes ask for waits for the main loop.
var stale = true;
var wanted = false;
var busy = false;
var due: u64 = 0;
var deadline: u64 = 0;
var trouble: ?Trouble = null;

/// The kept place a menu was opened on.
var offered: usize = 0;

var place_menu: gui.Menu(&.{

    .{ .icon = .trash, .title = "Remove", .run = remove },

}) = .{};

// Sidebar.
var search_bytes: [64]u8 = undefined;

var search_text = gui.Text{

    .buffer = &search_bytes,
    .placeholder = "Search for a place",

};

var search = gui.input(&search_text);
var note_bytes: [96]u8 = undefined;
/// A caption over a group of the sidebar's rows.
const note_style = theme.caption.with(.{

    .padding = gui.Edges{

        .top = 10,
        .bottom = 4,
        .left = 4,

    },

});

var result_note = gui.label("", note_style);
var result_rows: [results]Row = undefined;
var places_note = gui.label("Places", note_style);
var place_rows: [1 + most]Row = undefined;
var side_list: [3 + results + place_rows.len]*gui.Node = undefined;

var sidebar = gui.box(.{

    .width = 250,
    .padding = .all(theme.gap),
    .gap = 2,
    .scroll = true,

    .background = theme.pane,

}, &side_list);

// The place and its unit.
var banner = gui.label("", theme.title_text);
var subtitle_bytes: [64]u8 = undefined;
var subtitle = gui.label("", theme.caption);
var heading_parts = [_]*gui.Node{ &banner, &subtitle };

var heading = gui.box(.{

    .grow = 1,
    .gap = 2,

}, &heading_parts);

var fahrenheit = gui.button("\u{00b0}F", &useFahrenheit);
var celsius = gui.button("\u{00b0}C", &useCelsius);
var again = gui.tool(.refresh, &refresh);
var header_parts = [_]*gui.Node{ &heading, &fahrenheit, &celsius, &again };

var header = gui.box(.{

    .direction = .row,
    .gap = 4,
    .items = .center,

}, &header_parts);

// Now.
var hero_icon = gui.icon(.sun, theme.icon.with(.{

    .width = 72,
    .height = 72,
    .size = 56,

}));

var hero_bytes: [16]u8 = undefined;

var hero_temperature = gui.label("", .{

    .size = 56,

});

var condition = gui.label("", .{

    .size = theme.heading,

});

var feels_bytes: [64]u8 = undefined;
var feels = gui.label("", theme.caption);
var hero_word_parts = [_]*gui.Node{ &condition, &feels };

var hero_words = gui.box(.{

    .gap = 4,
    .justify = .center,

}, &hero_word_parts);

var hero_parts = [_]*gui.Node{ &hero_icon, &hero_temperature, &hero_words };

var hero = gui.box(.{

    .direction = .row,
    .gap = 18,
    .items = .center,

}, &hero_parts);

var humidity: Stat = undefined;
var wind: Stat = undefined;
var pressure: Stat = undefined;
var exposure: Stat = undefined;
var stat_list: [4]*gui.Node = undefined;

var stats = gui.box(.{

    .direction = .row,
    .gap = theme.spacing,

}, &stat_list);

// The picked day, hour by hour.
var chart_day = gui.label("", .{});
var readout_bytes: [64]u8 = undefined;
var readout = gui.label("", theme.caption);
var chart_spring = gui.box(theme.spring, &.{});
var chart_head_parts = [_]*gui.Node{ &chart_day, &chart_spring, &readout };

var chart_head = gui.box(.{

    .direction = .row,
    .items = .center,

}, &chart_head_parts);

var curve = gui.Figure{

    .paint = &paintChart,

};

var chart: gui.Node = undefined;

var hours: [8]Fact = undefined;
var hour_list: [8]*gui.Node = undefined;

var hour_row = gui.box(.{

    .direction = .row,

}, &hour_list);

var chart_parts = [_]*gui.Node{ &chart_head, &chart, &hour_row };

var chart_panel = gui.box(theme.panel.with(.{

    .gap = 10,

}), &chart_parts);

// The week.
var chips: [7]Chip = undefined;
var chip_list: [7]*gui.Node = undefined;

var week = gui.box(.{

    .direction = .row,
    .gap = theme.gap,

}, &chip_list);

var facts: [5]Fact = undefined;
var fact_list: [5]*gui.Node = undefined;

var details = gui.box(theme.panel.with(.{

    .direction = .row,

}), &fact_list);

// Shown instead while there is no forecast.
var message_icon = gui.icon(.cloud, theme.icon.with(.{

    .width = null,
    .height = 52,
    .size = 40,
    .color = theme.faint,

}));

var message_bytes: [128]u8 = undefined;

var message = gui.label("", .{

    .color = theme.muted,
    .text_align = .center,

});

var retry = gui.button("Try again", &refresh);
var message_parts = [_]*gui.Node{ &message_icon, &message, &retry };

var notice = gui.box(.{

    .padding = .{

        .top = 120,

    },
    .gap = theme.spacing,
    .items = .center,

}, &message_parts);

var main_parts = [_]*gui.Node{ &header, &hero, &stats, &chart_panel, &week, &details, &notice };

var main = gui.box(.{

    .grow = 1,
    .padding = .all(theme.spacing + 4),
    .gap = theme.spacing,
    .scroll = true,

}, &main_parts);

var root_parts = [_]*gui.Node{ &sidebar, &main };

var root = gui.box(.{

    .direction = .row,

}, &root_parts);

pub export fn app_main(parent: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .application);
    session = parent;

    var argument_bytes: [256]u8 = undefined;
    const argument = api.argument(&argument_bytes);
    const quiet = std.mem.startsWith(u8, argument, forecast.quiet);

    home = std.fmt.bufPrint(&home_bytes, "{s}", .{catalog.home(argument[if (quiet) forecast.quiet.len else 0 ..]) orelse "/"}) catch "/";
    user = std.fs.path.basenamePosix(home);
    load();
    api.net.idle = &idle;

    if (quiet) {

        _ = latest() catch {

        };

        api.exit(0);

    }

    build();

    window = gui.Window.open(&root, .{

        .title = "Weather",
        .application = .weather,

        .width = 980,
        .height = 700,

    }) catch api.exit(3);

    opened = true;
    place_menu.init(&window);

    // Named in the sidebar even while a kept place shows; the service answers at once, known or not.
    here = metrics.place() catch here;
    show();

    while (true) {

        if (stale or api.ticks() >= due) update();
        if (wanted) seek();

        const event = window.next(100) orelse continue;

        if (event.kind == .close) window.quit();
        if (!event.pressing(.escape)) continue;
        if (search_text.length != 0 or found_count != 0) clear();

        window.focus(null);

    }

}

/// Keeps the window painting and answering while a forecast or search waits on the network, and gives up on a slow one.
fn idle() api.net.NetError!void {

    if (api.ticks() >= deadline) return error.Timeout;
    if (!opened) return;

    const event = window.next(1) orelse return;

    if (event.kind == .close) window.quit();

}

/// Forecasts the place shown, keeping it as the brief the quick settings show.
fn latest() Trouble!Forecast {

    const spot = try where(shown);

    deadline = api.ticks() + longest;

    const result = try forecast.fetch(spot.latitude, spot.longitude);

    forecast.Brief.of(spot.name, &result).save(user);

    _ = api.call(session, protocol.pack(.reload, @intFromEnum(catalog.Reload.weather))) catch {

    };

    return result;

}

fn where(index: usize) Trouble!Spot {

    if (index != 0) {

        const place = &kept[index - 1];

        return .{

            .latitude = place.latitude,
            .longitude = place.longitude,
            .name = metrics.text(&place.name),

        };

    }

    here = metrics.place() catch |err| return if (err == error.Busy) error.Locating else error.Unlocated;

    const city = metrics.text(&here.city);

    return .{

        .latitude = here.latitude,
        .longitude = here.longitude,
        .name = if (city.len == 0) "Current location" else city,

    };

}

/// Forecasts the place shown, unless the window moves on to another place before it comes.
fn update() void {

    const asked = shown;

    stale = false;
    busy = true;
    due = api.ticks() + fresh;
    show();

    const result = latest();

    busy = false;
    if (asked != shown) return;

    if (result) |fetched| {

        weather = fetched;
        trouble = null;
        updated = api.clock();

    } else |err| {

        trouble = err;
        if (err == error.Locating) due = api.ticks() + soon;

    }

    show();

}

/// Searches for the places named in the search field.
fn seek() void {

    wanted = false;

    const query = std.mem.trim(u8, search_text.text(), " ");
    if (query.len == 0) return clear();

    busy = true;
    found_count = 0;
    result_note.content.label = "Searching\u{2026}";
    show();

    deadline = api.ticks() + longest;
    found_count = forecast.search(query, &found) catch |err| {

        busy = false;
        result_note.content.label = std.fmt.bufPrint(&note_bytes, "Search failed: {s}", .{api.http.reason(err)}) catch "";

        return show();

    };

    busy = false;
    result_note.content.label = if (found_count == 0) "No places found" else "Results";
    show();

}

fn clear() void {

    search_text.clear();
    found_count = 0;
    result_note.content.label = "";
    show();

}

fn build() void {

    search.action = &ask;
    side_list[0] = &search;
    side_list[1] = &result_note;

    for (&result_rows, 0..) |*row, index| {

        row.init(&add, index);
        side_list[2 + index] = &row.node;

    }

    side_list[2 + results] = &places_note;

    for (&place_rows, 0..) |*row, index| {

        row.init(&choose, index);
        if (index != 0) row.node.menu = &offer;
        side_list[3 + results + index] = &row.node;

    }

    for ([_]*gui.Node{ &fahrenheit, &celsius }) |button| button.style.width = 48;

    humidity.init(.humidity, "Humidity");
    wind.init(.wind, "Wind");
    pressure.init(.pressure, "Pressure");
    exposure.init(.sun, "UV index");
    stat_list = .{ &humidity.node, &wind.node, &pressure.node, &exposure.node };

    chart = gui.figure(&curve, .{

        .height = 150,

    });

    chart.hover = &glide;

    for (&hours, 0..) |*cell, index| {

        cell.init("", .sun, true);
        hour_list[index] = &cell.node;

    }

    for (&chips, 0..) |*chip, index| {

        chip.init(index);
        chip_list[index] = &chip.node;

    }

    for (&facts, [_][]const u8{ "Sunrise", "Sunset", "Rain or snow", "Wind", "UV index" }, 0..) |*fact, name, index| {

        fact.init(name, null, false);
        fact_list[index] = &fact.node;

    }

}

/// Reads the unit, the places kept, and the place shown.
fn load() void {

    settings.open(user, forecast.config);
    unit = forecast.Unit.read(&settings);
    kept_count = 0;

    var lines = settings.all("place");

    while (lines.next()) |line| {

        if (kept_count == most) break;

        var fields = std.mem.splitScalar(u8, line, '|');
        var place = Found{};

        place.latitude = std.fmt.parseFloat(f64, fields.next() orelse continue) catch continue;
        place.longitude = std.fmt.parseFloat(f64, fields.next() orelse continue) catch continue;
        metrics.fill(&place.name, fields.next() orelse continue);
        metrics.fill(&place.detail, fields.rest());
        kept[kept_count] = place;
        kept_count += 1;

    }

    shown = @min(settings.number(usize, "shown") orelse 0, kept_count);

}

fn save() void {

    settings.open(user, forecast.config);
    _ = settings.set("unit", @tagName(unit));
    _ = settings.set("shown", shown);
    settings.erase("place");

    for (kept[0..kept_count]) |*place| {

        var line: [256]u8 = undefined;

        _ = settings.add("place", std.fmt.bufPrint(&line, "{d:.4}|{d:.4}|{s}|{s}", .{ place.latitude, place.longitude, metrics.text(&place.name), metrics.text(&place.detail) }) catch continue);

    }

    settings.save() catch {

    };

}

/// Shows everything afresh: the sidebar, then the forecast, or why there is none.
fn show() void {

    if (!opened) return;

    const city = metrics.text(&here.city);

    for (&result_rows, 0..) |*row, index| {

        row.node.hidden = index >= found_count;
        if (index < found_count) row.set(.place, metrics.text(&found[index].name), metrics.text(&found[index].detail));

    }

    result_note.hidden = result_note.content.label.len == 0;
    place_rows[0].set(.location, if (city.len == 0) "Current location" else city, if (city.len == 0) "" else "Current location");

    for (place_rows[1..], 0..) |*row, index| {

        row.node.hidden = index >= kept_count;
        if (index < kept_count) row.set(.place, metrics.text(&kept[index].name), metrics.text(&kept[index].detail));

    }

    for (&place_rows, 0..) |*row, index| row.node.selected = index == shown;

    fahrenheit.selected = unit == .fahrenheit;
    celsius.selected = unit == .celsius;
    again.action = if (busy) null else &refresh;
    banner.content.label = place_rows[shown].title.content.label;

    const data = if (weather) |*known| known else null;

    for ([_]*gui.Node{ &hero, &stats, &chart_panel, &week, &details }) |part| part.hidden = data == null;
    notice.hidden = data != null;

    if (data) |known| {

        subtitle.content.label = if (busy) "Updating\u{2026}" else blk: {

            var clock_bytes: [16]u8 = undefined;

            break :blk std.fmt.bufPrint(&subtitle_bytes, "Updated {s}", .{api.Date.init(updated).clock(&clock_bytes, false)}) catch "";

        };

        present(known);

    } else {

        subtitle.content.label = "";
        retry.hidden = trouble == null or trouble.? == error.Locating;
        message.content.label = if (trouble) |err| explain(err) else "Loading the weather\u{2026}";

    }

    window.refresh();

}

fn explain(err: Trouble) []const u8 {

    return switch (err) {

        error.Locating => "Finding your location\u{2026}",
        error.Unlocated => "Your location couldn't be found. Search for a place instead.",
        else => |other| std.fmt.bufPrint(&message_bytes, "Couldn't load the weather: {s}.", .{api.http.reason(other)}) catch "",

    };

}

/// Fills in the forecast for `data`'s place.
fn present(data: *const Forecast) void {

    const now = data.now;
    const sky = forecast.sky(now.code, now.day);
    const today = if (data.day_count != 0) data.days[0] else forecast.Day{};

    day = @min(day, data.day_count -| 1);
    hero_icon.content.label = sky.icon.text();
    hero_temperature.content.label = unit.temperature(&hero_bytes, now.temperature);
    condition.content.label = sky.title;

    var feel: [8]u8 = undefined;
    var high: [8]u8 = undefined;
    var low: [8]u8 = undefined;

    feels.content.label = std.fmt.bufPrint(&feels_bytes, "Feels like {s}  \u{00b7}  H {s}  L {s}", .{ unit.temperature(&feel, now.feels), unit.temperature(&high, today.high), unit.temperature(&low, today.low) }) catch "";

    humidity.value.content.label = std.fmt.bufPrint(&humidity.bytes, "{d:.0}%", .{now.humidity}) catch "";
    humidity.detail.content.label = "Relative";
    wind.value.content.label = unit.speed(&wind.bytes, now.wind);
    wind.detail.content.label = forecast.compass(now.direction);
    pressure.value.content.label = std.fmt.bufPrint(&pressure.bytes, "{d:.0} hPa", .{now.pressure}) catch "";
    pressure.detail.content.label = "At the surface";
    exposure.value.content.label = std.fmt.bufPrint(&exposure.bytes, "{d:.0}", .{today.uv}) catch "";
    exposure.detail.content.label = level(today.uv);

    for (&chips, 0..) |*chip, index| {

        chip.node.hidden = index >= data.day_count;
        if (index >= data.day_count) continue;

        const picked = &data.days[index];

        chip.name.content.label = if (index == 0) "Today" else api.time.days[api.Date.init(data.local(picked.time)).weekday][0..3];
        chip.icon.content.label = forecast.sky(picked.code, true).icon.text();
        chip.range.content.label = std.fmt.bufPrint(&chip.bytes, "{s}  {s}", .{ unit.temperature(&high, picked.high), unit.temperature(&low, picked.low) }) catch "";
        chip.node.selected = index == day;

    }

    const picked = if (data.day_count != 0) data.days[day] else forecast.Day{};
    var rain_bytes: [16]u8 = undefined;

    facts[0].value.content.label = moment(&facts[0].bytes, data, picked.sunrise);
    facts[1].value.content.label = moment(&facts[1].bytes, data, picked.sunset);
    facts[2].value.content.label = std.fmt.bufPrint(&facts[2].bytes, "{d:.0}%  \u{00b7}  {s}", .{ picked.chance, unit.depth(&rain_bytes, picked.rain) }) catch "";
    facts[3].value.content.label = unit.speed(&facts[3].bytes, picked.wind);
    facts[4].value.content.label = std.fmt.bufPrint(&facts[4].bytes, "{d:.0}  {s}", .{ picked.uv, level(picked.uv) }) catch "";

    chart_day.content.label = if (day == 0) "Today" else if (day == 1) "Tomorrow" else api.time.days[api.Date.init(data.local(picked.time)).weekday];

    const spanned = span(data);

    for (&hours, 0..) |*cell, index| {

        const at = index * 3 + 1;

        cell.node.hidden = at >= spanned.len;
        if (at >= spanned.len) continue;

        cell.title.content.label = when(&cell.bytes, data, spanned[at].time);
        cell.icon.content.label = forecast.sky(spanned[at].code, spanned[at].day).icon.text();
        cell.value.content.label = unit.temperature(cell.bytes[16..], spanned[at].temperature);

    }

    instant = @intCast(api.net.utc());
    describe(data);
    curve.invalidate();

}

/// The readout over the graph: the hour the pointer is over, or the picked day's range.
fn describe(data: *const Forecast) void {

    const spanned = span(data);
    var first: [8]u8 = undefined;
    var second: [8]u8 = undefined;

    if (hour) |index| if (index < spanned.len) {

        var time: [16]u8 = undefined;
        const picked = spanned[index];

        readout.content.label = std.fmt.bufPrint(&readout_bytes, "{s}  \u{00b7}  {s}  \u{00b7}  {d:.0}% chance of rain", .{ when(&time, data, picked.time), unit.temperature(&first, picked.temperature), picked.chance }) catch "";
        return;

    };

    const picked = if (data.day_count != 0) data.days[day] else forecast.Day{};

    readout.content.label = std.fmt.bufPrint(&readout_bytes, "H {s}  L {s}", .{ unit.temperature(&first, picked.high), unit.temperature(&second, picked.low) }) catch "";

}

/// The picked day's hours.
fn span(data: *const Forecast) []const forecast.Hour {

    const start = @min(day * 24, data.hour_count);

    return data.hours[start..@min(start + 24, data.hour_count)];

}

/// An hour such as `3 PM` at the place.
fn when(out: []u8, data: *const Forecast, time: i64) []const u8 {

    const date = api.Date.init(data.local(time));

    return std.fmt.bufPrint(out, "{d} {s}", .{ date.twelve(), date.half() }) catch "";

}

/// A time such as `7:02 AM` at the place.
fn moment(out: []u8, data: *const Forecast, time: i64) []const u8 {

    return api.Date.init(data.local(time)).clock(out, false);

}

fn level(uv: f32) []const u8 {

    if (uv < 3) return "Low";
    if (uv < 6) return "Moderate";
    if (uv < 8) return "High";
    if (uv < 11) return "Very high";

    return "Extreme";

}

/// The picked day's temperatures as a curve, the chance of rain as bars beneath, and marks for now and the hour pointed at.
fn paintChart(_: *gui.Figure, target: *gui.Sketch) void {

    const data = if (weather) |*known| known else return;
    const spanned = span(data);
    if (spanned.len < 2) return;

    var values: [24]f32 = undefined;
    var lowest: f32 = spanned[0].temperature;
    var highest: f32 = spanned[0].temperature;

    for (spanned) |picked| {

        lowest = @min(lowest, picked.temperature);
        highest = @max(highest, picked.temperature);

    }

    // A degree of room either side keeps a flat day off the edges.
    for (spanned, 0..) |picked, index| values[index] = (picked.temperature - lowest + 1) / (highest - lowest + 2);

    const look = gui.graph.Look{

        .emphasis = 0,

    };

    const height: f32 = @floatFromInt(target.height);
    const inset = margin(target.width);
    var inner = target.*;

    target.rectangle(.{ 0, 0, @floatFromInt(target.width), height }, @floatFromInt(look.radius), 0, look.background);
    inner.origin.x += @intCast(inset);
    inner.width -|= 2 * inset;
    gui.graph.plot(&inner, values[0..spanned.len], look);

    const width: f32 = @floatFromInt(inner.width);
    const step = width / @as(f32, @floatFromInt(spanned.len - 1));
    const thickness = @max(step * 0.45, 2);

    for (spanned, 0..) |picked, index| {

        const x = step * @as(f32, @floatFromInt(index));
        const tall = picked.chance / 100 * height * 0.35;

        if (tall >= 1) inner.rectangle(.{ x - thickness / 2, height - tall, x + thickness / 2, height }, 1, 0, gui.shade(0xffffff, 36));

    }

    // Now, as a faint line across today.
    const since = @as(f32, @floatFromInt(instant - spanned[0].time)) / 3600;

    if (day == 0 and since >= 0 and since <= @as(f32, @floatFromInt(spanned.len - 1))) inner.line(since * step, 0, since * step, height, 1, gui.shade(0xffffff, 90));

    const index = hour orelse return;
    if (index >= spanned.len) return;

    const x = step * @as(f32, @floatFromInt(index));
    const pad = look.width + 1;
    const y = pad + (1 - values[index]) * (height - 2 * pad);

    inner.line(x, 0, x, height, 1, gui.shade(0xffffff, 140));
    inner.disc(x, y, 4, theme.accent);

}

/// How far in from each side the graph's first and last hours sit: half of one of the day's 24 columns, so every third hour
/// lines up over the hour beneath it.
fn margin(width: usize) usize {

    return width / 48;

}

fn glide(node: *gui.Node, at: ?gui.Point) void {

    const data = if (weather) |*known| known else return;
    const count = span(data).len;

    const next: ?usize = if (at) |point| blk: {

        if (count < 2) break :blk null;

        const inset: i32 = @intCast(margin(@intCast(@max(node.rect.width, 0))));
        const fraction = @as(f32, @floatFromInt(point.x - node.rect.x - inset)) / @as(f32, @floatFromInt(@max(node.rect.width - 2 * inset, 1)));

        break :blk @intFromFloat(@round(std.math.clamp(fraction, 0, 1) * @as(f32, @floatFromInt(count - 1))));

    } else null;

    if (std.meta.eql(next, hour)) return;

    hour = next;
    describe(data);
    curve.invalidate();
    window.invalidate(&chart_panel);

}

fn ask(_: *gui.Node) void {

    wanted = true;

}

fn refresh(_: *gui.Node) void {

    stale = true;

}

/// Shows place `node.data` from the sidebar.
fn choose(node: *gui.Node) void {

    if (node.data == shown) return;

    shown = node.data;
    weather = null;
    trouble = null;
    hour = null;
    day = 0;
    stale = true;
    save();
    show();

}

/// Keeps a place a search found, and shows it.
fn add(node: *gui.Node) void {

    const place = found[node.data];

    for (kept[0..kept_count], 0..) |*other, index| {

        if (@abs(other.latitude - place.latitude) < 0.01 and @abs(other.longitude - place.longitude) < 0.01) {

            clear();
            return choose(&place_rows[index + 1].node);

        }

    }

    if (kept_count == most) {

        result_note.content.label = "Remove a place to keep another";
        return show();

    }

    kept[kept_count] = place;
    kept_count += 1;
    clear();
    choose(&place_rows[kept_count].node);

}

fn offer(node: *gui.Node, at: gui.Point) void {

    offered = node.data;
    place_menu.show(at);

}

fn remove() void {

    if (offered == 0 or offered > kept_count) return;

    std.mem.copyForwards(Found, kept[offered - 1 .. kept_count - 1], kept[offered..kept_count]);
    kept_count -= 1;

    if (shown == offered) {

        shown = 0;
        weather = null;
        stale = true;

    } else if (shown > offered) {

        shown -= 1;

    }

    save();
    show();

}

fn pick(node: *gui.Node) void {

    day = node.data;
    hour = null;
    show();

}

fn useFahrenheit(_: *gui.Node) void {

    convert(.fahrenheit);

}

fn useCelsius(_: *gui.Node) void {

    convert(.celsius);

}

/// Shows readings in `chosen`, and tells the desktop so its card follows.
fn convert(chosen: forecast.Unit) void {

    if (unit == chosen) return;

    unit = chosen;
    save();
    show();

    _ = api.call(session, protocol.pack(.reload, @intFromEnum(catalog.Reload.weather))) catch {

    };

}
