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
    .{ .image = .screenshots, .title = "Screenshots", .icon = .cut, .summary = "Snip the screen and keep your screenshots" },
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

/// The folder in each home that screenshots and snips are saved in.
pub const screenshots = "Screenshots";

/// What went wrong with a file, as people read it.
pub fn reason(err: api.ServiceError) []const u8 {

    return switch (err) {

        error.Missing => "Not found.",
        error.Exists => "Something with that name already exists.",
        error.Full => "The volume is full.",
        error.Busy => "Only empty folders can be deleted.",
        error.Denied => "Permission denied.",
        error.Invalid => "That can't be done here.",
        else => "The file service is unavailable.",

    };

}

pub const unnamed = "Names need a character or two, and no slashes.";

/// Whether `name` may name a file or folder.
pub fn valid(name: []const u8) bool {

    return name.len != 0 and name.len <= 200 and std.mem.indexOfScalar(u8, name, '/') == null and !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..");

}

/// A size in bytes as people read it, such as `4.2 KB`.
pub fn amount(allocator: std.mem.Allocator, bytes: u64) ![]const u8 {

    const units = [_][]const u8{ "bytes", "KB", "MB", "GB" };
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;

    while (value >= 1024 and unit + 1 < units.len) : (unit += 1) value /= 1024;

    if (unit == 0) return std.fmt.allocPrint(allocator, "{d} {s}", .{ bytes, units[0] });

    return std.fmt.allocPrint(allocator, "{d:.1} {s}", .{ value, units[unit] });

}

/// The home directory `/home/NAME` an app was launched with, or what `argument` lies under; null when it names none.
pub fn home(argument: []const u8) ?[]const u8 {

    if (!std.mem.startsWith(u8, argument, "/home/")) return null;

    const end = std.mem.indexOfScalarPos(u8, argument, 6, '/') orelse argument.len;

    return argument[0..end];

}
