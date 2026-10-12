//! What the input drivers share: turning scancodes into key events, and handing events to the display in order.

const std = @import("std");

const api = @import("api");

const protocol = api.protocol;
const Event = api.Event;
const Key = api.Key;

// Scancode set 1 (the controller translates) to US characters; zero marks keys without one.
const plain = "\x00\x001234567890-=\x00\x00qwertyuiop[]\x00\x00asdfghjkl;'`\x00\\zxcvbnm,./\x00*\x00 ";
const shifted = "\x00\x00!@#$%^&*()_+\x00\x00QWERTYUIOP{}\x00\x00ASDFGHJKL:\"~\x00|ZXCVBNM<>?\x00*\x00 ";

/// The keyboard's state: held modifiers, Caps Lock, and whether an 0xe0 prefix came last.
pub const Keyboard = struct {

    modifiers: Event.Modifiers = .{},
    extended: bool = false,
    caps: bool = false,

    /// The key event set-1 scancode byte `byte` completes, if any; USB keyboards translate their usages into these too.
    pub fn scancode(self: *Keyboard, byte: u8) ?Event {

        if (byte == 0xe0) {

            self.extended = true;
            return null;

        }

        const pressed = byte & 0x80 == 0;
        const code = byte & 0x7f;
        const prefixed = self.extended;

        self.extended = false;

        const which: Key = if (prefixed) switch (code) {

            0x1c => .enter,
            0x1d => .control,
            0x35 => .character,
            0x38 => .alt,
            0x47 => .home,
            0x48 => .up,
            0x49 => .page_up,
            0x4b => .left,
            0x4d => .right,
            0x4f => .end,
            0x50 => .down,
            0x51 => .page_down,
            0x52 => .insert,
            0x53 => .delete,
            0x5b, 0x5c => .super,
            else => .none,

        } else switch (code) {

            0x01 => .escape,
            0x0e => .backspace,
            0x0f => .tab,
            0x1c => .enter,
            0x1d => .control,
            0x2a, 0x36 => .shift,
            0x38 => .alt,
            0x3a => .caps_lock,
            0x3b...0x44 => @enumFromInt(@intFromEnum(Key.f1) + code - 0x3b),
            0x57 => .f11,
            0x58 => .f12,
            else => if (code < plain.len and plain[code] != 0) .character else .none,

        };

        switch (which) {

            .none => return null,
            .shift => self.modifiers.shift = pressed,
            .control => self.modifiers.control = pressed,
            .alt => self.modifiers.alt = pressed,
            .super => self.modifiers.super = pressed,
            .caps_lock => self.caps = self.caps != pressed,
            else => {

            },

        }

        var char: u16 = 0;

        if (which == .character) {

            const letter = std.ascii.isAlphabetic(plain[code]);

            char = if (prefixed) '/' else if (self.modifiers.shift != (letter and self.caps)) shifted[code] else plain[code];

        }

        return .{

            .kind = .key,
            .pressed = pressed,
            .modifiers = self.modifiers,

            .code = @intFromEnum(which),
            .char = char,

        };

    }

};

/// Events waiting for the display, with pointer movement folded into one pending event until something else comes.
pub const Relay = struct {

    queue: [64]Event = undefined,
    queued: usize = 0,

    motion: Event = .{

        .kind = .motion,

    },

    moved: bool = false,

    display: u64 = 0,
    retry: u64 = 0,

    /// Lends pending events to the display, oldest first, finding it again after a restart.
    pub fn forward(self: *Relay) void {

        if (self.queued < self.queue.len) self.settle();
        if (self.queued == 0) return;

        if (self.display == 0) {

            if (api.ticks() < self.retry) return;
            self.retry = api.ticks() + 100;
            self.display = api.lookup(0, .display) catch return;

        }

        _ = api.exchange(self.display, protocol.pack(.input, 0), std.mem.sliceAsBytes(self.queue[0..self.queued])) catch {

            self.display = 0;
            return;

        };

        self.queued = 0;

    }

    /// Folds one report into the pending pointer event: relative motion adds up, absolute positions replace.
    pub fn report(self: *Relay, kind: Event.Kind, buttons: u8, x: i32, y: i32) void {

        // Button changes close the current motion so presses stay ordered against movement.
        if (kind != self.motion.kind or buttons != self.motion.code) self.settle();

        const relative = kind == .motion;

        self.motion.kind = kind;
        self.motion.code = buttons;
        self.motion.x = @intCast(std.math.clamp(if (relative) self.motion.x +| x else x, -32768, 32767));
        self.motion.y = @intCast(std.math.clamp(if (relative) self.motion.y +| y else y, -32768, 32767));
        self.moved = true;

    }

    /// Reports each wheel step as a press of button 3 (away from the user, for negative `steps`) or 4 (towards), as X11 numbers them.
    pub fn scroll(self: *Relay, steps: i8) void {

        if (steps == 0) return;

        // The wheel acts where the pointer is, so the movement before it goes first.
        self.settle();

        for (0..@abs(steps)) |_| {

            self.push(.{

                .kind = .button,
                .pressed = true,
                .code = if (steps < 0) 3 else 4,

            });

        }

    }

    /// Queues the pending pointer event so whatever follows stays ordered after it.
    pub fn settle(self: *Relay) void {

        if (!self.moved) return;

        self.push(self.motion);
        self.motion.x = 0;
        self.motion.y = 0;
        self.moved = false;

    }

    pub fn push(self: *Relay, event: Event) void {

        // ponytail: a full queue drops input, which only builds up while the display is away; keep more if early keys matter.
        if (self.queued == self.queue.len) return;

        self.queue[self.queued] = event;
        self.queued += 1;

    }

};
