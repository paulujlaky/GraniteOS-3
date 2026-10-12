const arch = @import("../arch/root.zig");
const root = @import("root.zig");
const process = @import("process.zig");
const shared = @import("shared.zig");
const boot = @import("../boot/info.zig");

const Record = struct {

    next: ?*Record,
    id: u64,
    role: usize,

};

var records: ?*Record = null;
var initial_free: usize = 0;
var successes: usize = 0;
var faults: usize = 0;
var finished = false;
var passed = true;

pub fn start(info: *const boot.Info) !void {

    try memoryChecks();
    initial_free = root.frames.free_count;

    const bsp = arch.machine.local().id;
    const server = try spawn(0, bsp);
    const client = try spawn(1, bsp);

    try server.grant(.send, client.id, 1);
    try client.grant(.send, server.id, 1);
    client.context.frame.rsi = server.id;

    var cores = arch.machine.cores;

    while (cores) |core| : (cores = core.next) {

        _ = try spawn(2, core.id);
        _ = try spawn(2, core.id);

    }

    for (3..10) |role| {

        const task = try spawn(role, bsp);

        if (role == 6) {

            try task.grant(.port, 0x80, 1);

            if (info.framebuffer) |framebuffer| {

                try task.grant(.mmio, framebuffer.base, 4096);
                task.context.frame.rsi = framebuffer.base;

            }

        }

    }

}

fn memoryChecks() !void {

    const available = root.frames.free_count;
    const image = @embedFile("application");
    const first = try process.Process.create(arch.machine.kernel, image, 1, 0, 0);
    const second = try process.Process.create(arch.machine.kernel, image, 2, 0, 0);
    const address = arch.paging.user_base;

    if (try first.space.translate(address, false) == try second.space.translate(address, false)) return error.SharedPrivatePage;

    if (first.space.translate(address, true)) |_| {

        return error.WritableExecutable;

    } else |err| {

        if (err != error.PermissionDenied) return err;

    }

    // Many regions, one spanning two page lists and backed by the same pages for both holders.
    for (0..100) |_| _ = try shared.create(first, 1);

    const region = try shared.create(first, 600);

    try second.grant(.region, region.handle, 1);
    const view = try shared.attach(second, region.handle);

    if (try first.space.translate(region.address + 599 * 4096, true) != try second.space.translate(view.address + 599 * 4096, true)) return error.SharedRegionMismatch;

    shared.departed(first.id);
    shared.departed(second.id);
    first.destroy();

    var held: usize = 0;

    while (root.frames.free_count > 5) {

        const page = try root.frames.alloc();

        @as(*usize, @ptrFromInt(page)).* = held;
        held = page;

    }

    if (process.Process.create(arch.machine.kernel, image, 3, 0, 0)) |task| {

        task.destroy();

        return error.MissingAllocationFailure;

    } else |err| {

        if (err != error.OutOfMemory) return err;

    }

    if (shared.create(second, 8)) |_| {

        return error.MissingAllocationFailure;

    } else |err| {

        if (err != error.OutOfMemory) return err;

    }

    if (root.frames.free_count != 5) return error.RollbackLeak;

    while (held != 0) {

        const page = held;

        held = @as(*usize, @ptrFromInt(page)).*;
        try root.frames.release(page);

    }

    second.destroy();
    if (root.frames.free_count != available) return error.ProcessLeak;

    root.log.line("page isolation and allocation rollback passed");

}

fn spawn(role: usize, home: u32) !*process.Process {

    const task = try root.spawn(@embedFile("application"), role, home);

    if (role == 6) {

        try task.configure(.service, &.{

            .ipc, .memory, .time, .diagnostics, .ports, .mmio

        });

    } else {

        try task.configure(.application, &.{

            .ipc, .memory, .time, .diagnostics

        });

    }

    try task.grant(.log, 0, 1);

    const record: *Record = @ptrFromInt(try root.frames.alloc());

    record.* = .{

        .next = records,
        .id = task.id,
        .role = role,

    };

    records = record;

    return task;

}

fn take(id: u64) ?usize {

    var link = &records;

    while (link.*) |record| {

        if (record.id != id) {

            link = &record.next;

            continue;

        }

        const role = record.role;

        link.* = record.next;
        root.frames.release(@intFromPtr(record)) catch @panic("Probe ownership");

        return role;

    }

    return null;

}

pub fn exited(task: *process.Process, status: u64) void {

    const role = take(task.id) orelse return;

    if (status != 0 or (role == 2 and task.preemptions < 2) or (role >= 3 and role != 6)) passed = false;
    successes += 1;

}

pub fn faulted(task: *process.Process, frame: *const arch.context.Frame) void {

    const role = take(task.id) orelse return;

    const expected = switch (role) {

        3 => frame.vector == 14 and frame.code & 5 == 5,
        4 => frame.vector == 13,
        5 => frame.vector == 14 and frame.code & 21 == 21,
        7 => frame.vector == 14 and frame.code & 7 == 7,
        8 => frame.vector == 14 and frame.code & 5 == 4,
        9 => frame.vector == 14 and frame.code & 7 == 7,
        else => false,

    };

    if (!expected) passed = false;
    faults += 1;

}

pub fn verify() void {

    if (finished or records != null or root.processes != null) return;
    if (!passed or faults != 6 or successes != 3 + 2 * arch.machine.core_count or root.frames.free_count != initial_free) @panic("Kernel self-test failed");

    var current = arch.machine.cores;

    while (current) |core| : (current = core.next) {

        if (!core.online.load(.acquire) or core.preemptions < 4) @panic("Multicore preemption missing");
        root.log.decimal("verified cpu", core.id);
        root.log.decimal("preemptions", core.preemptions);

    }

    root.log.line("IPC and capability checks passed");
    root.log.line("fault isolation passed");
    root.log.line("process memory reclaimed");
    root.ready();
    finished = true;
    @import("service.zig").start() catch |err| root.failure(@errorName(err));

}
