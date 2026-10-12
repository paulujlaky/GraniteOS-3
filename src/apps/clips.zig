//! Clipboard history: everything copied lately, newest first; Super+V lists it, and choosing an entry copies it again.

const std = @import("std");

const notices = @import("notices.zig");

const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;

/// Entries kept, each as long as the clipboard holds.
const most = 8;
const longest = 64 * 1024;

const width = 420;

var entries: [most][longest]u8 = undefined;
var lengths = [_]usize{0} ** most;
var count: usize = 0;

/// What was just copied, read here rather than on the stack, which is too small for it.
var fresh_bytes: [longest]u8 = undefined;

var heading = gui.label("Clipboard", theme.caption.with(.{

    .grow = 1,

}));

var clear_button = gui.button("Clear", &clear);
var top_parts = [_]*gui.Node{ &heading, &clear_button };

var top = gui.box(.{

    .height = theme.control,

    .padding = .axes(0, 4),

    .direction = .row,
    .items = .center,

}, &top_parts);

var empty = gui.label("Nothing copied yet.", theme.caption.with(.{

    .height = 60,
    .text_align = .center,

}));

var previews: [most][96]u8 = undefined;
var lines: [most]gui.Node = undefined;
var details: [most]gui.Node = undefined;
var detail_bytes: [most][48]u8 = undefined;
var line_bytes: [most][24]u8 = undefined;
var row_parts: [most][2]*gui.Node = undefined;
var rows: [most]gui.Node = undefined;
var row_list: [most]*gui.Node = undefined;

var list = gui.box(.{

    .gap = 2,

}, &row_list);

var parts = [_]*gui.Node{ &top, &empty, &list };

var root = gui.box(theme.popup.with(.{

    .padding = gui.Edges.all(8),
    .gap = 4,

}), &parts);

pub var window: gui.Window = undefined;

var screen = gui.Rect{};

pub fn init(size: gui.Rect) void {

    for (&rows, 0..) |*row, index| {

        lines[index] = gui.label("", .{});
        details[index] = gui.label("", theme.caption);
        row_parts[index] = .{ &lines[index], &details[index] };

        row.* = gui.box(theme.item.with(.{

            .height = 50,

            .direction = .column,
            .gap = 2,
            .items = .stretch,
            .justify = .center,

        }), &row_parts[index]);

        row.action = &choose;
        row.data = index;
        row_list[index] = row;

    }

    screen = size;

    window = gui.Window.open(&root, .{

        .layer = .panel,

        .width = width,
        .height = 100,

        .hidden = true,
        .motion = .drop,
        .shadow = true,

    }) catch api.exit(3);

}

pub fn place(size: gui.Rect) void {

    screen = size;

}

/// Takes in what was just copied, moving it to the top if it was copied before.
pub fn copied() void {

    const fresh = gui.display.paste(&fresh_bytes) catch return;

    if (fresh.len == 0) return;

    // The same text again moves up rather than repeating; the oldest falls off when full.
    const found = for (0..count) |index| {

        if (std.mem.eql(u8, entries[index][0..lengths[index]], fresh)) break index;

    } else @min(count, most - 1);

    var index = found;

    while (index > 0) : (index -= 1) {

        @memcpy(entries[index][0..lengths[index - 1]], entries[index - 1][0..lengths[index - 1]]);
        lengths[index] = lengths[index - 1];

    }

    @memcpy(entries[0][0..fresh.len], fresh);
    lengths[0] = fresh.len;
    count = @min(@max(count, found + 1), most);
    if (!window.surface.hidden) fill();

}

/// Shows the history, or hides it when it shows.
pub fn toggle() void {

    if (!window.surface.hidden) return window.hide();

    fill();
    window.show();
    if (count != 0) window.focus(&rows[0]);

}

pub fn hide() void {

    if (!window.surface.hidden) window.hide();

}

/// Lays the entries out and sizes the surface to them.
fn fill() void {

    for (&rows, 0..) |*row, index| {

        row.hidden = index >= count;
        if (index >= count) continue;

        const bytes = entries[index][0..lengths[index]];
        var length: usize = 0;

        // One line of the text, its breaks and tabs as spaces, ending in an ellipsis when cut short.
        for (std.mem.trim(u8, bytes, " \t\r\n")) |char| {

            if (length + 3 >= previews[index].len) {

                @memcpy(previews[index][length..][0..3], "...");
                length += 3;
                break;

            }

            previews[index][length] = if (char == '\n' or char == '\r' or char == '\t') ' ' else char;
            length += 1;

        }

        // A cut can land inside a character, which then draws as a replacement mark.
        lines[index].content.label = previews[index][0..length];
        const characters = std.unicode.utf8CountCodepoints(bytes) catch bytes.len;
        const breaks = std.mem.count(u8, bytes, "\n");

        details[index].content.label = std.fmt.bufPrint(&detail_bytes[index], "{d} character{s}{s}", .{

            characters,
            if (characters == 1) "" else "s",
            if (breaks == 0) "" else std.fmt.bufPrint(&line_bytes[index], ", {d} lines", .{breaks + 1}) catch "",

        }) catch "";

    }

    empty.hidden = count != 0;
    clear_button.hidden = count == 0;

    const rows_height: i32 = @intCast(count * 50 + (count -| 1) * 2);
    const height = 16 + theme.control + 4 + if (count == 0) 60 else rows_height;

    window.move(screen.centered(width, height));

}

fn choose(node: *gui.Node) void {

    const index = node.data;

    window.hide();
    gui.display.copy(entries[index][0..lengths[index]]) catch return;
    notices.post(.clipboard, "Copied again", "Press Ctrl+V to paste it.", null);

}

fn clear(_: *gui.Node) void {

    count = 0;
    fill();

}
