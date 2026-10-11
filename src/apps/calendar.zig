//! Calendar: any month as weeks from Monday with ISO week numbers, today marked, and US federal holidays worked out for each year.

const std = @import("std");

const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;
const time = api.time;
pub const panic = api.panic;

const Day = struct {

    year: u16,
    month: u8,
    day: u8,

    fn today() Day {

        const date = api.Date.init(api.clock());

        return .{

            .year = date.year,
            .month = date.month,
            .day = date.day,

        };

    }

    /// Days since Monday.
    fn weekday(self: Day) u8 {

        return (time.weekday(self.year, self.month, self.day) + 6) % 7;

    }

    /// The day `count` days later, or earlier when negative.
    fn add(self: Day, count: i32) Day {

        var result = self;
        var left = count;

        while (left > 0) : (left -= 1) {

            result.day += 1;
            if (result.day <= time.length(result.year, result.month)) continue;

            result.day = 1;
            result = result.shift(1);

        }

        while (left < 0) : (left += 1) {

            if (result.day > 1) {

                result.day -= 1;
                continue;

            }

            result = result.shift(-1);
            result.day = time.length(result.year, result.month);

        }

        return result;

    }

    /// The same day `count` months later, or earlier, kept within the month.
    fn shift(self: Day, count: i32) Day {

        const months = @as(i32, self.year) * 12 + self.month - 1 + count;
        const year: u16 = @intCast(std.math.clamp(@divFloor(months, 12), 1970, 9999));
        const month: u8 = @intCast(@mod(months, 12) + 1);

        return .{

            .year = year,
            .month = month,
            .day = @min(self.day, time.length(year, month)),

        };

    }

    /// Days since the start of the year, counting from 1.
    fn ordinal(self: Day) u16 {

        var total: u16 = self.day;

        for (1..self.month) |month| total += time.length(self.year, @intCast(month));

        return total;

    }

    /// The ISO 8601 week: weeks start on Monday, and the first holds the year's first Thursday.
    fn week(self: Day) u8 {

        const number = @divFloor(@as(i32, self.ordinal()) - self.weekday() + 9, 7);

        if (number < 1) return weeks(self.year - 1);
        if (number > weeks(self.year)) return 1;

        return @intCast(number);

    }

    fn same(self: Day, other: Day) bool {

        return std.meta.eql(self, other);

    }

};

/// Weeks in ISO year `year`: 53 when it starts on a Thursday, or on a Wednesday in a leap year.
fn weeks(year: u16) u8 {

    const first = (time.weekday(year, 1, 1) + 6) % 7;
    const leap = time.length(year, 2) == 29;

    return if (first == 3 or (first == 2 and leap)) 53 else 52;

}

/// The US federal holiday on `day`, if any.
fn holiday(day: Day) ?[]const u8 {

    const nth = (day.day - 1) / 7 + 1;
    const last = day.day + 7 > time.length(day.year, day.month);
    const weekday = day.weekday();

    return switch (day.month) {

        1 => if (day.day == 1) "New Year's Day" else if (weekday == 0 and nth == 3) "Martin Luther King Jr. Day" else null,
        2 => if (weekday == 0 and nth == 3) "Washington's Birthday" else null,
        5 => if (weekday == 0 and last) "Memorial Day" else null,
        6 => if (day.day == 19) "Juneteenth" else null,
        7 => if (day.day == 4) "Independence Day" else null,
        9 => if (weekday == 0 and nth == 1) "Labor Day" else null,
        10 => if (weekday == 0 and nth == 2) "Columbus Day" else null,
        11 => if (day.day == 11) "Veterans Day" else if (weekday == 3 and nth == 4) "Thanksgiving Day" else null,
        12 => if (day.day == 25) "Christmas Day" else null,
        else => null,

    };

}

/// "1" to "53", for days and weeks.
const numerals = blk: {

    var list: [54][]const u8 = undefined;

    @setEvalBranchQuota(20000);
    for (&list, 0..) |*entry, number| entry.* = std.fmt.comptimePrint("{d}", .{number});

    break :blk list;

};

