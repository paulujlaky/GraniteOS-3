//! Calendar: any month as weeks from Monday with ISO week numbers, today marked, and US federal holidays worked out for each year.

const std = @import("std");

const days = @import("days.zig");

const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;
const time = api.time;
const Day = days.Day;
const holiday = days.holiday;
const numerals = days.numerals;
pub const panic = api.panic;

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

    detail.content.label = time.Date.on(picked.year, picked.month, picked.day).long(&detail_bytes, true);
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
