const std = @import("std");

const api = @import("root.zig");

const protocol = api.protocol;
pub const FileError = api.ServiceError;

pub const Kind = enum(u8) {

    file = 1,
    directory = 2,
    _,

};

pub const Entry = struct {

    kind: Kind,
    size: u64,
    mode: u16,
    owner: u32,
    name: []const u8,

};

pub const Usage = struct {

    total: u64,
    free: u64,

};

/// Paths are absolute; every call resolves them afresh, so a restarted files service needs no reopening.
pub const Files = struct {

    endpoint: u64 = 0,
    window: [4096]u8 = undefined,

    pub fn create(self: *Files, path: []const u8) FileError!void {

        _ = try self.request(.create, 0, path, 0);

    }

    pub fn directory(self: *Files, path: []const u8) FileError!void {

        _ = try self.request(.directory, 0, path, 0);

    }

    pub fn remove(self: *Files, path: []const u8) FileError!void {

        _ = try self.request(.remove, 0, path, 0);

    }

    /// Moves or renames `from` to `to`, which must not exist yet.
    pub fn rename(self: *Files, from: []const u8, to: []const u8) FileError!void {

        if (from.len + to.len + 2 > self.window.len or std.mem.indexOfScalar(u8, to, 0) != null) return error.Invalid;

        @memcpy(self.window[from.len + 1 ..][0..to.len], to);
        self.window[from.len + 1 + to.len] = 0;
        _ = try self.request(.rename, 0, from, to.len + 1);

    }

    /// Reads all of file `path` into memory the caller frees with `allocator`.
    pub fn load(self: *Files, allocator: std.mem.Allocator, path: []const u8) FileError![]u8 {

        // Big reads lend the destination itself, so each call moves up to a quarter mebibyte.
        const chunk = 256 * 1024;
        var data: std.ArrayList(u8) = .empty;

        errdefer data.deinit(allocator);

        while (true) {

            data.ensureUnusedCapacity(allocator, chunk + path.len + 1) catch return error.Exhausted;

            const count = try self.fetch(path, @intCast(data.items.len), data.unusedCapacitySlice()[0 .. chunk + path.len + 1]);

            if (count == 0) break;
            data.items.len += count;

        }

        return data.toOwnedSlice(allocator) catch error.Exhausted;

    }

    /// Reads up to `buffer.len` bytes at `offset` straight into `buffer`, which carries the path there and so must be longer
    /// than it; returns how many, zero at the end.
    pub fn fetch(self: *Files, path: []const u8, offset: u56, buffer: []u8) FileError!usize {

        if (buffer.len <= path.len or std.mem.indexOfScalar(u8, path, 0) != null) return error.Invalid;

        @memcpy(buffer[0..path.len], path);
        buffer[path.len] = 0;

        return api.query(&self.endpoint, .files, protocol.pack(.read, offset), buffer);

    }

    /// Replaces file `path` with `bytes`, creating it if needed.
    pub fn save(self: *Files, allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) FileError!void {

        const chunk = 256 * 1024;
        const window = allocator.alloc(u8, path.len + 1 + @min(bytes.len, chunk)) catch return error.Exhausted;
        var done: usize = 0;

        defer allocator.free(window);

        try self.create(path);
        @memcpy(window[0..path.len], path);
        window[path.len] = 0;

        while (done < bytes.len) {

            const count = @min(bytes.len - done, chunk);

            @memcpy(window[path.len + 1 ..][0..count], bytes[done..][0..count]);
            if (try api.query(&self.endpoint, .files, protocol.pack(.write, @intCast(done)), window[0 .. path.len + 1 + count]) != count) return error.Invalid;
            done += count;

        }

    }

    /// Sets permission bits; only system services may pass an `owner` other than null.
    pub fn change(self: *Files, path: []const u8, mode: u16, owner: ?u32) FileError!void {

        _ = try self.request(.change, @as(u56, owner orelse api.abi.nobody.user) << 16 | mode, path, 0);

    }

    /// Reads up to `limit` bytes at `offset`; the bytes live in `window` until the next call.
    pub fn read(self: *Files, path: []const u8, offset: u56, limit: usize) FileError![]const u8 {

        const count = try self.request(.read, offset, path, @max(limit, path.len + 1) - path.len - 1);

        return self.window[0..count];

    }

    pub fn write(self: *Files, path: []const u8, offset: u56, bytes: []const u8) FileError!void {

        if (path.len + 1 + bytes.len > self.window.len) return error.Invalid;
        @memcpy(self.window[path.len + 1 ..][0..bytes.len], bytes);

        if (try self.request(.write, offset, path, bytes.len) != bytes.len) return error.Invalid;

    }

    /// Lists entries from `index` onward into `out`, returning how many fit in one reply.
    pub fn list(self: *Files, path: []const u8, index: u56, out: []Entry) FileError!usize {

        const count = try self.request(.list, index, path, self.window.len - path.len - 1);
        var offset: usize = 0;

        for (0..@min(count, out.len)) |entry| {

            const length = self.window[offset + 15];

            out[entry] = .{

                .kind = @enumFromInt(self.window[offset]),
                .size = std.mem.readInt(u64, self.window[offset + 1 ..][0..8], .little),
                .mode = std.mem.readInt(u16, self.window[offset + 9 ..][0..2], .little),
                .owner = std.mem.readInt(u32, self.window[offset + 11 ..][0..4], .little),
                .name = self.window[offset + 16 ..][0..length],

            };

            offset += 16 + length;

        }

        return @min(count, out.len);

    }

    /// The entry for `path`, found by listing its folder; its name lives in the window until the next call.
    pub fn find(self: *Files, path: []const u8) FileError!Entry {

        const folder = std.fs.path.dirnamePosix(path) orelse return error.Invalid;
        const name = std.fs.path.basenamePosix(path);
        var listed: [32]Entry = undefined;
        var index: u56 = 0;

        while (true) {

            const count = try self.list(folder, index, &listed);

            if (count == 0) return error.Missing;

            for (listed[0..count]) |entry| {

                if (std.mem.eql(u8, entry.name, name)) return entry;

            }

            index += @intCast(count);

        }

    }

    pub fn usage(self: *Files) FileError!Usage {

        _ = try self.request(.volume, 0, "", 15);

        return .{

            .total = std.mem.readInt(u64, self.window[0..8], .little),
            .free = std.mem.readInt(u64, self.window[8..16], .little),

        };

    }

    /// Sends `path` and a NUL, followed by `payload` bytes already placed in the window.
    fn request(self: *Files, operation: protocol.Operation, value: u56, path: []const u8, payload: usize) FileError!u64 {

        if (path.len + 1 + payload > self.window.len or std.mem.indexOfScalar(u8, path, 0) != null) return error.Invalid;

        @memcpy(self.window[0..path.len], path);
        self.window[path.len] = 0;

        return api.query(&self.endpoint, .files, protocol.pack(operation, value), self.window[0 .. path.len + 1 + payload]);

    }

};
