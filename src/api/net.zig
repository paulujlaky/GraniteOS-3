//! The network from an app's side: the link and its addresses, names, echoes, and TCP and UDP connections, all through
//! the net service. Only apps granted the `network` permission reach it.

const std = @import("std");

const api = @import("root.zig");

const protocol = api.protocol;
pub const NetError = api.ServiceError || error{ Offline, Refused };

/// An IPv4 address, most significant octet first.
pub const Address = extern struct {

    octets: [4]u8 = .{ 0, 0, 0, 0 },

    pub fn from(number: u32) Address {

        return .{

            .octets = @bitCast(std.mem.nativeToBig(u32, number)),

        };

    }

    pub fn value(self: Address) u32 {

        return std.mem.bigToNative(u32, @bitCast(self.octets));

    }

    pub fn empty(self: Address) bool {

        return self.value() == 0;

    }

    /// Reads dotted decimal, such as `10.0.0.1`.
    pub fn parse(text: []const u8) ?Address {

        var result = Address{};
        var parts = std.mem.splitScalar(u8, text, '.');

        for (&result.octets) |*octet| {

            const part = parts.next() orelse return null;
            if (part.len == 0 or part.len > 3) return null;

            octet.* = std.fmt.parseInt(u8, part, 10) catch return null;

        }

        return if (parts.next() == null) result else null;

    }

    pub fn format(self: Address, writer: *std.Io.Writer) std.Io.Writer.Error!void {

        try writer.print("{d}.{d}.{d}.{d}", .{ self.octets[0], self.octets[1], self.octets[2], self.octets[3] });

    }

};

/// How the address was set.
pub const Source = enum(u8) {

    none,
    automatic,
    manual,
    _,

};

/// The link and how it is configured, as the net service reports it.
pub const Status = extern struct {

    /// The controller's PCI vendor id, and its device id in the upper half.
    device: u32 = 0,

    /// Link speed in Mb/s; zero while the link is down.
    speed: u32 = 0,

    mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    source: Source = .none,

    /// Turned off for everyone: nothing is sent or received until it is turned on again.
    off: bool = false,

    address: Address = .{},
    mask: Address = .{},
    gateway: Address = .{},

    /// The DNS server names are resolved through.
    server: Address = .{},

    /// Seconds left on a DHCP lease; zero for a manual address.
    lease: u32 = 0,

    /// Open connections, of every app.
    connections: u32 = 0,

    /// Bytes each way since the service started.
    received: u64 = 0,
    sent: u64 = 0,

    /// UTC seconds since 1970 as of tick `synced`, from an SNTP server; zero until the clock is set.
    utc: u64 = 0,
    synced: u64 = 0,

    /// Whether apps may connect: a link, and an address.
    pub fn online(self: Status) bool {

        return self.speed != 0 and !self.address.empty();

    }

    /// What people call the controller, such as `Intel 82574L`.
    pub fn adapter(self: Status) []const u8 {

        return switch (self.device >> 16) {

            0x10d3 => "Intel 82574L",
            0x15b8, 0x15bc, 0x15be, 0x15d6, 0x15d8 => "Intel I219-V",
            0x15b7, 0x15b9, 0x15bb, 0x15bd, 0x15d7, 0x15e3 => "Intel I219-LM",
            else => "Intel Ethernet",

        };

    }

};

/// A manual configuration, or a return to DHCP when `manual` is zero.
pub const Setting = extern struct {

    manual: u8 = 0,
    reserved: [3]u8 = .{ 0, 0, 0 },
    address: Address = .{},
    mask: Address = .{},
    gateway: Address = .{},
    server: Address = .{},

};

/// How many connections one process holds.
pub const Count = extern struct {

    process: u64,
    connections: u32,
    reserved: u32 = 0,

};

pub const Kind = enum(u8) {

    tcp,
    udp,

};

var endpoint: u64 = 0;

pub fn status() NetError!Status {

    var result = Status{};

    _ = try request(.info, 0, std.mem.asBytes(&result));

    return result;

}

/// The address `name` stands for: dotted decimal as written, or else as DNS resolves it.
pub fn resolve(name: []const u8) NetError!Address {

    if (Address.parse(name)) |address| return address;

    var bytes: [253]u8 = undefined;
    if (name.len == 0 or name.len > bytes.len) return error.Invalid;

    @memcpy(bytes[0..name.len], name);

    return Address.from(@intCast(try request(.resolve, 0, bytes[0..name.len])));

}

/// Sends `address` an ICMP echo request; returns the microseconds until its reply.
pub fn echo(address: Address) NetError!u64 {

    return request(.echo, address.value(), &.{});

}

/// Fills `out` with each process's connection count, as many as fit; returns how many it wrote.
pub fn connections(out: []Count) NetError!usize {

    return request(.list, 0, std.mem.sliceAsBytes(out));

}

/// Sets a manual address, or returns to DHCP; only administrators may.
pub fn configure(setting: Setting) NetError!void {

    var copy = setting;

    _ = try request(.change, 0, std.mem.asBytes(&copy));

}

/// Turns networking on or off for everyone, as any signed-in user may; the choice outlasts restarts.
pub fn power(on: bool) NetError!void {

    _ = try request(.enable, @intFromBool(on), &.{});

}

