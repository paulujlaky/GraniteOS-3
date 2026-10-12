//! The desktop's apps as people see them, and which app opens which file.

const std = @import("std");

const api = @import("api");
const gui = @import("gui");

const Image = api.abi.Image;

pub const App = struct {

    image: Image,
    title: []const u8,
    icon: gui.Icon,
    summary: []const u8,

};

pub const apps = [_]App{

    .{ .image = .explorer, .title = "Files", .icon = .folder, .summary = "Browse and organise your files" },
    .{ .image = .editor, .title = "Editor", .icon = .edit, .summary = "Write text and code" },
    .{ .image = .terminal, .title = "Terminal", .icon = .terminal, .summary = "Run OBSIDIAN shell commands" },
    .{ .image = .viewer, .title = "Viewer", .icon = .image, .summary = "Look at pictures" },
    .{ .image = .drawing, .title = "Drawing", .icon = .brush, .summary = "Sketch and paint pictures" },
    .{ .image = .calculator, .title = "Calculator", .icon = .calculator, .summary = "Work out sums" },
    .{ .image = .clock, .title = "Clock", .icon = .clock, .summary = "World time, stopwatch, and timer" },
    .{ .image = .calendar, .title = "Calendar", .icon = .calendar, .summary = "Months, weeks, and holidays" },
    .{ .image = .monitor, .title = "Monitor", .icon = .activity, .summary = "Watch processes, memory, and processors" },
    .{ .image = .settings, .title = "Settings", .icon = .settings, .summary = "Display, appearance, and accounts" },

};

/// Launches `image` with `argument`, the pointer showing busy until its window appears.
pub fn start(image: Image, argument: []const u8) api.ServiceError!void {

    gui.cursor.busy();
    _ = try api.launch(@tagName(image), argument);

}

pub fn find(image: Image) ?*const App {

    for (&apps) |*app| {

        if (app.image == image) return app;

    }

    return null;

}

/// The app that opens a file named `name`.
pub fn opener(name: []const u8) Image {

    return if (picture(name)) .viewer else .editor;

}

/// Whether `name` looks like an image the viewer reads.
pub fn picture(name: []const u8) bool {

    return std.ascii.endsWithIgnoreCase(name, ".png");

}

/// The icon for a file named `name`, or a directory.
pub fn symbol(name: []const u8, directory: bool) gui.Icon {

    if (directory) return .folder;
    if (picture(name)) return .image;

    for ([_][]const u8{ ".zig", ".c", ".h", ".py", ".sh", ".json", ".js", ".rs", ".go" }) |extension| {

        if (std.ascii.endsWithIgnoreCase(name, extension)) return .code;

    }

    return if (std.ascii.endsWithIgnoreCase(name, ".txt") or std.ascii.endsWithIgnoreCase(name, ".md")) .document else .file;

}

/// The home directory `/home/NAME` an app was launched with, or what `argument` lies under; null when it names none.
pub fn home(argument: []const u8) ?[]const u8 {

    if (!std.mem.startsWith(u8, argument, "/home/")) return null;

    const end = std.mem.indexOfScalarPos(u8, argument, 6, '/') orelse argument.len;

    return argument[0..end];

}
