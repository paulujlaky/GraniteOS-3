const std = @import("std");

const process = @import("process.zig");
const Lock = @import("lock.zig").Lock;

const Process = process.Process;

/// Every process by id. Lookups take no lock: ids are never reused, and a removed process stays readable until every processor has left the kernel.
pub const Table = struct {

    /// Guards adding and removing processes, and walking them all.
    lock: Lock = .{},

    /// Chains of processes whose ids share a remainder.
    buckets: []?*Process = &.{},

    /// Every process, newest first.
    all: std.DoublyLinkedList = .{},
    count: usize = 0,
    next: u64 = 1,

    pub fn find(self: *const Table, id: u64) ?*Process {

        var current = @atomicLoad(?*Process, &self.buckets[id % self.buckets.len], .acquire);

        while (current) |task| : (current = @atomicLoad(?*Process, &task.chain, .acquire)) {

            if (task.id == id and @atomicLoad(process.State, &task.state, .monotonic) != .dead) return task;

        }

        return null;

    }

    /// Adds `task` under the next unused id.
    pub fn insert(self: *Table, task: *Process) error{ProcessIdsExhausted}!void {

        self.lock.acquire();
        defer self.lock.release();

        if (self.next == std.math.maxInt(u64)) return error.ProcessIdsExhausted;

        task.id = self.next;
        self.next += 1;

        const bucket = &self.buckets[task.id % self.buckets.len];

        task.chain = bucket.*;
        @atomicStore(?*Process, bucket, task, .release);
        self.all.prepend(&task.roster);
        self.count += 1;

    }

    pub fn remove(self: *Table, task: *Process) void {

        self.lock.acquire();
        defer self.lock.release();

        var link = &self.buckets[task.id % self.buckets.len];

        while (link.* != task) link = &link.*.?.chain;

        @atomicStore(?*Process, link, task.chain, .release);
        self.all.remove(&task.roster);
        self.count -= 1;

    }

    /// Walks every process, newest first; the caller holds the lock.
    pub fn iterate(self: *const Table) Iterator {

        return .{

            .node = self.all.first,

        };

    }

};

pub const Iterator = struct {

    node: ?*std.DoublyLinkedList.Node,

    pub fn next(self: *Iterator) ?*Process {

        const node = self.node orelse return null;

        self.node = node.next;

        return Process.from("roster", node);

    }

};
