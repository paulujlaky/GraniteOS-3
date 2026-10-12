//! App settings, kept as `key=value` lines in `/cfgs/OWNER/NAME.config`: OWNER is a user's name, whose folder only they
//! can read, or `system` for services.

const std = @import("std");

const api = @import("root.zig");

pub const root = "/cfgs";
pub const system = "system";

var files = api.Files{};

/// One config file read into memory; change it with `set` and write it back with `save`.
pub const Config = struct {

    path_bytes: [128]u8 = undefined,
    reach: usize = 0,

    bytes: [2048]u8 = undefined,
    length: usize = 0,

    /// Reads `/cfgs/OWNER/NAME.config`; one missing or unreadable reads as empty.
    pub fn open(self: *Config, owner: []const u8, name: []const u8) void {

        const path = if (owner.len == 0) "" else std.fmt.bufPrint(&self.path_bytes, "{s}/{s}/{s}.config", .{ root, owner, name }) catch "";

        self.reach = path.len;
        self.length = 0;
        if (path.len == 0) return;

        const bytes = files.read(path, 0, files.window.len) catch return;

        self.length = @min(bytes.len, self.bytes.len);
        @memcpy(self.bytes[0..self.length], bytes[0..self.length]);

    }

    /// The value of `key`, or null when it has none.
    pub fn get(self: *const Config, key: []const u8) ?[]const u8 {

        var values = self.all(key);

        return values.next();

    }

    /// The whole number `key` holds, or null when it holds none.
    pub fn number(self: *const Config, comptime T: type, key: []const u8) ?T {

        return std.fmt.parseInt(T, self.get(key) orelse return null, 10) catch null;

    }

    /// Every value `key` holds, for keys given more than one with `add`.
    pub fn all(self: *const Config, key: []const u8) Values {

        return .{

            .lines = std.mem.tokenizeAny(u8, self.bytes[0..self.length], "\r\n"),
            .key = key,

        };

    }

    /// Gives `key` `value`, a string or a whole number, in place of what it held; false when it does not fit on one line of the file.
    pub fn set(self: *Config, key: []const u8, value: anytype) bool {

        self.erase(key);

        return self.add(key, value);

    }

    /// Gives `key` `value` as well as what it holds; false when it does not fit on one line of the file.
    pub fn add(self: *Config, key: []const u8, value: anytype) bool {

        var scratch: [32]u8 = undefined;

        const text: []const u8 = switch (@typeInfo(@TypeOf(value))) {

            .int, .comptime_int => std.fmt.bufPrint(&scratch, "{d}", .{value}) catch return false,
            else => value,

        };

        const open_line = self.length != 0 and self.bytes[self.length - 1] != '\n';
        const needed = @intFromBool(open_line) + key.len + 1 + text.len + 1;

        if (self.length + needed > self.bytes.len or std.mem.indexOfAny(u8, text, "\r\n") != null) return false;

        const written = std.fmt.bufPrint(self.bytes[self.length..], "{s}{s}={s}\n", .{ if (open_line) "\n" else "", key, text }) catch unreachable;

        self.length += written.len;

        return true;

    }

    /// Drops `key` and its value.
    pub fn erase(self: *Config, key: []const u8) void {

        var kept: usize = 0;
        var start: usize = 0;

        while (start < self.length) {

            const end = if (std.mem.indexOfScalarPos(u8, self.bytes[0..self.length], start, '\n')) |found| found + 1 else self.length;
            const line = self.bytes[start..end];

            if (!holds(std.mem.trimRight(u8, line, "\r\n"), key)) {

                std.mem.copyForwards(u8, self.bytes[kept..], line);
                kept += line.len;

            }

            start = end;

        }

        self.length = kept;

    }

    /// Writes the file back, making its folder first if the caller may.
    pub fn save(self: *Config) api.ServiceError!void {

        if (self.reach == 0) return error.Invalid;

        const path = self.path_bytes[0..self.reach];

        // Services make their own folders; the accounts service makes each user's along with their account.
        for ([_][]const u8{ root, std.fs.path.dirnamePosix(path).? }) |folder| files.directory(folder) catch {

        };

        try files.create(path);
        try files.write(path, 0, self.bytes[0..self.length]);

    }

};

pub const Values = struct {

    lines: std.mem.TokenIterator(u8, .any),
    key: []const u8,

    pub fn next(self: *Values) ?[]const u8 {

        while (self.lines.next()) |line| {

            if (holds(line, self.key)) return line[self.key.len + 1 ..];

        }

        return null;

    }

};

fn holds(line: []const u8, key: []const u8) bool {

    return line.len > key.len and line[key.len] == '=' and std.mem.startsWith(u8, line, key);

}
