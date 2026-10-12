const std = @import("std");

const process = @import("process.zig");

const Process = process.Process;
pub const IpcError = error{ PermissionDenied, NoProcess, Deadlock, Exhausted, InvalidReply };
var sequence: u64 = 0;

pub fn find(head: ?*Process, id: u64) ?*Process {

    var current = head;

    while (current) |entry| : (current = entry.next) {

        if (entry.id == id and entry.state != .dead) return entry;

    }

    return null;

}

pub fn send(head: ?*Process, sender: *Process, destination: u64, message: u64) IpcError!void {

    try transmit(head, sender, destination, message, 0, 0);

}

pub fn call(head: ?*Process, sender: *Process, destination: u64, message: u64, deadline: u64) IpcError!void {

    if (sequence == std.math.maxInt(u64)) return error.Exhausted;

    try transmit(head, sender, destination, message, sequence + 1, deadline);

}

fn transmit(head: ?*Process, sender: *Process, destination: u64, message: u64, ticket: u64, deadline: u64) IpcError!void {

    if (!sender.permits(.send, destination, 1)) return error.PermissionDenied;

    const receiver = find(head, destination) orelse return error.NoProcess;
    var cursor = receiver;

    while (true) {

        if (cursor == sender) return error.Deadlock;
        if (cursor.state != .sending and cursor.state != .replying) break;

        cursor = find(head, cursor.destination) orelse break;

    }

    if (sequence == std.math.maxInt(u64)) return error.Exhausted;

    sequence += 1;
    sender.sequence = sequence;
    sender.destination = destination;
    sender.message = message;
    sender.ticket = ticket;
    sender.deadline = deadline;

    if (receiver.state == .receiving) {

        deliver(receiver, sender);
        if (ticket != 0) sender.state = .replying;

        return;

    }

    sender.state = .sending;

}

pub fn receive(head: ?*Process, receiver: *Process) void {

    if (!poll(head, receiver)) receiver.state = .receiving;

}

pub fn poll(head: ?*Process, receiver: *Process) bool {

    if (receiver.signals != 0) {

        notify(receiver);
        return true;

    }

    var first: ?*Process = null;
    var current = head;

    while (current) |sender| : (current = sender.next) {

        if (sender.state != .sending or sender.destination != receiver.id) continue;
        if (first == null or sender.sequence < first.?.sequence) first = sender;

    }

    if (first) |sender| {

        deliver(receiver, sender);

        if (sender.ticket != 0) {

            sender.state = .replying;

        } else {

            complete(sender, 0, 0);

        }

        return true;

    }

    return false;

}

pub fn reply(head: ?*Process, server: *Process, client: u64, ticket: u64, message: u64) IpcError!void {

    const sender = find(head, client) orelse return error.NoProcess;

    if (sender.state != .replying or sender.destination != server.id or ticket == 0 or sender.ticket != ticket) return error.InvalidReply;

    complete(sender, 0, message);

}

fn complete(sender: *Process, status: u64, message: u64) void {

    sender.state = .ready;
    sender.ticket = 0;
    sender.deadline = 0;

    sender.context.respond(.{

        .number = status,
        .first = message,

    });

}

pub fn expire(head: ?*Process, ticks: u64) void {

    var current = head;

    while (current) |task| : (current = task.next) {

        if (task.deadline == 0 or ticks < task.deadline) continue;
        if (task.state == .sleeping) complete(task, 0, 0);
        if (task.state == .replying or (task.state == .sending and task.ticket != 0)) complete(task, 6, 0);

    }

}

pub fn cancel(head: ?*Process, id: u64) void {

    var current = head;

    while (current) |sender| : (current = sender.next) {

        if ((sender.state != .sending and sender.state != .replying) or sender.destination != id) continue;

        complete(sender, 3, 0);

    }

}

/// Records interrupts `bits` for `task`; it receives them as one message from process 0.
pub fn signal(task: *Process, bits: u64) void {

    task.signals |= bits;
    if (task.state == .receiving) notify(task);

}

fn notify(receiver: *Process) void {

    receiver.context.respond(.{

        .number = 0,
        .second = receiver.signals,

    });

    receiver.signals = 0;
    receiver.state = .ready;

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

    receiver.state = .ready;

}
