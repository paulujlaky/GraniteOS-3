const Process = @import("process.zig").Process;

/// The next ready process homed on processor `home` after `previous`, in id order and wrapping round;
/// with none, the first ready process homed elsewhere, so an idle processor takes over work a busy one cannot get to.
pub fn choose(head: ?*Process, home: u32, previous: u64) ?*Process {

    var next: ?*Process = null;
    var first: ?*Process = null;
    var stray: ?*Process = null;
    var current = head;

    while (current) |task| : (current = task.next) {

        if (task.state != .ready) continue;

        if (task.home != home) {

            if (stray == null or task.id < stray.?.id) stray = task;
            continue;

        }

        if (first == null or task.id < first.?.id) first = task;
        if (task.id > previous and (next == null or task.id < next.?.id)) next = task;

    }

    return next orelse first orelse stray;

}

/// How many processes are ready but not running.
pub fn waiting(head: ?*Process) usize {

    var count: usize = 0;
    var current = head;

    while (current) |task| : (current = task.next) {

        if (task.state == .ready) count += 1;

    }

    return count;

}
