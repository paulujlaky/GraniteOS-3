const std = @import("std");

const api = @import("root.zig");

/// A shell's terminal: the serial service, or the graphical terminal that launched the shell.
pub const Terminal = struct {

    supervisor: u64,
    endpoint: u64 = 0,

    /// The graphical terminal to talk to instead of the serial service; zero for serial.
    host: u64 = 0,

    pub fn request(self: *Terminal, operation: api.protocol.Operation, value: u56) api.ApiError!u64 {

        if (self.endpoint == 0) self.endpoint = if (self.host != 0) self.host else try api.lookup(self.supervisor, .serial);

        return api.call(self.endpoint, api.protocol.pack(operation, value)) catch |err| {

            self.endpoint = 0;
            return err;

        };

    }

    /// Serial gets up to seven bytes per message, with NUL bytes dropped; a graphical host reads whole windows.
    pub fn write(self: *Terminal, bytes: []const u8) api.ApiError!void {

        if (self.host != 0) return self.lend(bytes);

        var chunk: u56 = 0;
        var count: u6 = 0;

        for (bytes, 0..) |byte, index| {

            const expanded = if (byte == '\n') "\r\n" else bytes[index .. index + 1];

            for (expanded) |output| {

                if (output == 0) continue;
                chunk |= @as(u56, output) << count * 8;
                count += 1;

                if (count == 7) {

                    try self.flush(chunk);
                    chunk = 0;
                    count = 0;

                }

            }

        }

        if (count != 0) try self.flush(chunk);

    }

    fn lend(self: *Terminal, bytes: []const u8) api.ApiError!void {

        var offset: usize = 0;

        while (offset < bytes.len) {

            const size = @min(bytes.len - offset, 4096);

            if (try api.exchange(self.host, api.protocol.pack(.write, size), @constCast(bytes[offset..][0..size])) != 0) return error.Invalid;
            offset += size;

        }

    }

    fn flush(self: *Terminal, chunk: u56) api.ApiError!void {

        if (try self.request(.write, chunk) != 0) return error.Invalid;

    }

    pub fn print(self: *Terminal, comptime format: []const u8, arguments: anytype) api.ApiError!void {

        var buffer: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, format, arguments) catch return error.Invalid;

        try self.write(text);

    }

    pub fn read(self: *Terminal) api.ApiError!?u8 {

        const value = try self.request(.read, 0);
        if (value == api.protocol.empty) return null;
        if (value > 255) return error.Invalid;

        return @intCast(value);

    }

};
