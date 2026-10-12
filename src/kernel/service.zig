const std = @import("std");

const root = @import("root.zig");
const process = @import("process.zig");
const ipc = @import("ipc.zig");
const abi = @import("abi.zig");
const pci = @import("../board/pc/pci.zig");
const machine = @import("../arch/root.zig").machine;

var listeners = [_]u64{0} ** 16;
var supervisor: u64 = 0;
var restarting = false;
var attempts: u8 = 0;
var due: u64 = 0;
var controller: ?pci.Bar = null;
var host: ?pci.Bar = null;

/// The display's graphics device: its PCI vendor and device ids, and the BARs it needs.
const Graphics = struct {

    device: u32,
    bars: [3]pci.Bar,

};

const vmware = 0x0405_15ad;

var adapter: ?Graphics = null;
var probed = false;

pub fn start() !void {

    const task = try root.spawn(@embedFile("supervisor"), @intFromBool(supervisor != 0), root.primary);
    errdefer task.state = .dead;

    try task.configure(.service, &.{

        .ipc, .time, .management, .diagnostics, .power

    });

    try task.grant(.manage, 0, 1);
    try task.grant(.power, 0, 1);
    try task.grant(.log, 0, 1);

    var current = root.processes;

    while (current) |child| : (current = child.next) {

        if (child.owner != supervisor or child.image == null or child.state == .dead) continue;
        try child.grant(.send, task.id, 1);
        try task.grant(.send, child.id, 1);

    }

    // Publish ownership only after every replacement capability exists.
    current = root.processes;

    while (current) |child| : (current = child.next) {

        if (child.owner == supervisor and child.image != null) child.owner = task.id;

    }

    supervisor = task.id;
    restarting = false;
    root.log.line("supervisor started");

}

pub fn endpoint(owner: u64) ipc.IpcError!u64 {

    if (owner == 0 or owner != supervisor) return error.PermissionDenied;
    if (restarting or ipc.find(root.processes, supervisor) == null) return error.NoProcess;

    return supervisor;

}

pub fn departed(id: u64) void {

    if (id != supervisor) return;
    restarting = true;
    due = root.ticks +| 10;

}

pub fn maintain() void {

    if (!restarting or attempts == 3 or root.ticks < due) return;
    attempts += 1;

    start() catch {

        due = root.ticks +| 100;
        root.log.line("supervisor recovery failed");

    };

}

pub fn spawn(owner: *process.Process, image: abi.Image, argument: u64) !u64 {

    const bytes = switch (image) {

        inline else => |tag| @embedFile(@tagName(tag)),

    };

    // AHCI: mass storage, SATA, AHCI 1.0; ABAR is BAR 5.
    if (image == .storage and controller == null) controller = if (pci.find(.{ .class = 0x010601 })) |at| pci.bar(at, 5) else null;
    if (image == .storage and controller == null) return error.NoDevice;

    if (image == .display and !probed) {

        probed = true;
        adapter = svga() orelse intel();

    }

    if (image == .display and root.framebuffer == null and adapter == null) return error.NoDevice;

    // xHCI: serial bus, USB, xHCI; its registers are BAR 0.
    if (image == .usb and host == null) host = if (pci.find(.{ .class = 0x0c0330 })) |at| pci.bar(at, 0) else null;
    if (image == .usb and host == null) return error.NoDevice;

    const task = try root.spawn(bytes, argument, root.quietest());
    errdefer task.state = .dead;

    task.owner = owner.id;
    task.image = image;
    task.generation = argument;
    task.context.frame.rsi = 0;

    switch (image) {

        .serial => try task.configure(.service, &.{

            .ipc, .time, .ports

        }),
        .helper => try task.configure(.service, &.{

            .ipc

        }),
        .storage => {

            try task.configure(.service, &.{

                .ipc, .time, .mmio, .dma, .diagnostics

            });

            const page = controller.?.base & ~@as(u64, 4095);

            try task.grant(.mmio, page, std.mem.alignForward(u64, controller.?.base + controller.?.size, 4096) - page);
            try task.grant(.log, 0, 1);
            task.context.frame.rsi = controller.?.base;

        },
        .files => {

            try task.configure(.service, &.{

                .ipc, .diagnostics

            });

            try task.grant(.log, 0, 1);

        },
        .accounts => {

            try task.configure(.service, &.{

                .ipc, .accounts, .diagnostics

            });

            try task.grant(.log, 0, 1);

        },
        .install => {

            try task.configure(.service, &.{

                .ipc, .mmio, .firmware, .diagnostics

            });

            try task.grant(.log, 0, 1);

            if (root.efi) |file| {

                const page = file.base & ~@as(u64, 4095);

                try task.grant(.mmio, page, std.mem.alignForward(u64, file.base + file.size, 4096) - page);
                task.context.frame.rsi = file.base;
                task.context.frame.rcx = file.size;

            }

        },
        .display => {

            try task.configure(.service, &.{

                .ipc, .time, .memory, .mmio, .ports, .dma, .diagnostics

            });

            try task.grant(.log, 0, 1);

            if (root.framebuffer) |screen| {

                const page = screen.base & ~@as(u64, 4095);

                try task.grant(.mmio, page, std.mem.alignForward(u64, screen.base + @as(u64, screen.stride) * screen.height * 4, 4096) - page);
                task.context.frame.rsi = screen.base;
                task.context.frame.rcx = screen.width | @as(u64, screen.height) << 16 | @as(u64, screen.stride) << 32;
                task.context.frame.r8 = @ctz(screen.red_mask) | @as(u64, @ctz(screen.green_mask)) << 8 | @as(u64, @ctz(screen.blue_mask)) << 16;

            }

            if (adapter) |graphics| {

                const bars = graphics.bars;

                // Screen objects keep VRAM on the device side, so only the ports and command FIFO are granted; Intel's registers and GTT share BAR 0.
                if (graphics.device == vmware) {

                    try task.grant(.port, bars[0].base, bars[0].size);
                    try task.grant(.mmio, bars[2].base, bars[2].size);

                } else {

                    try task.grant(.mmio, bars[0].base, bars[0].size);

                }

                task.environment.device = graphics.device;

                for (bars, 0..) |entry, index| task.environment.bars[index] = .{

                    .base = entry.base,
                    .size = entry.size,
                    .ports = entry.ports,

                };

            }

        },
        .input => {

            try task.configure(.service, &.{

                .ipc, .time, .ports, .diagnostics

            });

            try task.grant(.port, 0x60, 1);
            try task.grant(.port, 0x64, 1);
            try task.grant(.log, 0, 1);

            // The PS/2 keyboard and mouse.
            try listen(task, 1);
            try listen(task, 12);

        },
        .usb => {

            try task.configure(.service, &.{

                .ipc, .time, .mmio, .dma, .diagnostics

            });

            const page = host.?.base & ~@as(u64, 4095);

            try task.grant(.mmio, page, std.mem.alignForward(u64, host.?.base + host.?.size, 4096) - page);
            try task.grant(.log, 0, 1);
            task.context.frame.rsi = host.?.base;
            task.context.frame.rcx = host.?.size;

        },
        // Applications keep the default application policy.
        else => {

        },

    }

    try task.grant(.send, owner.id, 1);
    if (image == .serial) try task.grant(.port, 0x2f8, 8);
    try owner.grant(.send, task.id, 1);

    return task.id;

}

