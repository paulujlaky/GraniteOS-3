//! The app launcher: a search field over the categories down the side and the apps of the one picked, or over every app
//! the search matches.

const std = @import("std");

const catalog = @import("catalog.zig");
const desktop = @import("desktop.zig");
const pins = @import("pins.zig");

const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;
const Category = catalog.Category;

const categories = std.enums.values(Category);

/// Rows down the side: every app, then each category.
const sections = categories.len + 1;

var search_bytes: [64]u8 = undefined;

var search_text = gui.Text{

    .buffer = &search_bytes,
    .placeholder = "Search apps",

};

var search = gui.input(&search_text);
var searched: u64 = 0;

/// The category picked, or null for every app.
var picked: ?Category = null;

var section_icons: [sections]gui.Node = undefined;
var section_titles: [sections]gui.Node = undefined;
var section_parts: [sections][2]*gui.Node = undefined;
var section_rows: [sections]gui.Node = undefined;
var section_list: [sections]*gui.Node = undefined;

var side = gui.box(.{

    .width = 160,
    .gap = 2,

}, &section_list);

var rule = gui.box(.{

    .width = theme.border,
    .background = theme.line,

}, &.{});

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

var none = gui.label("No apps match.", theme.caption.with(.{

    .grow = 1,
    .text_align = .center,

}));

var main_parts = [_]*gui.Node{ &list, &none };

var main = gui.box(.{

    .grow = 1,

}, &main_parts);

var body_parts = [_]*gui.Node{ &side, &rule, &main };

var body = gui.box(.{

    .grow = 1,
    .direction = .row,
    .gap = 10,

}, &body_parts);

var root_parts = [_]*gui.Node{ &search, &body };

var root = gui.box(theme.popup.with(.{

    .padding = gui.Edges.all(theme.spacing),
    .gap = 10,

}), &root_parts);

pub var window: gui.Window = undefined;

/// Opens the launcher, hidden, with its top-left corner at `at`.
pub fn init(at: gui.Point) void {

    for (0..sections) |index| {

        const category: ?Category = if (index == 0) null else categories[index - 1];

        section_icons[index] = gui.icon(if (category) |which| which.icon() else .grid, theme.icon);
        section_titles[index] = gui.label(if (category) |which| which.title() else "All apps", .{});
        section_parts[index] = .{ &section_icons[index], &section_titles[index] };
        section_rows[index] = gui.box(theme.item, &section_parts[index]);
        section_rows[index].action = &choose;
        section_rows[index].data = index;
        section_list[index] = &section_rows[index];

    }

    for (catalog.apps, 0..) |app, index| {

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
        entries[index].menu = &offer;
        entries[index].data = index;
        list_parts[index] = &entries[index];

    }

    search.action = &first;

    window = gui.Window.open(&root, .{

        .layer = .panel,

        .x = at.x,
        .y = at.y,
        .width = 620,
        .height = 440,

        .hidden = true,
        .motion = .drop,
        .shadow = true,

    }) catch api.exit(3);

}

/// Keeps the list to what the search matches; call it every pass of the event loop.
pub fn tick() void {

    // The search field takes its own keys, so a changed text is how typing shows.
    if (search_text.version != searched) filter();

}

/// Shows every app, with the search empty and focused.
pub fn show() void {

    picked = null;
    search_text.clear();
    filter();
    window.show();
    window.focus(&search);

}

pub fn hide() void {

    if (shown()) window.hide();

}

pub fn shown() bool {

    return !window.surface.hidden;

}

fn filter() void {

    const query = search_text.text();
    const current: usize = if (picked) |which| @intFromEnum(which) + 1 else 0;

    searched = search_text.version;

    for (catalog.apps, 0..) |app, index| {

        entries[index].hidden = if (query.len != 0) std.ascii.indexOfIgnoreCase(app.title, query) == null and std.ascii.indexOfIgnoreCase(app.summary, query) == null else picked != null and picked != app.category;

    }

    // A search spans every category, so none shows as picked meanwhile.
    for (&section_rows, 0..) |*row, index| {

        row.selected = query.len == 0 and index == current;

    }

    list.hidden = for (entries) |entry| {

        if (!entry.hidden) break false;

    } else true;

    none.hidden = !list.hidden;
    list.offset = 0;
    window.refresh();

}

fn choose(row: *gui.Node) void {

    picked = if (row.data == 0) null else categories[row.data - 1];
    search_text.clear();
    filter();

}

fn open(node: *gui.Node) void {

    desktop.start_app(catalog.apps[node.data].image, desktop.home);

}

/// Launches the first app the list shows.
fn first(_: *gui.Node) void {

    for (&entries) |*entry| {

        if (!entry.hidden) return open(entry);

    }

}

fn offer(node: *gui.Node, at: gui.Point) void {

    const area = window.surface.spec.area;

    pins.offer(catalog.apps[node.data].image, .{

        .x = area.x + at.x,
        .y = area.y + at.y,

    });

}
