//! One TCP connection's state machine, apart from any device or clock: segments go in through `input`, come out of
//! `output`, and time passes through `tick`, all counted in 100 Hz ticks.

const std = @import("std");

const wire = @import("wire.zig");

pub const Flags = wire.Flags;
pub const Segment = wire.Segment;

pub const State = enum {

    closed,
    syn_sent,
    syn_received,
    established,
    fin_wait1,
    fin_wait2,
    close_wait,
    closing,
    last_ack,
    time_wait,

};

/// Bytes queued in a power-of-two buffer that wraps around.
pub const Ring = struct {

    bytes: []u8 = &.{},
    start: usize = 0,
    length: usize = 0,

    pub fn free(self: *const Ring) usize {

        return self.bytes.len - self.length;

    }

    /// Up to `count` queued bytes from `offset` on, in at most two pieces where they wrap.
    pub fn queued(self: *const Ring, offset: usize, count: usize) [2][]u8 {

        return self.pieces(self.start + offset, @min(count, self.length -| offset));

    }

    /// Up to `count` free bytes after the queue, in at most two pieces; `fill` counts in what was written there.
    pub fn vacant(self: *const Ring, count: usize) [2][]u8 {

        return self.pieces(self.start + self.length, @min(count, self.free()));

    }

    pub fn fill(self: *Ring, count: usize) void {

        self.length += count;

    }

    /// Queues as much of `data` as fits; returns how much did.
    pub fn push(self: *Ring, data: []const u8) usize {

        const parts = self.vacant(data.len);

        @memcpy(parts[0], data[0..parts[0].len]);
        @memcpy(parts[1], data[parts[0].len..][0..parts[1].len]);
        self.fill(parts[0].len + parts[1].len);

        return parts[0].len + parts[1].len;

    }

    /// Copies queued bytes from `offset` on into `out`, leaving them queued; returns how many it copied.
    pub fn peek(self: *const Ring, offset: usize, out: []u8) usize {

        const parts = self.queued(offset, out.len);

        @memcpy(out[0..parts[0].len], parts[0]);
        @memcpy(out[parts[0].len..][0..parts[1].len], parts[1]);

        return parts[0].len + parts[1].len;

    }

    fn pieces(self: *const Ring, from: usize, count: usize) [2][]u8 {

        if (count == 0) return .{ &.{}, &.{} };

        const at = from & (self.bytes.len - 1);
        const first = @min(count, self.bytes.len - at);

        return .{ self.bytes[at..][0..first], self.bytes[0 .. count - first] };

    }

    pub fn discard(self: *Ring, count: usize) void {

        const size = @min(count, self.length);

        self.start = (self.start + size) & (self.bytes.len - 1);
        self.length -= size;

    }

};

/// Retransmission timeouts, in ticks: the first guess, and the bounds any estimate keeps to.
const initial = 100;
const shortest = 20;
const longest = 6000;

/// Tries at any one segment before the connection is given up for lost.
const attempts = 8;

/// How long a closed connection lingers to absorb stray segments.
const lingering = 200;

/// A segment's own bytes come from `tx` at `offset`, `length` of them.
pub const Outgoing = struct {

    segment: Segment,
    offset: usize = 0,
    length: usize = 0,

};

