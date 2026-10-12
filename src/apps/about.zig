//! About GraniteOS: the system's name, what it can do, and what it is running on, opened from the wallpaper's menu.

const std = @import("std");

const release = @import("release.zig");

const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;

/// Height of each line in the two lists.
const line = 26;

const Fact = struct {

    icon: gui.Icon,
    title: []const u8,

};

const facts = [_]Fact{

    .{ .icon = .cpu, .title = "Processors" },
    .{ .icon = .memory, .title = "Memory" },
    .{ .icon = .monitor, .title = "Display" },
    .{ .icon = .image, .title = "Graphics" },
    .{ .icon = .activity, .title = "Rendering" },
    .{ .icon = .clock, .title = "Up for" },
    .{ .icon = .user, .title = "Signed in as" },

};

// The heading: the name with its stage beside it, lighter, then what the system is.
var name = gui.label(release.name, .{

    .size = theme.large,

});

var edition = gui.label(release.edition, .{

    .size = theme.large,
    .color = theme.faint,

});

var name_parts = [_]*gui.Node{ &name, &edition };
var name_row = gui.box(.{

    .direction = .row,
    .gap = 10,

}, &name_parts);

var tagline = gui.label(release.tagline, theme.caption);
var heading_parts = [_]*gui.Node{ &name_row, &tagline };

var heading = gui.box(.{

    .gap = 6,

}, &heading_parts);

var rule = gui.box(theme.rule, &.{});

/// Each list's title, a little apart from its first line.
const heading_look = theme.caption.with(.{

    .padding = .{

        .bottom = 6,

    },

});

// This computer, a fact to a line.
var fact_title = gui.label("This computer", heading_look);
var fact_icons: [facts.len]gui.Node = undefined;
var fact_keys: [facts.len]gui.Node = undefined;
var fact_values: [facts.len]gui.Node = undefined;
var fact_bytes: [facts.len][48]u8 = undefined;
var fact_parts: [facts.len][3]*gui.Node = undefined;
var fact_rows: [facts.len]gui.Node = undefined;
var fact_list: [facts.len + 1]*gui.Node = undefined;

var fact_column = gui.box(.{

    .width = 260,

}, &fact_list);

// What it can do, as the shell's `about` lists it.
var feature_title = gui.label("OS Features", heading_look);
var feature_icons: [release.features.len]gui.Node = undefined;
var feature_labels: [release.features.len]gui.Node = undefined;
var feature_parts: [release.features.len][2]*gui.Node = undefined;
var feature_rows: [release.features.len]gui.Node = undefined;
var feature_list: [release.features.len + 1]*gui.Node = undefined;

var feature_column = gui.box(.{

    .grow = 1,

}, &feature_list);

var body_parts = [_]*gui.Node{ &fact_column, &feature_column };

var body = gui.box(.{

    .direction = .row,
    .gap = 32,

}, &body_parts);

var parts = [_]*gui.Node{ &heading, &rule, &body };

var root = gui.box(.{

    .padding = .all(28),
    .gap = 22,

}, &parts);

pub var window: gui.Window = undefined;

pub fn init() void {

    fact_list[0] = &fact_title;

    for (facts, 0..) |fact, index| {

        fact_icons[index] = gui.icon(fact.icon, theme.icon.with(.{

            .color = theme.muted,

        }));

        fact_keys[index] = gui.label(fact.title, theme.caption.with(.{

            .width = 92,

        }));

        fact_values[index] = gui.label("", .{

            .size = theme.small,
            .grow = 1,

        });

        fact_parts[index] = .{ &fact_icons[index], &fact_keys[index], &fact_values[index] };
        fact_rows[index] = row(&fact_parts[index]);
        fact_list[index + 1] = &fact_rows[index];

    }

    feature_list[0] = &feature_title;

    for (release.features, 0..) |feature, index| {

        feature_icons[index] = gui.icon(.check, theme.icon.with(.{

            .color = theme.muted,

        }));

        feature_labels[index] = gui.label(feature, .{

            .size = theme.small,

        });

        feature_parts[index] = .{ &feature_icons[index], &feature_labels[index] };
        feature_rows[index] = row(&feature_parts[index]);
        feature_list[index + 1] = &feature_rows[index];

    }

    window = gui.Window.open(&root, .{

        .title = "About GraniteOS",

        .width = 700,
        .height = 437,

        .fixed = true,
        .hidden = true,

    }) catch api.exit(3);

}

fn row(children: []const *gui.Node) gui.Node {

    return gui.box(.{

        .direction = .row,
        .height = line,

        .gap = 10,
        .items = .center,

    }, children);

}

/// Shows the window with current figures, for `account`.
pub fn show(account: []const u8) void {

    var records: [1]api.abi.Usage = undefined;
    const summary = api.stats(&records) catch api.abi.Summary{};
    const screen = gui.screen() catch gui.Rect{};
    const adapter = gui.display.adapter() catch api.display.Adapter{};
    const minutes = summary.uptime / 100 / 60;

    const texts = [_][]const u8{

        std.fmt.bufPrint(&fact_bytes[0], "{d}", .{summary.processors}) catch "",
        std.fmt.bufPrint(&fact_bytes[1], "{d} MB", .{summary.pages * 4 / 1024}) catch "",
        std.fmt.bufPrint(&fact_bytes[2], "{d} x {d}", .{ screen.width, screen.height }) catch "",

        adapter.name(),
        adapter.rendering(),

        if (minutes < 60) std.fmt.bufPrint(&fact_bytes[5], "{d} min", .{minutes}) catch "" else std.fmt.bufPrint(&fact_bytes[5], "{d} h {d} min", .{ minutes / 60, minutes % 60 }) catch "",
        account,

    };

    for (texts, 0..) |text, index| fact_values[index].content.label = text;

    window.show();
    window.refresh();

}

pub fn hide() void {

    if (!window.surface.hidden) window.hide();

}
