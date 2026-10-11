const std = @import("std");

const boot = @import("../boot/info.zig");
const arch = @import("../arch/root.zig");
const memory = @import("memory.zig");
const process = @import("process.zig");
const ipc = @import("ipc.zig");
const check = @import("check.zig");
const service = @import("service.zig");
const shared = @import("shared.zig");
const Log = @import("../debug/log.zig").Log;

const options = @import("options");

const machine = arch.machine;
pub var frames: memory.Frames = undefined;
pub var processes: ?*process.Process = null;
pub var log: Log = undefined;
pub var lock = std.atomic.Value(bool).init(false);
var launched = std.atomic.Value(bool).init(false);
pub var failed = std.atomic.Value(bool).init(false);
var initialized = false;
var next_id: u64 = 1;
pub var framebuffer: ?boot.Framebuffer = null;
pub var primary: u32 = 0;
pub var ticks: u64 = 0;
pub var runtime: u64 = 0;
pub var efi: ?boot.Region = null;

/// Local time in seconds since 1970 when the loader read the firmware clock; `ticks` counts on from there.
pub var epoch: u64 = 0;

pub fn start(info: *const boot.Info, output: Log) !noreturn {

    log = output;
    framebuffer = info.framebuffer;
    runtime = info.runtime;
    efi = info.efi;
    epoch = info.clock;
    if (info.version != 3 or info.memory.len == 0) return error.InvalidBootInfo;

    log.line("start");
    log.hex("image base", info.image.base);

    const size = try memory.Frames.storageSize(info.memory);
    var storage: ?[]u8 = null;

    for (info.memory) |region| {

        if (region.kind != .available or region.base < 0x100000 or region.size < std.mem.alignForward(usize, size, 4096)) continue;

        storage = @as([*]u8, @ptrFromInt(region.base))[0..size];

        break;

    }

    const bits = storage orelse return error.OutOfMemory;

    frames = try memory.Frames.init(info.memory, bits, @intFromPtr(bits.ptr), std.mem.alignForward(usize, size, 4096));
    log.decimal("free pages", frames.free_count);

    try machine.prepare(info, &frames, log);
    initialized = true;
    primary = machine.local().id;
    log.line("memory protected");

    if (options.self_test) try check.start(info);
    try machine.startOthers(info, secondary);
    log.line("all processors online");

    if (!options.self_test) {

        try service.start();
        ready();

    }

    launched.store(true, .release);
    machine.apic.timer();
    arch.context.restore(&machine.local().idle);

}

pub fn spawn(bytes: []const u8, argument: usize, home: u32) !*process.Process {

    if (next_id == std.math.maxInt(u64)) return error.ProcessIdsExhausted;

    var cores = machine.cores;

    while (cores) |core| : (cores = core.next) {

        if (core.id == home) break;

    } else return error.InvalidProcessor;

    const task = try process.Process.create(machine.kernel, bytes, next_id, argument, home);

    next_id += 1;
    task.next = processes;
    processes = task;

    return task;

}

pub fn ready() void {

    if (framebuffer) |display| {

        const pixels: [*]volatile u32 = @ptrFromInt(display.base);

        for (0..@min(display.height, 24)) |y| {

            for (0..display.width) |x| pixels[y * display.stride + x] = display.green_mask;

        }

    }

    log.line("ready");

}

fn secondary(core: *machine.Core) callconv(.c) noreturn {

    arch.cpu.features();
    arch.paging.activate(machine.kernel.root);
    core.tables.load(core.stack, core.emergency);
    machine.apic.init();
    core.online.store(true, .release);

    while (!launched.load(.acquire)) arch.cpu.relax();

    machine.apic.timer();
    arch.context.restore(&core.idle);

}

pub fn exited(task: *process.Process, status: u64) void {

    if (options.self_test) check.exited(task, status);
    log.decimal("exited process", task.id);
    log.decimal("exit status", status);

    task.state = .dead;

}

pub fn reap() void {

    var link = &processes;

    while (link.*) |task| {

        if (task.state != .dead) {

            link = &task.next;

            continue;

        }

        ipc.cancel(processes, task.id);
        service.revoke(task.id);
        service.departed(task.id);
        shared.departed(task.id);
        link.* = task.next;
        task.destroy();

    }

}

pub fn failure(message: []const u8) noreturn {

    failureAt(message, @returnAddress());

}

pub fn failureAt(message: []const u8, address: ?usize) noreturn {

    beginFailure();
    reportFailure(message, address);

}

pub fn beginFailure() void {

    arch.cpu.disable();
    if (failed.swap(true, .acq_rel)) arch.cpu.halt();
    if (initialized) machine.apic.stopOthers();

}

pub fn reportFailure(message: []const u8, address: ?usize) noreturn {

    log.err(message);
    if (address) |value| log.hex("failure address", value);
    log.line("rebooting after kernel failure");

    if (initialized) machine.apic.delay(1000);
    machine.reboot();

}
