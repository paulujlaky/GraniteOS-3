//! The window switcher: Alt+Tab shows every window, most recent first, and releasing Alt brings the chosen one forward.

const catalog = @import("catalog.zig");
const menu = @import("menu.zig");

const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;

/// The most windows offered at once.
const most = 8;

const tile = 116;

var windows: [64]api.display.Window = undefined;

/// Windows offered, most recent first, and which is chosen.
var offered: [most]api.display.Window = undefined;
var count: usize = 0;
var chosen: usize = 0;

var icons: [most]gui.Node = undefined;
var titles: [most]gui.Node = undefined;
var parts: [most][2]*gui.Node = undefined;
var tiles: [most]gui.Node = undefined;
var list: [most]*gui.Node = undefined;
var root = gui.box(menu.popup.with(.{

    .padding = gui.Edges.all(10),
    .direction = .row,
    .gap = 6,

}), &list);

pub var window: gui.Window = undefined;

/// The screen, to centre the switcher on.
var screen = gui.Rect{};

pub fn init(size: gui.Rect) void {

    for (&tiles, 0..) |*entry, index| {

        icons[index] = gui.icon(.app, theme.icon.with(.{

            .width = null,
            .size = 30,

        }));
        titles[index] = gui.label("", theme.caption.with(.{

            .text_align = .center,

        }));
        parts[index] = .{ &icons[index], &titles[index] };
        entry.* = gui.box(theme.item.with(.{

            .width = tile,
            .height = 96,
            .padding = gui.Edges.all(8),
            .direction = .column,
            .gap = 8,
            .justify = .center,

        }), &parts[index]);
        entry.action = &pick;
        entry.data = index;
        list[index] = entry;

    }

    screen = size;
    window = gui.Window.open(&root, .{

        .layer = .overlay,
        .width = tile,
        .height = 116,
        .hidden = true,
        .motion = .fade,

    }) catch api.exit(3);

}

pub fn place(size: gui.Rect) void {

    screen = size;

}

/// Handles the keys of switching, from whichever desktop surface they reached; true when they were the switcher's.
pub fn react(event: api.Event) bool {

    if (event.kind != .key) return false;

    const shown = !window.surface.hidden;

    if (event.pressed and event.modifiers.alt and event.key() == .tab) {

        if (!shown) return open(event.modifiers.shift);

        step(event.modifiers.shift);

        return true;

    }

    if (!shown) return false;

    if (event.key() == .alt and !event.pressed) {

        finish(chosen);

    } else if (event.pressing(.escape)) {

        window.hide();

    } else if (event.pressing(.right) or event.pressing(.left)) {

        step(event.key() == .left);

    } else if (event.pressing(.enter)) {

        finish(chosen);

    }

    return true;

}

/// Offers every window, and chooses the one behind the window in front, or the one in front when going backwards.
fn open(backwards: bool) bool {

    const total = gui.display.windows(&windows) catch 0;

    count = 0;

    // The list runs bottom to top, so the most recent comes last.
    var index = total;

    while (index > 0 and count < most) {

        index -= 1;
        offered[count] = windows[index];
        count += 1;

    }

    if (count == 0) return true;

    for (0..most) |slot| {

        tiles[slot].hidden = slot >= count;
        if (slot >= count) continue;

        const app = if (offered[slot].application == api.display.Spec.none) null else catalog.find(@enumFromInt(offered[slot].application));

        icons[slot].content.label = (if (app) |found| found.icon else gui.Icon.app).text();
        titles[slot].content.label = offered[slot].name();

    }

    chosen = if (count == 1 or offered[0].state.minimized) 0 else if (backwards) count - 1 else 1;
    mark();

    const size: i32 = @intCast(count);
    const width = size * tile + (size - 1) * 6 + 20;

    window.move(screen.centered(width, 116));
    window.show();

    return true;

}

fn step(backwards: bool) void {

    chosen = if (backwards) (chosen + count - 1) % count else (chosen + 1) % count;
    mark();

}

fn mark() void {

    for (&tiles, 0..) |*entry, index| entry.selected = index == chosen;
    window.refresh();

}

fn pick(node: *gui.Node) void {

    finish(node.data);

}

/// Puts the switcher away and brings window `index` forward.
fn finish(index: usize) void {

    window.hide();
    if (index < count) gui.display.activate(offered[index].id, .raise) catch {

    };

}
