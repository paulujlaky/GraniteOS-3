const std = @import("std");

const api = @import("api");

const protocol = api.protocol;
const Event = api.Event;
const Key = api.Key;
pub const panic = api.panic;

const data = 0x60;
const control = 0x64;

// Held keys repeat after 250 ms at 30 per second, as Linux and Windows set them; the power-on default is 500 ms at 10.9.
const typematic = 0x00;

// Scancode set 1 (the controller translates) to US characters; zero marks keys without one.
const plain = "\x00\x001234567890-=\x00\x00qwertyuiop[]\x00\x00asdfghjkl;'`\x00\\zxcvbnm,./\x00*\x00 ";
const shifted = "\x00\x00!@#$%^&*()_+\x00\x00QWERTYUIOP{}\x00\x00ASDFGHJKL:\"~\x00|ZXCVBNM<>?\x00*\x00 ";

// Backdoor calls for VMware's absolute pointer, numbered as in Linux's vmmouse driver.
const Backdoor = enum(u32) {

    data = 39,
    status = 40,
    command = 41,

};

var queue: [64]Event = undefined;
var queued: usize = 0;

var packet: [4]u8 = undefined;
var size: usize = 3;
var received: usize = 0;
var motion = Event{

    .kind = .motion,

};
var moved = false;

/// Whether VMware's absolute pointer supplies pointer data, leaving PS/2 mouse bytes only to announce it.
var absolute = false;

var modifiers = Event.Modifiers{};
var extended = false;
var caps = false;

var display: u64 = 0;
var retry: u64 = 0;

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .service);
    if (!api.permits(.ports) or api.permits(.mmio) or api.permits(.management)) api.exit(2);

    command(0xad);
    command(0xa7);
    flush();

    command(0x20);
    const configuration = receive() orelse api.exit(3);

    // Both clocks and both interrupts on, and translation to scancode set 1.
    command(0x60);
    send(configuration & ~@as(u8, 0x30) | 0x43);
    command(0xae);
    command(0xa8);
    flush();

    _ = device(false, 0xf3) and device(false, typematic);
    const keyboard = device(false, 0xf4);
    const mouse = device(true, 0xf6) and wheel() and device(true, 0xf4);

    if (!keyboard and !mouse) api.exit(3);

    absolute = mouse and vmware() and attach();
    api.log(if (absolute) "input: ready (vmmouse)\n" else "input: ready\n");

    while (true) {

        const request = api.receive(true) catch continue;

        // The kernel reports controller interrupts as a message from no process.
        if (request.first == 0) {

            drain();
            forward();
            continue;

        }

        const result: u64 = switch (protocol.operation(request.second)) {

            .hello => protocol.version,
            .crash => if (request.first == api.raw(.owner, 0, 0, 0).first) fault() else protocol.invalid,
            else => protocol.invalid,

        };

        api.reply(request, result) catch {

        };

    }

}

/// Lends pending events to the display, oldest first, finding it again after a restart.
fn forward() void {

    if (queued < queue.len) settle();
    if (queued == 0) return;

    if (display == 0) {

        if (api.ticks() < retry) return;
        retry = api.ticks() + 100;
        display = api.lookup(0, .display) catch return;

    }

    _ = api.exchange(display, protocol.pack(.input, 0), std.mem.sliceAsBytes(queue[0..queued])) catch {

        display = 0;
        return;

    };

    queued = 0;

}

fn drain() void {

    for (0..256) |_| {

        const status = input(control);
        if (status & 1 == 0) break;

        const byte = input(data);

        if (status & 0x20 == 0) key(byte) else if (!absolute) pointer(byte);

    }

    if (absolute) poll();

}