/// The trusted certificate authorities, in PEM form, in memory the caller frees with `allocator`.
pub fn roots(allocator: std.mem.Allocator) NetError![]u8 {

    var data: std.ArrayList(u8) = .empty;

    errdefer data.deinit(allocator);

    while (true) {

        data.ensureUnusedCapacity(allocator, 0x10000) catch return error.Exhausted;

        const count = try request(.roots, @intCast(data.items.len), data.unusedCapacitySlice()[0..0x10000]);

        if (count == 0) break;
        data.items.len += count;

    }

    return data.toOwnedSlice(allocator) catch error.Exhausted;

}

/// UTC seconds since 1970: the network's clock once SNTP set it, or else the firmware's local time.
pub fn utc() u64 {

    const state = status() catch return api.clock();

    return if (state.utc == 0) api.clock() else state.utc + (api.ticks() -| state.synced) / 100;

}

/// One end of a TCP connection or UDP exchange, or a listening port; usable only by the process that opened it.
pub const Socket = struct {

    handle: u64,

    /// Connects to `port` at `address`; a TCP connection is established when this returns.
    pub fn connect(kind: Kind, address: Address, port: u16) NetError!Socket {

        return .{

            .handle = try request(.connect, @as(u56, @intFromEnum(kind)) << 48 | @as(u56, port) << 32 | address.value(), &.{}),

        };

    }

    /// Listens for TCP connections to `port`; ports below 1024 are for administrators and services.
    pub fn listen(port: u16) NetError!Socket {

        return .{

            .handle = try request(.listen, port, &.{}),

        };

    }

    /// Waits for the next connection to a listening socket.
    pub fn accept(self: Socket) NetError!Peer {

        var bytes: [6]u8 = undefined;
        const handle = try request(.accept, @intCast(self.handle), &bytes);

        return .{

            .socket = .{ .handle = handle },
            .address = .{ .octets = bytes[0..4].* },
            .port = std.mem.readInt(u16, bytes[4..6], .big),

        };

    }

    /// Waits for bytes, or for a datagram, which is cut short to fit; zero once the peer has finished sending.
    pub fn read(self: Socket, out: []u8) NetError!usize {

        while (true) {

            const count = try request(.read, @intCast(self.handle), out);
            if (count != protocol.empty) return count;

        }

    }

    /// Sends all of `bytes`, waiting while the connection's buffer is full; for UDP, `bytes` is one datagram.
    pub fn write(self: Socket, bytes: []const u8) NetError!void {

        var done: usize = 0;

        while (done < bytes.len) {

            // The service only reads the window it is lent.
            const chunk = @constCast(bytes[done..][0..@min(bytes.len - done, 0x10000)]);
            const count = try request(.write, @intCast(self.handle), chunk);

            if (count != protocol.empty) done += count;

        }

    }

    /// Finishes sending and lets the handle go; a TCP peer still receives what was queued.
    pub fn close(self: Socket) void {

        _ = request(.close, @intCast(self.handle), &.{}) catch {

        };

    }

    /// Buffered `std.Io` streams over the socket; the stream must stay where it is while they are used.
    pub fn stream(self: Socket, input: []u8, output: []u8) Stream {

        return .{

            .socket = self,
            .reader = .{

                .vtable = &.{

                    .stream = Stream.pump,

                },
                .buffer = input,
                .seek = 0,
                .end = 0,

            },
            .writer = .{

                .vtable = &.{

                    .drain = Stream.drain,

                },
                .buffer = output,

            },

        };

    }

};

pub const Peer = struct {

    socket: Socket,
    address: Address,
    port: u16,

};

pub const Stream = struct {

    socket: Socket,
    reader: std.Io.Reader,
    writer: std.Io.Writer,

    /// Why the socket last failed, behind a `ReadFailed` or `WriteFailed`.
    failure: ?NetError = null,

    fn pump(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {

        const self: *Stream = @alignCast(@fieldParentPtr("reader", reader));
        const out = limit.slice(try writer.writableSliceGreedy(1));

        const count = self.socket.read(out) catch |err| {

            self.failure = err;
            return error.ReadFailed;

        };

        if (count == 0) return error.EndOfStream;
        writer.advance(count);

        return count;

    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {

        const self: *Stream = @alignCast(@fieldParentPtr("writer", writer));
        const last = data[data.len - 1];
        var total: usize = 0;

        try self.send(writer.buffered());
        writer.end = 0;

        for (data[0 .. data.len - 1]) |bytes| {

            try self.send(bytes);
            total += bytes.len;

        }

        for (0..splat) |_| try self.send(last);

        return total + last.len * splat;

    }

    fn send(self: *Stream, bytes: []const u8) std.Io.Writer.Error!void {

        self.socket.write(bytes) catch |err| {

            self.failure = err;
            return error.WriteFailed;

        };

    }

};

/// Sends a request to the net service, refusing at once when this app lacks the `network` permission.
fn request(operation: protocol.Operation, value: u56, window: []u8) NetError!u64 {

    if (!api.permits(.network)) return error.Denied;

    const result = try api.query(&endpoint, .net, protocol.pack(operation, value), window);

    return switch (result) {

        protocol.timeout => error.Timeout,
        protocol.refused => error.Refused,
        protocol.offline => error.Offline,
        else => result,

    };

}
