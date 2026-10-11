//! Editor: plain text and code in a monospaced font, opened from and saved to files.

const std = @import("std");

const catalog = @import("catalog.zig");

const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;
pub const panic = api.panic;

const control = api.Event.Modifiers{

    .control = true,

};

/// The largest document, in bytes.
const capacity = 4 << 20;

var window: gui.Window = undefined;
var files = api.Files{};

var text = gui.Text{

    .buffer = &.{},
    .placeholder = "Start typing...",

};
var page = gui.area(&text);

var path_bytes: [512]u8 = undefined;
var path: []const u8 = "";
var folder_bytes: [512]u8 = undefined;
var folder: []const u8 = "/";

/// The text's version when last opened or saved, to tell unsaved changes.
var saved: u64 = 0;

var create = gui.tool(.new, &startNew);
var load = gui.tool(.folder_open, &askOpen);
var keep = gui.tool(.save, &save);
var divider = gui.box(theme.divider, &.{});
var keep_as = gui.button("Save as", &askSave);
var name = gui.label("Untitled", .{

    .grow = 1,
    .padding = .axes(0, 6),

});
var tools = [_]*gui.Node{ &create, &load, &keep, &divider, &name, &keep_as };
var toolbar = gui.box(theme.bar, &tools);

var prompt = gui.Prompt{};

var position_bytes: [48]u8 = undefined;
var position = gui.label("", theme.caption.with(.{

    .grow = 1,

}));
var notice = gui.label("", theme.caption);
var status_parts = [_]*gui.Node{ &position, &notice };
var status = gui.box(.{

    .height = 26,
    .padding = .axes(0, theme.spacing),
    .direction = .row,
    .items = .center,

    .background = theme.raised,

}, &status_parts);
var parts = [_]*gui.Node{ &toolbar, &prompt.bar, &page, &status };
var root = gui.box(.{}, &parts);

var title_bytes: [96]u8 = undefined;
var shown: u64 = std.math.maxInt(u64);
var caret: usize = std.math.maxInt(usize);

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .application);
    prompt.init();

    const memory = api.share(capacity / 4096) catch api.exit(3);

    text.buffer = memory.bytes;
    page.style = theme.area.with(.{

        .height = null,
        .grow = 1,
        .face = .mono,
        .size = 14,
        .radius = 0,
        .border_width = 0,
        .padding = gui.Edges.axes(10, 14),
        .background = theme.background,

    });
    keep_as.style = keep_as.style.with(.{

        .height = 30,

    });

    var argument_bytes: [256]u8 = undefined;
    const argument = api.argument(&argument_bytes);

    folder = copy(&folder_bytes, catalog.home(argument) orelse "/");

    window = gui.Window.open(&root, .{

        .title = "Editor",
        .application = .editor,
        .width = 760,
        .height = 540,
        .capacity = 1024 * 1024,

    }) catch api.exit(3);

    if (argument.len != 0 and !std.mem.eql(u8, argument, folder)) open(argument);

    window.focus(&page);
    update();

    while (true) {

        const event = window.next(500) orelse {

            update();
            continue;

        };

        if (event.kind == .close) window.quit();
        react(event);
        update();

    }

}

fn react(event: api.Event) void {

    if (event.chord(control, 's')) return save(&keep);
    if (event.chord(control, 'o')) return askOpen(&load);
    if (event.chord(control, 'n')) return startNew(&create);
    if (event.pressing(.escape) and prompt.open()) {

        prompt.close();
        window.focus(&page);

    }

}

/// Keeps the title, name, and caret position current.
fn update() void {

    if (shown == text.version and caret == text.caret) return;

    shown = text.version;
    caret = text.caret;

    const modified = text.version != saved;
    const title = if (path.len == 0) "Untitled" else std.fs.path.basename(path);

    const heading = std.fmt.bufPrint(&title_bytes, "{s}{s} - Editor", .{ if (modified) "* " else "", title }) catch "Editor";

    name.content.label = if (path.len == 0) "Untitled" else path;
    if (!std.mem.eql(u8, heading, window.surface.spec.name())) window.retitle(heading);

    // Lines and columns count from one, columns in characters.
    const before = text.text()[0..text.caret];
    const line = std.mem.count(u8, before, "\n") + 1;
    const start = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |index| index + 1 else 0;
    const column = (std.unicode.utf8CountCodepoints(before[start..]) catch before.len - start) + 1;

    position.content.label = std.fmt.bufPrint(&position_bytes, "Line {d}, column {d}    {d} bytes", .{ line, column, text.length }) catch "";
    window.refresh();

}

fn open(target: []const u8) void {

    var scratch = std.heap.ArenaAllocator.init(api.pages);
    defer scratch.deinit();

    const bytes = files.load(scratch.allocator(), target) catch |err| return report(err);

    if (bytes.len > capacity) return say("That file is too large to edit.");

    text.set(bytes);
    text.select(0, false);
    saved = text.version;
    path = copy(&path_bytes, target);
    folder = copy(&folder_bytes, std.fs.path.dirnamePosix(target) orelse "/");
    say("");

}

fn startNew(_: *gui.Node) void {

    text.clear();
    saved = text.version;
    path = "";
    say("");
    window.focus(&page);

}

fn askOpen(_: *gui.Node) void {

    var initial: [520]u8 = undefined;

    prompt.ask(&window, "Open", std.fmt.bufPrint(&initial, "{s}/", .{folder}) catch folder, "Open", &openPath);

}

fn openPath(target: []const u8) void {

    open(target);
    window.focus(&page);

}

fn save(_: *gui.Node) void {

    if (path.len == 0) return askSave(&keep_as);

    write(path);

}

fn askSave(_: *gui.Node) void {

    var initial: [600]u8 = undefined;
    const suggestion = if (path.len != 0) path else std.fmt.bufPrint(&initial, "{s}/Untitled.txt", .{folder}) catch folder;

    prompt.ask(&window, "Save as", suggestion, "Save", &saveAs);

}

fn saveAs(target: []const u8) void {

    var kept: [512]u8 = undefined;
    const copied = copy(&kept, target);

    write(copied);

}

fn write(target: []const u8) void {

    var scratch = std.heap.ArenaAllocator.init(api.pages);
    defer scratch.deinit();

    files.save(scratch.allocator(), target, text.text()) catch |err| return report(err);

    saved = text.version;
    shown = std.math.maxInt(u64);
    path = copy(&path_bytes, target);
    folder = copy(&folder_bytes, std.fs.path.dirnamePosix(target) orelse "/");
    say("Saved.");
    window.focus(&page);

}

fn report(err: api.ServiceError) void {

    say(switch (err) {

        error.Missing => "That file or folder does not exist.",
        error.Denied => "Permission denied.",
        error.Full => "The volume is full.",
        error.Invalid => "That isn't a file that can be opened here.",
        else => "The file service is unavailable.",

    });

}

fn say(message: []const u8) void {

    notice.content.label = message;
    shown = std.math.maxInt(u64);
    window.refresh();

}

fn copy(out: []u8, value: []const u8) []const u8 {

    const length = @min(value.len, out.len);

    std.mem.copyForwards(u8, out[0..length], value[0..length]);

    return out[0..length];

}