fn pointer(byte: u8) void {

    // A first byte without bit 3 means the stream lost sync.
    if (received == 0 and byte & 8 == 0) return;

    packet[received] = byte;
    received += 1;
    if (received < size) return;

    received = 0;
    if (packet[0] & 0xc0 != 0) return;

    const dx = @as(i32, packet[1]) - (@as(i32, packet[0] & 0x10) << 4);
    const dy = @as(i32, packet[2]) - (@as(i32, packet[0] & 0x20) << 3);

    report(.motion, packet[0] & 7, dx, -dy);
    if (size == 4) scroll(@bitCast(packet[3]));

}

/// Reports every packet waiting in VMware's pointer queue, handing the pointer back to PS/2 on a protocol error.
fn poll() void {

    for (0..256) |_| {

        const words = waiting() orelse return detach();
        if (words == 0) return;
        if (words % 4 != 0) return detach();

        const status, const x, const y, const z = backdoor(.data, 4);

        // VMware holds left, right, and middle in bits 5, 4, and 3; events count them up from bit 0.
        const buttons: u8 = @intCast((status >> 5 & 1) | (status >> 3 & 2) | (status >> 1 & 4));

        // Relative packets come when the host asks for them, with y growing upwards as in PS/2.
        if (status & 0x10000 != 0) {

            report(.motion, buttons, @bitCast(x), -%@as(i32, @bitCast(y)));

        } else {

            report(.pointer, buttons, @intCast(x >> 1), @intCast(y >> 1));

        }

        scroll(@bitCast(@as(u8, @truncate(z))));

    }

}

/// Folds one packet into the pending pointer event: relative motion adds up, absolute positions replace.
fn report(kind: Event.Kind, buttons: u8, x: i32, y: i32) void {

    // Button changes close the current motion so presses stay ordered against movement.
    if (kind != motion.kind or buttons != motion.code) settle();

    const relative = kind == .motion;

    motion.kind = kind;
    motion.code = buttons;
    motion.x = @intCast(std.math.clamp(if (relative) motion.x +| x else x, -32768, 32767));
    motion.y = @intCast(std.math.clamp(if (relative) motion.y +| y else y, -32768, 32767));
    moved = true;

}

/// Reports each wheel step as a press of button 3 (away from the user) or 4 (towards), as X11 numbers them.
fn scroll(steps: i8) void {

    if (steps == 0) return;

    // The wheel acts where the pointer is, so the movement before it goes first.
    settle();

    for (0..@abs(steps)) |_| {

        push(.{

            .kind = .button,
            .pressed = true,
            .code = if (steps < 0) 3 else 4,

        });

    }

}

/// Queues the pending pointer event so whatever follows stays ordered after it.
fn settle() void {

    if (!moved) return;

    push(motion);
    motion.x = 0;
    motion.y = 0;
    moved = false;

}

fn key(byte: u8) void {

    if (byte == 0xe0) {

        extended = true;
        return;

    }

    const pressed = byte & 0x80 == 0;
    const code = byte & 0x7f;
    const prefixed = extended;

    extended = false;

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

        .none => return,
        .shift => modifiers.shift = pressed,
        .control => modifiers.control = pressed,
        .alt => modifiers.alt = pressed,
        .super => modifiers.super = pressed,
        .caps_lock => caps = caps != pressed,
        else => {

        },

    }

    var char: u16 = 0;

    if (which == .character) {

        const letter = std.ascii.isAlphabetic(plain[code]);

        char = if (prefixed) '/' else if (modifiers.shift != (letter and caps)) shifted[code] else plain[code];

    }

    push(.{

        .kind = .key,
        .pressed = pressed,
        .modifiers = modifiers,

        .code = @intFromEnum(which),
        .char = char,

    });

}

fn push(event: Event) void {

    // ponytail: a full queue drops input, which only builds up while the display is away; keep more if early keys matter.
    if (queued == queue.len) return;

    queue[queued] = event;
    queued += 1;

}

/// Sends `byte` to the keyboard or, through the controller, the mouse; true when it acknowledges.
fn device(auxiliary: bool, byte: u8) bool {

    if (auxiliary) command(0xd4);
    send(byte);

    return receive() == 0xfa;

}

