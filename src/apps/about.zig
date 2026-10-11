//! About GraniteOS: the system's name and what it is running on, opened from the wallpaper's menu.

const std = @import("std");

const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;

const facts = [_][]const u8{ "Processors", "Memory", "Display", "Up for", "Signed in as" };

var mark = gui.icon(.monitor, theme.icon.with(.{

    .width = null,
    .size = 40,
    .text_align = .center,

}));
var name = gui.label("GraniteOS", .{

    .size = theme.large,
    .text_align = .center,

});
var version = gui.label("Version 3, desktop preview", theme.caption.with(.{

    .text_align = .center,

}));
var keys: [facts.len]gui.Node = undefined;
var values: [facts.len]gui.Node = undefined;
var value_bytes: [facts.len][48]u8 = undefined;
var row_parts: [facts.len][2]*gui.Node = undefined;
var rows: [facts.len]gui.Node = undefined;
var row_list: [facts.len]*gui.Node = undefined;
var table = gui.box(theme.panel.with(.{

    .gap = 6,

}), &row_list);
var parts = [_]*gui.Node{ &mark, &name, &version, &table };
var root = gui.box(.{

    .padding = .all(20),
    .gap = 8,

}, &parts);

pub var window: gui.Window = undefined;

var user: []const u8 = "";

pub fn init() void {

    for (facts, 0..) |fact, index| {

        keys[index] = gui.label(fact, theme.caption.with(.{

            .grow = 1,

        }));
        values[index] = gui.label("", .{

            .size = theme.small,

        });
        row_parts[index] = .{ &keys[index], &values[index] };
        rows[index] = gui.box(.{

            .direction = .row,
            .items = .center,

        }, &row_parts[index]);
        row_list[index] = &rows[index];

    }

    window = gui.Window.open(&root, .{

        .title = "About GraniteOS",
        .width = 340,
        .height = 290,
        .fixed = true,
        .hidden = true,

    }) catch api.exit(3);

}

/// Shows the panel with current figures, for `account`.
pub fn show(account: []const u8) void {

    var records: [1]api.abi.Usage = undefined;
    const summary = api.stats(&records) catch api.abi.Summary{};
    const screen = gui.screen() catch gui.Rect{};
    const minutes = summary.uptime / 100 / 60;

    user = account;

    const texts = [_][]const u8{

        std.fmt.bufPrint(&value_bytes[0], "{d}", .{summary.processors}) catch "",
        std.fmt.bufPrint(&value_bytes[1], "{d} MB", .{summary.pages * 4 / 1024}) catch "",
        std.fmt.bufPrint(&value_bytes[2], "{d} x {d}", .{ screen.width, screen.height }) catch "",
        if (minutes < 60) std.fmt.bufPrint(&value_bytes[3], "{d} min", .{minutes}) catch "" else std.fmt.bufPrint(&value_bytes[3], "{d} h {d} min", .{ minutes / 60, minutes % 60 }) catch "",
        user,

    };

    for (texts, 0..) |text, index| values[index].content.label = text;

    window.show();
    window.refresh();

}

pub fn hide() void {

    if (!window.surface.hidden) window.hide();

}
