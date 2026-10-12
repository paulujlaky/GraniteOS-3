const Lock = @import("../kernel/lock.zig").Lock;

// Processors share one output, so each line holds this while it is written.
var lock: Lock = .{};

/// Set once a kernel failure has stopped the other processors, any of which may have stopped holding the lock.
pub var stopped = false;

pub const Log = struct {

    output: *const fn ([]const u8) void,
    scope: []const u8,

    pub fn line(self: Log, text: []const u8) void {

        begin();
        defer end();

        self.prefix();
        self.output(text);
        self.output("\n");

    }

    pub fn err(self: Log, message: []const u8) void {

        begin();
        defer end();

        self.prefix();
        self.output("error: ");
        self.output(message);
        self.output("\n");

    }

    /// Writes `bytes` unprefixed, such as a line a process wrote.
    pub fn write(self: Log, bytes: []const u8) void {

        begin();
        defer end();

        self.output(bytes);

    }

    pub fn decimal(self: Log, label: []const u8, value: u64) void {

        self.number(label, value, 10);

    }

    pub fn hex(self: Log, label: []const u8, value: u64) void {

        self.number(label, value, 16);

    }

    fn prefix(self: Log) void {

        self.output(self.scope);
        self.output(": ");

    }

    fn number(self: Log, label: []const u8, value: u64, comptime base: u8) void {

        const digits = "0123456789abcdef";

        var buffer: [20]u8 = undefined;
        var start = buffer.len;

        var remaining = value;

        while (true) {

            start -= 1;
            buffer[start] = digits[@intCast(remaining % base)];

            remaining /= base;
            if (remaining == 0) break;

        }

        begin();
        defer end();

        self.prefix();
        self.output(label);
        self.output(" = ");

        if (base == 16) self.output("0x");

        self.output(buffer[start..]);
        self.output("\n");

    }

};

fn begin() void {

    if (!stopped) lock.acquire();

}

fn end() void {

    if (!stopped) lock.release();

}