/// Unlocks an IntelliMouse wheel with the sample rate knock; a device ID of 3 then means four-byte packets.
fn wheel() bool {

    for ([_]u8{ 200, 100, 80 }) |rate| {

        if (!device(true, 0xf3) or !device(true, rate)) return false;

    }

    if (!device(true, 0xf2)) return false;
    if (receive() == 3) size = 4;

    // The knock leaves the rate at 80; restore the default.
    return device(true, 0xf3) and device(true, 100);

}

/// Whether CPUID reports a hypervisor that names itself VMware.
fn vmware() bool {

    if (cpuid(1)[2] & 0x80000000 == 0) return false;

    const leaf = cpuid(0x40000000);

    return std.mem.eql(u8, std.mem.asBytes(leaf[1..4]), "VMwareVMware");

}

/// Switches VMware's pointer to absolute positions; false leaves it off when it does not answer as expected.
fn attach() bool {

    // A restarted service may find the device still on with stale packets queued, so start it afresh.
    detach();
    _ = backdoor(.command, 0x45414552);

    // Enabling queues a version word, which proves the device is there.
    const words = waiting() orelse 0;

    if (words == 0 or backdoor(.data, 1)[0] != 0x3442554a) {

        detach();
        return false;

    }

    // Request absolute positions instead of relative motion.
    _ = backdoor(.command, 0x53424152);

    return true;

}

/// Disables VMware's pointer, handing pointer data back to the PS/2 stream.
fn detach() void {

    if (absolute) api.log("input: vmmouse failed; using PS/2\n");

    _ = backdoor(.command, 0xf5);
    absolute = false;
    received = 0;

}

/// Words queued by VMware's pointer, or null when it reports an error.
fn waiting() ?u16 {

    const status = backdoor(.status, 0)[0];

    return if (status & 0xffff0000 == 0xffff0000) null else @truncate(status);

}

/// One call through VMware's backdoor port, which the hypervisor answers even from ring 3.
fn backdoor(call: Backdoor, argument: u32) [4]u32 {

    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile ("inl %%dx, %%eax" // Trap to VMware, which reads the call from the registers.
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [magic] "{eax}" (@as(u32, 0x564d5868)),
          [argument] "{ebx}" (argument),
          [call] "{ecx}" (@intFromEnum(call)),
          [port] "{edx}" (@as(u32, 0x5658)),
        : .{

            .rsi = true,
            .rdi = true,
            .memory = true,

        });

    return .{ eax, ebx, ecx, edx };

}

fn cpuid(leaf: u32) [4]u32 {

    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile ("cpuid" // Identify the processor, which ring 3 may do.
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (@as(u32, 0)),
    );

    return .{ eax, ebx, ecx, edx };

}

fn flush() void {

    for (0..16) |_| {

        if (input(control) & 1 == 0) break;
        _ = input(data);

    }

}

fn command(byte: u8) void {

    if (!wait(2, 0)) api.exit(3);
    output(control, byte);

}

fn send(byte: u8) void {

    if (!wait(2, 0)) api.exit(3);
    output(data, byte);

}

fn receive() ?u8 {

    return if (wait(1, 1)) input(data) else null;

}

fn wait(mask: u8, value: u8) bool {

    const deadline = api.ticks() + 10;

    while (input(control) & mask != value) {

        if (api.ticks() >= deadline) return false;
        _ = api.raw(.yield, 0, 0, 0);

    }

    return true;

}

fn input(port: u16) u8 {

    const result = api.raw(.port, port, 0, 0);
    if (result.number != 0) api.exit(1);

    return @intCast(result.first);

}

fn output(port: u16, byte: u8) void {

    if (api.raw(.port, port, 1, byte).number != 0) api.exit(1);

}

fn fault() noreturn {

    asm volatile ("ud2");
    api.exit(1);

}
