const std = @import("std");

const process = @import("process.zig");
const schedule = @import("schedule.zig");
const Lock = @import("lock.zig").Lock;
const Table = @import("table.zig").Table;

const Process = process.Process;
const State = process.State;
pub const IpcError = error{ PermissionDenied, NoProcess, Deadlock, Exhausted, InvalidReply };
var sequence = std.atomic.Value(u64).init(0);

// Only a send that queues adds a wait that could close a cycle; ordering those lets each deadlock check see the others.
var graph: Lock = .{};

/// Hands `message` to `destination`; true when the sender waits for it to be received.
pub fn send(table: *Table, sender: *Process, destination: u64, message: u64) IpcError!bool {

    return transmit(table, sender, destination, message, false, 0);

}

/// Sends `message` and waits for the reply, or until tick `deadline`.
pub fn call(table: *Table, sender: *Process, destination: u64, message: u64, deadline: u64) IpcError!void {

    _ = try transmit(table, sender, destination, message, true, deadline);

}

fn transmit(table: *Table, sender: *Process, destination: u64, message: u64, answer: bool, deadline: u64) IpcError!bool {

    if (!sender.permits(.send, destination, 1)) return error.PermissionDenied;

    const receiver = table.find(destination) orelse return error.NoProcess;

    receiver.lock.acquire();

    // A receiver blocked in `receive` waits on nobody, so handing it the message cannot close a cycle.
    if (receiver.state == .receiving) {

        defer receiver.lock.release();
        return post(receiver, sender, message, answer, deadline);

    }

    receiver.lock.release();
    graph.acquire();
    defer graph.release();

    var cursor = receiver;

    while (true) {

        if (cursor == sender) return error.Deadlock;
        if (!waiting(cursor)) break;

        cursor = @atomicLoad(?*Process, &cursor.server, .monotonic) orelse break;

    }

    receiver.lock.acquire();
    defer receiver.lock.release();

    return post(receiver, sender, message, answer, deadline);

}

/// Delivers to `receiver` if it is receiving, or else queues the sender behind earlier ones; the caller holds `receiver`'s lock.
fn post(receiver: *Process, sender: *Process, message: u64, answer: bool, deadline: u64) IpcError!bool {

    if (receiver.state == .dead) return error.NoProcess;
    if (answer and sequence.load(.monotonic) == std.math.maxInt(u64)) return error.Exhausted;

    sender.message = message;
    sender.ticket = if (answer) sequence.fetchAdd(1, .monotonic) + 1 else 0;
    sender.deadline = deadline;

    if (receiver.state != .receiving) {

        wait(receiver, sender, .sending);
        return true;

    }

    deliver(receiver, sender);
    schedule.wake(receiver);
    if (answer) wait(receiver, sender, .replying);

    return answer;

}

/// Leaves `client` waiting on `server` in `state`, with its alarm set when it has a deadline.
fn wait(server: *Process, client: *Process, state: State) void {

    client.server = server;
    (if (state == .sending) &server.pending else &server.serving).append(&client.link);

    // The deadlock check reads this without a lock, so it must not see the state before the server.
    @atomicStore(State, &client.state, state, .release);
    if (client.deadline != 0) schedule.arm(client);

}

/// Takes the oldest message waiting for the running `receiver`; false when there is none.
pub fn poll(receiver: *Process) bool {

    receiver.lock.acquire();
    defer receiver.lock.release();

    return take(receiver);

}

/// Takes the oldest message waiting for the running `receiver`, or else blocks it until one arrives or tick `deadline`, when
/// not zero; true when it blocked.
pub fn receive(receiver: *Process, deadline: u64) bool {

    receiver.lock.acquire();
    defer receiver.lock.release();

    if (take(receiver)) return false;

    receiver.deadline = deadline;
    receiver.state = .receiving;
    if (deadline != 0) schedule.arm(receiver);

    return true;

}

