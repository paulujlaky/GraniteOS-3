const arch = @import("../root.zig");
const root = @import("../../kernel/root.zig");
const calls = @import("../../kernel/syscall.zig");
const check = @import("../../kernel/check.zig");
const schedule = @import("../../kernel/schedule.zig");
const ipc = @import("../../kernel/ipc.zig");
const service = @import("../../kernel/service.zig");
const process = @import("../../kernel/process.zig");
const abi = @import("../../kernel/abi.zig");

const options = @import("options");

const machine = arch.machine;

pub export fn dispatch(frame: *const arch.context.Frame, floating: *const [512]u8) callconv(.c) *const arch.context.Context {

    const active_root = asm volatile ("mov %%cr3, %[value]" // Read the active page-table address.
        : [value] "=r" (-> usize),
    );

    if (root.failed.load(.acquire)) arch.cpu.halt();

    if (frame.vector < 32 and (frame.cs & 3 == 0 or frame.vector == 2 or frame.vector == 8 or frame.vector == 18)) {

        root.beginFailure();
        dump(frame, active_root);

        root.reportFailure("Kernel exception", frame.rip);

    }

    const core = machine.local();

    root.enter(core);
    core.kicked.store(false, .release);

    // Every space maps the kernel the same way, so the caller's page tables stay active until another process is chosen.
    const number = frame.rax;
    const now = root.ticks.load(.acquire);
    var outcome: schedule.Outcome = .yield;

    if (core.current) |task| {

        task.context.frame = frame.*;
        task.context.floating = floating.*;

        if (frame.vector == 32) {

            task.preemptions += 1;
            core.preemptions += 1;

        } else if (frame.vector == 128) {

            // A call that leaves its caller running carries on with it, rather than passing the processor on, unless it yields.
            outcome = calls.handle(task, now);

        } else if (frame.vector == 14 and frame.code & 1 == 0 and task.grow(asm volatile ("mov %%cr2, %[value]" // Read the faulting address.
            : [value] "=r" (-> usize),
        ))) {

            outcome = .keep;

        } else if (frame.vector < 32) {

            root.log.decimal("isolated fault process", task.id);
            dump(frame, active_root);

            if (options.self_test) check.faulted(task, frame);

            outcome = .exit;

        }

    } else {

        core.idle.frame = frame.*;
        core.idle.floating = floating.*;

    }

    if (frame.vector == 32) core.ticks += 1;
    if (frame.vector == 32 and core.id == root.primary) _ = root.ticks.fetchAdd(1, .release);
    if (frame.vector >= machine.legacy and frame.vector < machine.legacy + machine.lines) service.interrupt(@intCast(frame.vector - machine.legacy));
    ipc.expire(core.id, root.ticks.load(.acquire));
    if (frame.vector >= 32 and frame.vector != 128 and frame.vector != 255) machine.apic.write(0xb0, 0);

    root.collect();
    service.maintain();

    var kept: ?*process.Process = null;

    if (core.current) |task| {

        outcome = schedule.release(core.id, task, outcome);
        if (outcome == .exit) root.kill(task, true);
        if (outcome == .keep) kept = task;

    }

    core.current = kept orelse schedule.pick(core.id);
    var result: *const arch.context.Context = &core.idle;

    if (core.current) |task| {

        if (kept == null) core.switches += 1;

        // Unmapping leaves stale translations behind, which reloading the page tables flushes.
        if (kept == null or number == @intFromEnum(abi.Call.release) or number == @intFromEnum(abi.Call.detach)) arch.paging.activate(task.space.root);
        result = &task.context;

    } else {

        // A retired process's page tables are freed once every processor has left the kernel, so an idle one must not keep them.
        arch.paging.activate(machine.kernel.root);

    }

    // Whatever became ready that this processor cannot run goes to idle ones at once.
    machine.kick(core);

    if (options.self_test) check.verify();
    root.leave(core);

    return result;

}

fn dump(frame: *const arch.context.Frame, active_root: usize) void {

    root.log.decimal("cpu", machine.apic.id());
    root.log.hex("vector", frame.vector);
    root.log.hex("error code", frame.code);

    root.log.hex("rip", frame.rip);
    root.log.hex("rsp", frame.rsp);

    root.log.hex("cr2", asm volatile ("mov %%cr2, %[value]" // Read the faulting memory address.
        : [value] "=r" (-> usize),
    ));

    root.log.hex("rax", frame.rax);
    root.log.hex("rbx", frame.rbx);
    root.log.hex("rcx", frame.rcx);
    root.log.hex("rdx", frame.rdx);
    root.log.hex("rsi", frame.rsi);
    root.log.hex("rdi", frame.rdi);
    root.log.hex("rbp", frame.rbp);
    root.log.hex("r8", frame.r8);
    root.log.hex("r9", frame.r9);
    root.log.hex("r10", frame.r10);
    root.log.hex("r11", frame.r11);
    root.log.hex("r12", frame.r12);
    root.log.hex("r13", frame.r13);
    root.log.hex("r14", frame.r14);
    root.log.hex("r15", frame.r15);

    root.log.hex("rflags", frame.flags);
    root.log.hex("cr3", active_root);

}
