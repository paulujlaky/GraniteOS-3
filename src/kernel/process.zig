const std = @import("std");

const arch = @import("../arch/root.zig");
const elf = @import("elf.zig");
const memory = @import("memory.zig");
const abi = @import("abi.zig");
const permission = @import("permission.zig");
const Lock = @import("lock.zig").Lock;

const paging = arch.paging;
const Node = std.DoublyLinkedList.Node;
pub const State = abi.State;

/// The stack grows down from its top to the read-only environment page, which stops an overflow; heap allocations stay below both.
const stack_top = paging.user_end - 4096;
const environment_address = paging.user_end - 0x100000;

pub const Right = enum {

    send,
    port,
    mmio,
    power,
    log,
    manage,
    region,

};

pub const Capability = struct {

    next: ?*Capability = null,
    right: Right,

    base: u64 = 0,
    size: u64 = 0,

};

pub const Process = struct {

    id: u64,
    state: State = .ready,
    policy: permission.Policy = permission.application,
    identity: abi.Identity = abi.nobody,
    environment: *abi.Environment,

    space: paging.Space,
    context: arch.context.Context,

    capabilities: ?*Capability = null,
    message: u64 = 0,
    ticket: u64 = 0,
    deadline: u64 = 0,
    owner: u64 = 0,
    image: ?abi.Image = null,
    generation: u64 = 0,

    buffer: u64 = 0,
    length: u64 = 0,

    /// Device interrupts raised since the last `receive`, one bit per interrupt line.
    signals: u64 = 0,

    /// Guards its capabilities, signals, and callers, and its state unless it waits on a server, whose lock guards that instead.
    lock: Lock = .{},

    /// The server it sends to or awaits a reply from.
    server: ?*Process = null,

    /// Callers queued to be received, in arrival order, and those received but not yet answered.
    pending: std.DoublyLinkedList = .{},
    serving: std.DoublyLinkedList = .{},

    /// Its place in a ready queue or a server's queue, and among its processor's alarms.
    link: Node = .{},
    alarm: Node = .{},
    armed: bool = false,

    /// Its places in the process table: its bucket's chain, and the list of every process.
    chain: ?*Process = null,
    roster: Node = .{},

    /// The processor it last ran on, which takes it first; an idle processor may take it over.
    home: u32,

    /// Its processor's current process, or a new one its creator has yet to start; only the holder queues or ends it.
    held: bool = true,

    /// Stopped while another processor held it; it dies when that processor lets go.
    doomed: bool = false,

    /// The retirement count when it ended; its memory is freed once every processor has entered the kernel since.
    retired: u64 = 0,

    /// Timer ticks that interrupted the process while it ran: its processor time at 100 Hz.
    preemptions: usize = 0,

    allocation: usize = paging.user_base + 0x10000000,
    cursor: usize = paging.user_base + 0x10000000,

    pub fn create(kernel: paging.Space, bytes: []const u8, id: u64, argument: usize, home: u32) !*Process {

        const image = try elf.Image.parse(bytes, paging.user_base, paging.user_base + 0x10000000);

        const address = try kernel.frames.alloc();
        errdefer kernel.frames.release(address) catch @panic("Process ownership");

        const self: *Process = @ptrFromInt(address);
        var space = try paging.Space.process(kernel);
        errdefer space.destroy();

        for (0..image.header.phnum) |index| {

            const segment = image.program(index);

            if (segment.kind != 1 or segment.memory_size == 0) continue;

            var virtual = segment.address & ~@as(u64, 4095);
            const end = segment.address + segment.memory_size;

            while (virtual < end) : (virtual += 4096) {

                const flags: u64 = paging.user | (if (segment.flags & 2 != 0) paging.writable else @as(u64, 0)) | (if (segment.flags & 1 == 0) paging.nx else @as(u64, 0));
                const physical = try space.allocate(@intCast(virtual), flags);
                const page: *[4096]u8 = @ptrFromInt(physical);

                const first = @max(virtual, segment.address);
                const last = @min(virtual + 4096, segment.address + segment.file_size);

                if (first < last) @memcpy(page[first - virtual .. last - virtual], bytes[segment.offset + first - segment.address .. segment.offset + last - segment.address]);

            }

        }

        // 56 KiB of stack to start with; `grow` adds more as faults reach under it.
        for (0..14) |index| {

            _ = try space.allocate(stack_top - (index + 1) * 4096, paging.user | paging.writable | paging.nx);

        }

        self.* = .{

            .id = id,
            .space = space,
            .context = arch.context.Context.init(image.header.entry, stack_top, argument, false),
            .home = home,
            .environment = @ptrFromInt(try space.allocate(environment_address, paging.user | paging.nx)),

        };

        self.context.frame.rdx = environment_address;
        self.publish();

        return self;

    }

    /// The process holding `node` as its `field`.
    pub fn from(comptime field: []const u8, node: *Node) *Process {

        return @alignCast(@fieldParentPtr(field, node));

    }

    pub fn grant(self: *Process, right: Right, base: u64, size: u64) !void {

        self.lock.acquire();
        defer self.lock.release();

        try self.add(right, base, size);

    }

    /// Grants `right` over the range unless the process already holds it.
    pub fn allow(self: *Process, right: Right, base: u64, size: u64) !void {

        self.lock.acquire();
        defer self.lock.release();

        if (!self.holds(right, base, size)) try self.add(right, base, size);

    }

    pub fn permits(self: *Process, right: Right, base: u64, size: u64) bool {

        self.lock.acquire();
        defer self.lock.release();

        return self.holds(right, base, size);

    }

    /// Drops its rights to send to process `id`, which has ended.
    pub fn withdraw(self: *Process, id: u64) void {

        self.lock.acquire();
        defer self.lock.release();

        var link = &self.capabilities;

        while (link.*) |capability| {

            if (capability.right != .send or capability.base != id or capability.size != 1) {

                link = &capability.next;
                continue;

            }

            link.* = capability.next;
            self.space.frames.release(@intFromPtr(capability)) catch @panic("Capability ownership");

        }

    }

    fn add(self: *Process, right: Right, base: u64, size: u64) !void {

        if (!self.policy.permits(required(right))) return error.Denied;
        const capability: *Capability = @ptrFromInt(try self.space.frames.alloc());

        capability.* = .{

            .next = self.capabilities,
            .right = right,
            .base = base,
            .size = size,

        };

        self.capabilities = capability;

    }

    /// Maps a fresh stack page at `address` when a fault there means the stack grew; false for any other fault.
    pub fn grow(self: *Process, address: usize) bool {

        if (address < environment_address + 4096 or address >= stack_top or self.space.present(address)) return false;
        _ = self.space.allocate(address & ~@as(usize, 4095), paging.user | paging.writable | paging.nx) catch return false;

        return true;

    }

    pub fn vacant(self: *const Process) memory.MemoryError!usize {

        return self.reserve(1);

    }

    /// Finds `pages` consecutive unmapped pages at or above the allocation cursor.
    pub fn reserve(self: *const Process, pages: usize) memory.MemoryError!usize {

        var address = self.cursor;
        var run: usize = 0;

        while (address < paging.user_end - 0x100000) : (address += 4096) {

            run = if (self.space.present(address)) 0 else run + 1;
            if (run == pages) return address + 4096 - pages * 4096;

        }

        return error.OutOfMemory;

    }

    pub fn mapped(self: *Process, address: usize) void {

        self.cursor = address + 4096;
        self.allocation = @max(self.allocation, self.cursor);

    }

    fn holds(self: *const Process, right: Right, base: u64, size: u64) bool {

        if (!self.policy.permits(required(right))) return false;
        var current = self.capabilities;

        while (current) |capability| : (current = capability.next) {

            if (capability.right == right and base >= capability.base and base - capability.base <= capability.size and size <= capability.size - (base - capability.base)) return true;

        }

        return false;

    }

    pub fn configure(self: *Process, layer: abi.Layer, permissions: []const abi.Permission) permission.PolicyError!void {

        self.policy = try permission.Policy.init(layer, permissions);
        self.identity = if (layer == .service) abi.system else abi.nobody;
        self.publish();

    }

    /// Describes the process for `stats`.
    pub fn usage(self: *const Process) abi.Usage {

        return .{

            .id = self.id,
            .owner = self.owner,
            .image = if (self.image) |image| @intFromEnum(image) else abi.Usage.anonymous,
            .identity = self.identity,
            .layer = self.policy.layer,
            .state = self.state,
            .pages = self.space.resident(),
            .ticks = self.preemptions,

        };

    }

    fn publish(self: *Process) void {

        self.environment.* = .{

            .layer = self.policy.layer,
            .length = self.policy.length,
            .permissions = self.policy.permissions,

        };

    }

    pub fn destroy(self: *Process) void {

        const frames = self.space.frames;

        self.space.destroy();

        var current = self.capabilities;

        while (current) |capability| {

            current = capability.next;
            frames.release(@intFromPtr(capability)) catch @panic("Capability ownership");

        }

        frames.release(@intFromPtr(self)) catch @panic("Process ownership");

    }

};

fn required(right: Right) abi.Permission {

    return switch (right) {

        .send => .ipc,
        .port => .ports,
        .mmio => .mmio,
        .power => .power,
        .log => .diagnostics,
        .manage => .management,
        .region => .memory,

    };

}

comptime {

    if (@sizeOf(Process) > 4096) @compileError("Process exceeds a page");

}