fn take(receiver: *Process) bool {

    if (receiver.signals != 0) {

        notify(receiver);
        return true;

    }

    const node = receiver.pending.popFirst() orelse return false;
    const sender = Process.from("link", node);

    deliver(receiver, sender);

    if (sender.ticket != 0) {

        sender.state = .replying;
        receiver.serving.append(&sender.link);

    } else {

        complete(sender, 0, 0);

    }

    return true;

}

pub fn reply(table: *Table, server: *Process, client: u64, ticket: u64, message: u64) IpcError!void {

    const sender = caller(table, server, client, ticket) catch |err| return if (err == error.NoProcess) err else error.InvalidReply;
    defer server.lock.release();

    server.serving.remove(&sender.link);
    complete(sender, 0, message);

}

/// The client `id` awaiting `server`'s reply to `ticket`, returned with `server`'s lock held so it keeps waiting.
pub fn caller(table: *Table, server: *Process, id: u64, ticket: u64) IpcError!*Process {

    const client = table.find(id) orelse return error.NoProcess;

    server.lock.acquire();
    if (client.state == .replying and client.server == server and ticket != 0 and client.ticket == ticket) return client;
    server.lock.release();

    return error.PermissionDenied;

}

fn complete(sender: *Process, status: u64, message: u64) void {

    sender.ticket = 0;

    sender.context.respond(.{

        .number = status,
        .first = message,

    });

    schedule.wake(sender);

}

/// Blocks the running `task` until tick `deadline`.
pub fn sleep(task: *Process, deadline: u64) void {

    task.lock.acquire();
    defer task.lock.release();

    task.deadline = deadline;
    task.state = .sleeping;
    schedule.arm(task);

}

/// Ends every wait on processor `id` whose deadline passed by tick `now`.
pub fn expire(id: u32, now: u64) void {

    while (schedule.due(id, now)) |alarm| {

        const task = alarm.task;
        const holder = guard(task);

        defer holder.lock.release();

        // A wait that ended as its alarm went off may already have given way to another.
        if (task.deadline != alarm.deadline) continue;

        if (task.state == .sleeping) {

            complete(task, 0, 0);

        } else if (task.state == .receiving) {

            complete(task, 6, 0);

        } else if (holder != task) {

            leave(holder, task);
            complete(task, 6, 0);

        }

    }

}

/// Fails every call and send still waiting on `server`, which has ended.
pub fn cancel(server: *Process) void {

    server.lock.acquire();
    defer server.lock.release();

    for ([_]*std.DoublyLinkedList{ &server.pending, &server.serving }) |queue| {

        while (queue.popFirst()) |node| complete(Process.from("link", node), 3, 0);

    }

}

/// Takes `client` out of the queue it waits in on `server`; the caller holds `server`'s lock.
pub fn leave(server: *Process, client: *Process) void {

    (if (client.state == .sending) &server.pending else &server.serving).remove(&client.link);

}

/// Locks and returns the process guarding `task`'s state: the server it waits on, or else itself.
pub fn guard(task: *Process) *Process {

    while (true) {

        const holder = warden(task);

        holder.lock.acquire();
        if (warden(task) == holder) return holder;
        holder.lock.release();

    }

}

fn warden(task: *Process) *Process {

    return if (waiting(task)) @atomicLoad(?*Process, &task.server, .monotonic).? else task;

}

fn waiting(task: *Process) bool {

    const state = @atomicLoad(State, &task.state, .acquire);

    return state == .sending or state == .replying;

}

/// Records interrupts `bits` for `task`; it receives them as one message from process 0.
pub fn signal(task: *Process, bits: u64) void {

    task.lock.acquire();
    defer task.lock.release();

    task.signals |= bits;
    if (task.state != .receiving) return;

    notify(task);
    schedule.wake(task);

}

fn notify(receiver: *Process) void {

    receiver.context.respond(.{

        .number = 0,
        .second = receiver.signals,

    });

    receiver.signals = 0;

}

fn deliver(receiver: *Process, sender: *const Process) void {

    receiver.context.respond(.{

        .number = 0,
        .first = sender.id,
        .second = sender.message,
        .third = sender.ticket,
        .fourth = sender.length,
        .fifth = @bitCast(sender.identity),

    });

}