fn listen(task: *process.Process, irq: u4) !void {

    try machine.route(irq, task.home);
    listeners[irq] = task.id;

}

/// Hands ISA interrupt `irq` to its listener, if that process still runs.
pub fn interrupt(irq: u4) void {

    const task = ipc.find(root.processes, listeners[irq]) orelse return;

    ipc.signal(task, @as(u64, 1) << irq);

}

/// VMware SVGA II: I/O ports, VRAM, and command FIFO.
fn svga() ?Graphics {

    const at = pci.find(.{ .id = vmware }) orelse return null;

    return .{

        .device = vmware,
        .bars = .{

            pci.bar(at, 0) orelse return null,
            pci.bar(at, 1) orelse return null,
            pci.bar(at, 2) orelse return null,

        },

    };

}

/// Intel integrated graphics, such as the UHD Graphics 630: a display controller from Intel, whose registers and GTT are BAR 0.
fn intel() ?Graphics {

    const at = pci.find(.{ .class = 0x030000 }) orelse return null;
    const device = pci.id(at);

    if (device & 0xffff != 0x8086) return null;

    return .{

        .device = device,
        .bars = .{ pci.bar(at, 0) orelse return null, .{ .base = 0, .size = 0 }, .{ .base = 0, .size = 0 } },

    };

}

pub fn inspect(owner: *process.Process, image: abi.Image) ?*process.Process {

    var current = root.processes;

    while (current) |task| : (current = task.next) {

        if (task.owner == owner.id and task.image == image and task.state != .dead) return task;

    }

    return null;

}

pub fn connect(owner: *process.Process, source: u64, destination: u64) !void {

    const sender = ipc.find(root.processes, source) orelse return error.NoProcess;
    const receiver = ipc.find(root.processes, destination) orelse return error.NoProcess;

    if (sender.owner != owner.id or receiver.owner != owner.id) return error.Denied;
    if (!sender.permits(.send, destination, 1)) try sender.grant(.send, destination, 1);

}

pub fn revoke(id: u64) void {

    var current = root.processes;

    while (current) |task| : (current = task.next) {

        var link = &task.capabilities;

        while (link.*) |grant| {

            if (grant.right != .send or grant.base != id or grant.size != 1) {

                link = &grant.next;
                continue;

            }

            link.* = grant.next;
            root.frames.release(@intFromPtr(grant)) catch @panic("Capability ownership");

        }

    }

}