pub const Connection = struct {

    state: State = .closed,

    local_port: u16 = 0,
    remote_port: u16 = 0,

    /// Sending: the oldest byte not yet acknowledged, the next to send, and the peer's window and largest segment.
    unacknowledged: u32 = 0,
    next: u32 = 0,
    initial: u32 = 0,
    window: u32 = 0,
    mss: u16 = 536,

    /// Receiving: the next byte expected, and the window last offered.
    expected: u32 = 0,
    offered: u32 = 0,

    /// Bytes from `unacknowledged` on, sent or not, and bytes received but not yet read.
    tx: Ring = .{},
    rx: Ring = .{},

    /// The app closed its side, so a FIN follows the last byte.
    finishing: bool = false,

    /// The peer sent its FIN; reads end once `rx` drains.
    finished: bool = false,

    /// The peer reset the connection, or it was given up for lost after going unanswered.
    reset: bool = false,
    expired: bool = false,

    acknowledge: bool = false,

    /// Retransmission: when it fires, its timeout, and the tries so far; and one segment timed for a round-trip sample.
    retransmit: u64 = 0,
    timeout: u64 = initial,
    tries: u8 = 0,
    timing: ?u32 = null,
    sent_at: u64 = 0,
    smoothed: u64 = 0,
    variance: u64 = 0,

    /// Lets one byte past a closed window probe whether it opened.
    probe: bool = false,

    /// When a lingering connection finally closes.
    deadline: u64 = 0,

    /// Starts an active open from `local_port` with initial sequence number `iss`.
    pub fn open(self: *Connection, local_port: u16, remote_port: u16, iss: u32, mss: u16) void {

        self.* = .{

            .tx = .{ .bytes = self.tx.bytes },
            .rx = .{ .bytes = self.rx.bytes },
            .state = .syn_sent,
            .local_port = local_port,
            .remote_port = remote_port,
            .unacknowledged = iss,
            .next = iss,
            .initial = iss,
            .mss = mss,

        };

    }

    /// Answers `syn`, which reached a listening port, as a passive open.
    pub fn accept(self: *Connection, syn: Segment, iss: u32, mss: u16) void {

        self.open(syn.destination, syn.source, iss, @min(mss, syn.mss orelse 536));
        self.state = .syn_received;
        self.expected = syn.sequence +% 1;
        self.window = syn.window;

    }

    /// The app is done sending; a FIN follows what it queued.
    pub fn close(self: *Connection) void {

        switch (self.state) {

            .syn_sent, .syn_received => self.state = .closed,
            .established => self.state = .fin_wait1,
            .close_wait => self.state = .last_ack,
            else => {

            },

        }

        self.finishing = true;

    }

    /// Bytes the app may still read before the stream ends.
    pub fn readable(self: *const Connection) bool {

        return self.rx.length != 0 or self.finished or self.reset;

    }

    /// Whether the app may queue more bytes.
    pub fn writable(self: *const Connection) bool {

        return switch (self.state) {

            .established, .close_wait => !self.finishing and self.tx.free() != 0,
            else => false,

        };

    }

    /// Queues bytes to send; returns how many fit.
    pub fn write(self: *Connection, data: []const u8) usize {

        return if (self.writable()) self.tx.push(data) else 0;

    }

    /// Moves received bytes into `out`; returns how many.
    pub fn read(self: *Connection, out: []u8) usize {

        const count = self.rx.peek(0, out);

        self.consumed(count);

        return count;

    }

    /// Lets `count` bytes the app took from `rx` go, offering a wider window once that frees a good part of it.
    pub fn consumed(self: *Connection, count: usize) void {

        self.rx.discard(count);
        if (self.offered < self.rx.bytes.len / 2 and self.rx.free() >= self.rx.bytes.len / 2) self.acknowledge = true;

    }

    /// Takes one segment from the peer at tick `now`.
    pub fn input(self: *Connection, segment: Segment, now: u64) void {

        if (self.state == .closed) return;

        if (self.state == .syn_sent) return self.answered(segment, now);

        if (segment.flags.rst) {

            if (segment.sequence == self.expected) self.lose();
            return;

        }

        if (segment.flags.syn) {

            // A repeated SYN means our SYN-ACK went missing.
            if (self.state == .syn_received and segment.sequence == self.expected -% 1) self.next = self.initial;
            self.acknowledge = true;
            return;

        }

        // Only bytes from where we expect are taken: a segment ahead of that waits for a retransmission, and one partly
        // seen before is trimmed.
        var payload = segment.payload;
        var fin = segment.flags.fin;
        const behind = self.expected -% segment.sequence;

        if (behind != 0) {

            if (segment.span() != 0) self.acknowledge = true;

            if (@as(i32, @bitCast(behind)) < 0 or behind > payload.len) {

                payload = &.{};
                fin = false;

            } else {

                payload = payload[behind..];

            }

        }

        if (!segment.flags.ack) return;

        if (self.state == .syn_received) {

            if (segment.acknowledgment != self.initial +% 1) return;

            self.state = .established;
            self.unacknowledged = self.initial +% 1;
            self.retransmit = 0;
            self.tries = 0;
            self.sample(now);

        }

        self.acknowledged(segment, now);

        if (self.state == .closed) return;

        if (payload.len != 0 and self.receiving()) {

            const taken = self.rx.push(payload);

            self.expected +%= @intCast(taken);
            self.acknowledge = true;
            if (taken != payload.len) return;

        }

        if (fin and !self.finished) {

            self.expected +%= 1;
            self.finished = true;
            self.acknowledge = true;

            switch (self.state) {

                .established => self.state = .close_wait,
                .fin_wait1 => self.state = .closing,
                .fin_wait2 => self.linger(now),
                else => {

                },

            }

        }

    }

    /// The next segment to send, if any is due; call it until it returns null.
    pub fn output(self: *Connection, now: u64) ?Outgoing {

        switch (self.state) {

            .closed, .time_wait => {

                if (!self.acknowledge or self.state == .closed) return null;
                self.acknowledge = false;

                return .{

                    .segment = self.header(.{ .ack = true }),

                };

            },
            .syn_sent, .syn_received => {

                if (self.next != self.initial) return null;

                self.next = self.initial +% 1;
                self.arm(now);

                var segment = self.header(.{ .syn = true, .ack = self.state == .syn_received });

                segment.sequence = self.initial;
                segment.mss = self.mss;

                return .{

                    .segment = segment,

                };

            },
            else => {

            },

        }

        const flight: usize = self.next -% self.unacknowledged;
        const room = @max(self.window, @intFromBool(self.probe)) -| flight;
        const size = @min(self.tx.length -| flight, room, self.mss);

        if (size != 0) {

            self.probe = false;
            if (self.timing == null) self.time(now);
            self.next +%= @intCast(size);
            self.arm(now);

            var segment = self.header(.{ .ack = true, .psh = true });

            segment.sequence = self.next -% @as(u32, @intCast(size));

            return .{

                .segment = segment,
                .offset = flight,
                .length = size,

            };

        }

        // Bytes held back by a closed window still need the timer, which turns into a probe.
        if (self.tx.length > flight and self.retransmit == 0) self.retransmit = now + self.timeout;

        // A FIN goes once every byte before it has been sent, and goes again whenever a retransmission rewinds.
        const fin = self.unacknowledged +% @as(u32, @intCast(self.tx.length));

        if (self.finishing and self.next == fin and self.closing()) {

            self.next +%= 1;
            self.arm(now);

            var segment = self.header(.{ .ack = true, .fin = true });

            segment.sequence = fin;

            return .{

                .segment = segment,

            };

        }

        if (!self.acknowledge) return null;

        return .{

            .segment = self.header(.{ .ack = true }),

        };

    }

    /// Retransmits once the timer runs out, and closes a lingering connection; returns whether anything changed.
    pub fn tick(self: *Connection, now: u64) bool {

        if (self.state == .time_wait and now >= self.deadline) {

            self.state = .closed;
            return true;

        }

        if (self.retransmit == 0 or now < self.retransmit) return false;

        self.tries += 1;

        if (self.tries > attempts or ((self.state == .syn_sent or self.state == .syn_received) and self.tries > 4)) {

            self.lose();
            self.expired = true;
            return true;

        }

        // Go back to the oldest unacknowledged byte, and back off; a closed window gets a one-byte probe instead.
        self.probe = self.window == 0;
        self.next = self.unacknowledged;
        self.timing = null;
        self.timeout = @min(self.timeout * 2, longest);
        self.retransmit = 0;

        return true;

    }

    /// The tick when `tick` next has work, or zero for none.
    pub fn due(self: *const Connection) u64 {

        return if (self.state == .time_wait) self.deadline else self.retransmit;

    }

    fn answered(self: *Connection, segment: Segment, now: u64) void {

        const fits = segment.flags.ack and segment.acknowledgment == self.initial +% 1;

        if (segment.flags.rst) {

            if (fits) self.lose();
            return;

        }

        if (!segment.flags.syn or !fits) return;

        self.expected = segment.sequence +% 1;
        self.unacknowledged = segment.acknowledgment;
        self.window = segment.window;
        self.mss = @min(self.mss, segment.mss orelse 536);
        self.state = .established;
        self.acknowledge = true;
        self.retransmit = 0;
        self.tries = 0;
        self.sample(now);

    }

    /// Takes the acknowledgment and window `segment` carries.
    fn acknowledged(self: *Connection, segment: Segment, now: u64) void {

        const advance = segment.acknowledgment -% self.unacknowledged;
        const flight = self.next -% self.unacknowledged;

        if (advance > flight) return;

        self.window = segment.window;
        if (advance == 0) return;

        // The FIN takes a place in sequence space but none in `tx`.
        const fin_acknowledged = self.finishing and advance > self.tx.length;

        self.tx.discard(advance);
        self.unacknowledged = segment.acknowledgment;
        self.tries = 0;

        if (self.timing) |timed| {

            if (@as(i32, @bitCast(segment.acknowledgment -% timed)) > 0) self.sample(now);

        }

        self.retransmit = if (self.next == self.unacknowledged) 0 else now + self.timeout;

        if (!fin_acknowledged) return;

        switch (self.state) {

            .fin_wait1 => self.state = .fin_wait2,
            .closing => self.linger(now),
            .last_ack => self.state = .closed,
            else => {

            },

        }

    }

    /// Folds one round-trip time into the smoothed estimate and its variance, as RFC 6298 does.
    fn sample(self: *Connection, now: u64) void {

        const measured = now -| self.sent_at;

        if (self.smoothed == 0) {

            self.smoothed = @max(measured, 1);
            self.variance = self.smoothed / 2;

        } else {

            const difference = if (measured > self.smoothed) measured - self.smoothed else self.smoothed - measured;

            self.variance = (3 * self.variance + difference) / 4;
            self.smoothed = (7 * self.smoothed + measured) / 8;

        }

        self.timeout = std.math.clamp(self.smoothed + @max(1, 4 * self.variance), shortest, longest);
        self.timing = null;

    }

    fn time(self: *Connection, now: u64) void {

        self.timing = self.next;
        self.sent_at = now;

    }

    fn arm(self: *Connection, now: u64) void {

        if (self.retransmit == 0) self.retransmit = now + self.timeout;
        if (self.timing == null and (self.state == .syn_sent or self.state == .syn_received)) self.sent_at = now;

    }

    fn linger(self: *Connection, now: u64) void {

        self.state = .time_wait;
        self.deadline = now + lingering;
        self.retransmit = 0;

    }

    fn lose(self: *Connection) void {

        self.state = .closed;
        self.reset = true;
        self.retransmit = 0;

    }

    fn receiving(self: *const Connection) bool {

        return switch (self.state) {

            .established, .fin_wait1, .fin_wait2 => true,
            else => false,

        };

    }

    fn closing(self: *const Connection) bool {

        return switch (self.state) {

            .fin_wait1, .closing, .last_ack => true,
            else => false,

        };

    }

    /// A segment from the connection's current place, acknowledging what arrived and offering the room left.
    fn header(self: *Connection, flags: Flags) Segment {

        self.acknowledge = false;
        self.offered = @min(self.rx.free(), 0xffff);

        return .{

            .source = self.local_port,
            .destination = self.remote_port,
            .sequence = self.next,
            .acknowledgment = self.expected,
            .flags = flags,
            .window = @intCast(self.offered),

        };

    }

};