var window: gui.Window = undefined;

/// The month shown, by its first day, and the day picked in it.
var shown = Day{ .year = 1970, .month = 1, .day = 1 };
var picked = Day{ .year = 1970, .month = 1, .day = 1 };
var now = Day{ .year = 1970, .month = 1, .day = 1 };

var back = gui.tool(.left, &earlier);
var title_bytes: [32]u8 = undefined;
var title = gui.label("", theme.title_text.with(.{

    .grow = 1,
    .text_align = .center,

}));
var forward = gui.tool(.right, &later);
var today_button = gui.button("Today", &home);
var bar_parts = [_]*gui.Node{ &back, &title, &forward, &today_button };
var bar = gui.box(theme.bar.with(.{

    .padding = gui.Edges.axes(6, theme.spacing),

}), &bar_parts);

var heads: [8]gui.Node = undefined;
var head_list: [8]*gui.Node = undefined;
var head = gui.box(.{

    .direction = .row,
    .gap = 2,

}, &head_list);

var week_labels: [6]gui.Node = undefined;
var numbers: [42]gui.Node = undefined;
var dots: [42]gui.Node = undefined;
var dot_rows: [42]gui.Node = undefined;
var dot_parts: [42][1]*gui.Node = undefined;
var cell_parts: [42][2]*gui.Node = undefined;
var cells: [42]gui.Node = undefined;
var row_parts: [6][8]*gui.Node = undefined;
var rows: [6]gui.Node = undefined;
var row_list: [6]*gui.Node = undefined;
var grid = gui.box(.{

    .grow = 1,
    .gap = 2,

}, &row_list);
var month_parts = [_]*gui.Node{ &head, &grid };
var month_box = gui.box(.{

    .grow = 1,
    .padding = .axes(theme.gap, theme.spacing),
    .gap = 4,

}, &month_parts);

var detail_bytes: [64]u8 = undefined;
var detail = gui.label("", .{});
var note_bytes: [96]u8 = undefined;
var note = gui.label("", theme.caption);
var footer_parts = [_]*gui.Node{ &detail, &note };
var footer = gui.box(theme.panel.with(.{

    .gap = 4,

}), &footer_parts);
var footer_frame_parts = [_]*gui.Node{&footer};
var footer_frame = gui.box(.{

    .padding = gui.Edges{ .right = theme.spacing, .bottom = theme.spacing, .left = theme.spacing },

}, &footer_frame_parts);

var parts = [_]*gui.Node{ &bar, &month_box, &footer_frame };
var root = gui.box(.{}, &parts);

/// A day: its number in the middle, over a holiday's dot near the bottom.
const day_style = gui.Style{

    .grow = 1,
    .direction = .stack,

    .radius = theme.radius,

    .hover = .{

        .background = theme.hover,

    },
    .selected = .{

        .background = theme.selected,

    },
    .focus = .{

        .background = theme.hover,

    },

};

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .application);

    heads[0] = gui.label("Wk", theme.caption.with(.{

        .width = 30,
        .text_align = .center,

    }));
    head_list[0] = &heads[0];

    for (1..8) |index| {

        heads[index] = gui.label(time.days[index % 7][0..3], theme.caption.with(.{

            .grow = 1,
            .text_align = .center,

        }));
        head_list[index] = &heads[index];

    }

    for (&rows, 0..) |*row, line| {

        week_labels[line] = gui.label("", theme.caption.with(.{

            .width = 30,
            .color = theme.faint,
            .text_align = .center,

        }));
        row_parts[line][0] = &week_labels[line];

        for (0..7) |column| {

            const index = line * 7 + column;

            numbers[index] = gui.label("", .{

                .text_align = .center,

            });
            dots[index] = gui.box(.{

                .width = 4,
                .height = 4,

                .background = theme.accent,
                .radius = 2,

            }, &.{});
            dot_parts[index] = .{&dots[index]};
            dot_rows[index] = gui.box(.{

                .padding = .{

                    .bottom = 6,

                },
                .justify = .end,
                .items = .center,

            }, &dot_parts[index]);
            cell_parts[index] = .{ &numbers[index], &dot_rows[index] };
            cells[index] = gui.box(day_style, &cell_parts[index]);
            cells[index].action = &pick;
            cells[index].data = index;
            row_parts[line][column + 1] = &cells[index];

        }

        row.* = gui.box(.{

            .grow = 1,
            .direction = .row,
            .gap = 2,

        }, &row_parts[line]);
        row_list[line] = row;

    }

    now = Day.today();
    go(now);

    window = gui.Window.open(&root, .{

        .title = "Calendar",
        .application = .calendar,
        .width = 440,
        .height = 470,

    }) catch api.exit(3);

    while (true) {

        // Today moves on at midnight, so the calendar checks now and then.
        const event = window.next(3000) orelse {

            if (!now.same(Day.today())) {

                now = Day.today();
                fill();
                window.refresh();

            }

            continue;

        };

        if (event.kind == .close) window.quit();
        if (event.kind == .key and event.pressed) key(event);

    }

}

