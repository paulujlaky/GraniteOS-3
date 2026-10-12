//! Notifications: short toasts at the top right of the desktop that fade after a few seconds or when clicked.

const std = @import("std");


const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;

/// The most toasts shown at once; a new one pushes out the oldest.
const most = 3;

/// Ticks a toast stays up.
const lasting = 800;

const width = 340;
const tall = 62;
const gap = 8;

const Toast = struct {

    icon: gui.Node,
    title: gui.Node,
    detail: gui.Node,
    words: [2]*gui.Node,
    text: gui.Node,
    parts: [2]*gui.Node,
    node: gui.Node,

    title_bytes: [64]u8,
    detail_bytes: [192]u8,
    since: u64,

};

var toasts: [most]Toast = undefined;
var list: [most]*gui.Node = undefined;
var root = gui.box(.{

    .gap = gap,

}, &list);

pub var window: gui.Window = undefined;

/// Where the toasts hang from: the top-right corner of the space below the bar.
var corner = gui.Point{};

pub fn init(screen: gui.Rect, top: i32) void {

    for (&toasts, 0..) |*toast, index| {

        toast.icon = gui.icon(.bell, theme.icon.with(.{

            .width = 24,
            .size = 18,

        }));
        toast.title = gui.label("", .{});
        toast.detail = gui.label("", theme.caption);
        toast.words = .{ &toast.title, &toast.detail };
        toast.text = gui.box(.{

            .grow = 1,
            .gap = 3,
            .justify = .center,

        }, &toast.words);
        toast.parts = .{ &toast.icon, &toast.text };
        toast.node = gui.box(theme.popup.with(.{

            .height = tall,
            .padding = gui.Edges.axes(0, theme.spacing),
            .direction = .row,
            .gap = theme.spacing,
            .items = .center,

            .hover = .{

                .background = theme.hover,

            },

        }), &toast.parts);
        toast.node.action = &dismiss;
        toast.node.data = index;
        toast.node.hidden = true;
        list[index] = &toast.node;

    }

    window = gui.Window.open(&root, .{

        .layer = .panel,
        .width = width,
        .height = tall,
        .hidden = true,
        .motion = .drop,

    }) catch api.exit(3);

    place(screen, top);

}

/// Keeps the toasts under the bar of a `screen`-sized display whose bar is `top` rows tall.
pub fn place(screen: gui.Rect, top: i32) void {

    corner = .{

        .x = screen.width - width - gap,
        .y = top + gap,

    };
    fit();

}

/// Shows a toast saying `title` over `detail`, newest at the top.
pub fn post(icon: gui.Icon, title: []const u8, detail: []const u8) void {

    // The oldest makes room, then every toast moves down one.
    var index: usize = most - 1;

    while (index > 0) : (index -= 1) copy(&toasts[index], &toasts[index - 1]);

    const toast = &toasts[0];
    const title_length = @min(title.len, toast.title_bytes.len);
    const detail_length = @min(detail.len, toast.detail_bytes.len);

    @memcpy(toast.title_bytes[0..title_length], title[0..title_length]);
    @memcpy(toast.detail_bytes[0..detail_length], detail[0..detail_length]);
    toast.icon.content.label = icon.text();
    toast.title.content.label = toast.title_bytes[0..title_length];
    toast.detail.content.label = toast.detail_bytes[0..detail_length];
    toast.detail.hidden = detail_length == 0;
    toast.node.hidden = false;
    toast.since = api.ticks();
    fit();

}

/// Takes down toasts that have been up long enough; call it every pass of the event loop.
pub fn tick() void {

    const now = api.ticks();
    var changed = false;

    for (&toasts) |*toast| {

        if (toast.node.hidden or now - toast.since < lasting) continue;

        toast.node.hidden = true;
        changed = true;

    }

    if (changed) fit();

}

/// Hides every toast, such as when the session ends.
pub fn clear() void {

    for (&toasts) |*toast| toast.node.hidden = true;
    fit();

}

fn dismiss(node: *gui.Node) void {

    toasts[node.data].node.hidden = true;
    fit();

}

/// Sizes the surface to the toasts showing, hiding it when there are none.
fn fit() void {

    var count: i32 = 0;

    for (&toasts) |*toast| {

        if (!toast.node.hidden) count += 1;

    }

    if (count == 0) return window.hide();

    window.move(.{

        .x = corner.x,
        .y = corner.y,
        .width = width,
        .height = count * tall + (count - 1) * gap,

    });
    window.show();

}

/// Moves `from`'s message into `to`, keeping each toast's nodes pointing at its own bytes.
fn copy(to: *Toast, from: *const Toast) void {

    to.title_bytes = from.title_bytes;
    to.detail_bytes = from.detail_bytes;
    to.icon.content.label = from.icon.content.label;
    to.title.content.label = to.title_bytes[0..from.title.content.label.len];
    to.detail.content.label = to.detail_bytes[0..from.detail.content.label.len];
    to.detail.hidden = from.detail.hidden;
    to.node.hidden = from.node.hidden;
    to.since = from.since;

}
