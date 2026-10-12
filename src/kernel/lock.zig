const std = @import("std");

// Locks nest in this order: self-test, services, shared regions, retirements, process table, IPC graph, one process, a processor, frames, log.

/// A spin lock serving waiters in arrival order; the kernel runs with interrupts off, so nothing interrupts a holder.
pub const Lock = struct {

    next: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    serving: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn acquire(self: *Lock) void {

        const ticket = self.next.fetchAdd(1, .monotonic);

        while (self.serving.load(.acquire) != ticket) std.atomic.spinLoopHint();

    }

    pub fn release(self: *Lock) void {

        self.serving.store(self.serving.raw +% 1, .release);

    }

};