fn key(event: api.Event) void {

    switch (event.key()) {

        .left => jump(picked.add(-1)),
        .right => jump(picked.add(1)),
        .up => jump(picked.add(-7)),
        .down => jump(picked.add(7)),
        .page_up => jump(picked.shift(-1)),
        .page_down => jump(picked.shift(1)),
        .home => jump(now),
        .character => if (event.char | 0x20 == 't') jump(now),
        else => {

        },

    }

}

/// Picks `day`, showing its month.
fn go(day: Day) void {

    picked = day;
    shown = .{

        .year = day.year,
        .month = day.month,
        .day = 1,

    };
    fill();

}

/// The day in grid cell `index` of the month shown.
fn at(index: usize) Day {

    return shown.add(@as(i32, @intCast(index)) - shown.weekday());

}

fn fill() void {

    title.content.label = std.fmt.bufPrint(&title_bytes, "{s} {d}", .{ time.months[shown.month - 1], shown.year }) catch "";

    for (&cells, 0..) |*entry, index| {

        const day = at(index);
        const inside = day.month == shown.month;
        const weekend = index % 7 >= 5;

        numbers[index].content.label = numerals[day.day];
        numbers[index].style.color = if (!inside) theme.faint else if (weekend) theme.muted else theme.text;
        dots[index].hidden = holiday(day) == null;
        dots[index].style.background = if (inside) theme.accent else theme.faint;
        entry.selected = day.same(picked);

        // Today wears a ring.
        entry.style.border = if (day.same(now)) theme.accent else null;
        entry.style.border_width = if (day.same(now)) theme.border else 0;

        if (index % 7 == 0) week_labels[index / 7].content.label = numerals[day.week()];

    }

    detail.content.label = std.fmt.bufPrint(&detail_bytes, "{s}, {d} {s} {d}", .{ time.days[time.weekday(picked.year, picked.month, picked.day)], picked.day, time.months[picked.month - 1], picked.year }) catch "";
    note.content.label = std.fmt.bufPrint(&note_bytes, "{s}{s}Week {d}, day {d} of the year", .{ holiday(picked) orelse "", if (holiday(picked) != null) "  \u{00b7}  " else "", picked.week(), picked.ordinal() }) catch "";
    today_button.hidden = picked.same(now);

}

/// Picks `day` once the window is open, and shows it.
fn jump(day: Day) void {

    go(day);
    window.refresh();

}

fn pick(node: *gui.Node) void {

    jump(at(node.data));

}

fn earlier(_: *gui.Node) void {

    jump(picked.shift(-1));

}

fn later(_: *gui.Node) void {

    jump(picked.shift(1));

}

fn home(_: *gui.Node) void {

    jump(now);

}
