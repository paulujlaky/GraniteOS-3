//! HD Audio codecs: reading a codec's widgets, finding a path from each line out, speaker, and headphone pin back to a
//! converter, and opening those paths at unity gain so one stream plays from all of them.

const std = @import("std");

/// Carries verbs to one codec and brings back its responses; the controller's command rings, or a test's codec.
pub const Link = struct {

    context: *anyopaque,

    /// Sends a whole command and returns the response, or null when none came.
    send: *const fn (context: *anyopaque, command: u32) ?u32,

    address: u4,

    /// A verb with a 12-bit identifier and an 8-bit payload.
    pub fn get(self: Link, node: u8, verb: u12, payload: u8) ?u32 {

        return self.send(self.context, @as(u32, self.address) << 28 | @as(u32, node) << 20 | @as(u32, verb) << 8 | payload);

    }

    /// A verb with a 4-bit identifier and a 16-bit payload.
    pub fn set(self: Link, node: u8, verb: u4, payload: u16) void {

        _ = self.send(self.context, @as(u32, self.address) << 28 | @as(u32, node) << 20 | @as(u32, verb) << 16 | payload);

    }

    pub fn parameter(self: Link, node: u8, which: Parameter) u32 {

        return self.get(node, verbs.parameter, @intFromEnum(which)) orelse 0;

    }

};

pub const Parameter = enum(u8) {

    vendor = 0x00,
    nodes = 0x04,
    group = 0x05,
    widget = 0x09,
    pin = 0x0c,
    input_amp = 0x0d,
    connections = 0x0e,
    output_amp = 0x12,

};

pub const verbs = struct {

    pub const parameter = 0xf00;
    pub const select = 0x701;
    pub const connection = 0xf02;
    pub const power = 0x705;
    pub const stream = 0x706;
    pub const pin_control = 0x707;
    pub const eapd = 0x70c;
    pub const configuration = 0xf1c;

    /// 4-bit verbs.
    pub const format = 0x2;
    pub const amp = 0x3;

};

pub const Kind = enum(u4) {

    output,
    input,
    mixer,
    selector,
    pin,
    power,
    knob,
    beep,
    _,

};

/// What a pin's default configuration says is plugged into it.
const Device = enum(u4) {

    line_out,
    speaker,
    headphones,
    _,

};

// Widget capabilities.
const input_amp_present = 1 << 1;
const output_amp_present = 1 << 2;
const amp_override = 1 << 3;
const listed = 1 << 8;
const digital = 1 << 9;
const powered = 1 << 10;

// Pin capabilities.
const headphone_drive = 1 << 3;
const output_capable = 1 << 4;
const eapd_capable = 1 << 16;

// Pin widget control bits.
const output_enable = 0x40;
const headphone_enable = 0x80;

/// The most connections kept for one widget, and widgets for one codec.
const reach = 32;
const most = 128;

/// The longest path walked from a pin to a converter, counting both.
const depth = 6;

pub const Widget = struct {

    kind: Kind = .output,
    caps: u32 = 0,

    /// A pin's default configuration and capabilities.
    configuration: u32 = 0,
    pin: u32 = 0,

    /// Amplifier capabilities, its own or the function group's.
    input_amp: u32 = 0,
    output_amp: u32 = 0,

    inputs: [reach]u8 = undefined,
    count: u8 = 0,

    fn connections(self: *const Widget) []const u8 {

        return self.inputs[0..self.count];

    }

    /// An analog pin wired to a jack or built in, driving line out, a speaker, or headphones.
    fn output(self: *const Widget) bool {

        if (self.kind != .pin or self.caps & digital != 0 or self.pin & output_capable == 0) return false;

        // Port connectivity 1 means nothing is attached.
        if (self.configuration >> 30 == 1) return false;

        return switch (self.device()) {

            .line_out, .speaker, .headphones => true,
            _ => false,

        };

    }

    fn device(self: *const Widget) Device {

        return @enumFromInt(@as(u4, @truncate(self.configuration >> 20)));

    }

};

/// One step of a path: a widget, and which of its connections leads on to the next.
const Step = struct {

    node: u8,
    index: u8 = 0,

};

pub const Codec = struct {

    vendor: u32 = 0,

    /// The audio function group's node, and its widgets from node `first` on.
    group: u8 = 0,
    first: u8 = 0,
    widgets: [most]Widget = undefined,
    count: u8 = 0,

    /// The converters the driven pins play from, and how many pins are driven.
    converters: [8]u8 = undefined,
    converter_count: u8 = 0,
    outputs: u8 = 0,

    /// Reads the codec's audio function group and its widgets; false when it has none, as a modem codec would.
    pub fn probe(self: *Codec, link: Link) bool {

        self.* = .{

            .vendor = link.parameter(0, .vendor),

        };

        const groups = link.parameter(0, .nodes);
        const base: u8 = @truncate(groups >> 16);

        self.group = for (0..@as(u8, @truncate(groups))) |offset| {

            const node: u8 = @intCast(base + offset);

            if (link.parameter(node, .group) & 0xff == 1) break node;

        } else return false;

        _ = link.get(self.group, verbs.power, 0);

        const nodes = link.parameter(self.group, .nodes);
        const input_amp = link.parameter(self.group, .input_amp);
        const output_amp = link.parameter(self.group, .output_amp);

        self.first = @truncate(nodes >> 16);
        self.count = @min(@as(u8, @truncate(nodes)), most);

        for (self.widgets[0..self.count], self.first..) |*widget, number| {

            const node: u8 = @intCast(number);
            const caps = link.parameter(node, .widget);
            const own = caps & amp_override != 0;

            widget.* = .{

                .kind = @enumFromInt(@as(u4, @truncate(caps >> 20))),
                .caps = caps,
                .input_amp = if (own) link.parameter(node, .input_amp) else input_amp,
                .output_amp = if (own) link.parameter(node, .output_amp) else output_amp,

            };

            if (widget.kind == .pin) {

                widget.configuration = link.get(node, verbs.configuration, 0) orelse 0;
                widget.pin = link.parameter(node, .pin);

            }

            if (caps & listed != 0) list(link, node, widget);

        }

        return true;

    }

    /// Opens a path to every output pin it can, at unity gain, each pin playing whatever converter it reaches.
    pub fn route(self: *Codec, link: Link) void {

        self.outputs = 0;
        self.converter_count = 0;

        for (self.widgets[0..self.count], self.first..) |*widget, number| {

            if (!widget.output()) continue;

            var path: [depth]Step = undefined;
            const length = self.search(@intCast(number), &path, 0) orelse continue;

            self.open(link, path[0..length]);
            self.outputs += 1;

            const converter = path[length - 1].node;

            if (std.mem.indexOfScalar(u8, self.converters[0..self.converter_count], converter) == null and self.converter_count < self.converters.len) {

                self.converters[self.converter_count] = converter;
                self.converter_count += 1;

            }

        }

    }

    /// Has every converter in use play stream `tag`'s samples, laid out as `format` says.
    pub fn start(self: *const Codec, link: Link, tag: u4, format: u16) void {

        for (self.converters[0..self.converter_count]) |converter| {

            _ = link.get(converter, verbs.stream, @as(u8, tag) << 4);
            link.set(converter, verbs.format, format);

        }

    }

    pub fn find(self: *Codec, node: u8) ?*Widget {

        if (node < self.first or node - self.first >= self.count) return null;

        return &self.widgets[node - self.first];

    }

    /// Fills `path` from `node` to the first analog converter it reaches through mixers and selectors; returns its length.
    fn search(self: *Codec, node: u8, path: *[depth]Step, at: usize) ?usize {

        const found = self.find(node) orelse return null;

        if (found.caps & digital != 0) return null;

        path[at] = .{

            .node = node,

        };

        if (found.kind == .output) return at + 1;
        if (at + 1 == depth) return null;

        // Only the pin starts a path; pins and inputs met further on lead elsewhere.
        if (at != 0 and found.kind != .mixer and found.kind != .selector) return null;

        for (found.connections(), 0..) |next, index| {

            path[at].index = @intCast(index);

            if (self.search(next, path, at + 1)) |length| return length;

        }

        return null;

    }

    fn open(self: *Codec, link: Link, path: []const Step) void {

        for (path) |step| {

            const found = self.find(step.node).?;

            if (found.caps & powered != 0) _ = link.get(step.node, verbs.power, 0);

            // Pins and selectors pass one connection on; mixers add theirs up, so only the one on the path is heard.
            if (found.kind != .output and found.kind != .mixer and found.count > 1) _ = link.get(step.node, verbs.select, step.index);

            if (found.caps & input_amp_present != 0) {

                // An amplifier's index field reaches the first sixteen connections.
                for (0..@min(found.count, 16)) |index| amplify(link, step.node, found.input_amp, .input, @intCast(index), found.kind != .mixer or index == step.index);

            }

            if (found.caps & output_amp_present != 0) amplify(link, step.node, found.output_amp, .output, 0, true);

            if (found.kind == .pin) {

                const headphones = found.device() == .headphones and found.pin & headphone_drive != 0;

                _ = link.get(step.node, verbs.pin_control, output_enable | if (headphones) @as(u8, headphone_enable) else 0);

                // External amplifiers, as many laptops and some boards have for speakers, wait for this.
                if (found.pin & eapd_capable != 0) _ = link.get(step.node, verbs.eapd, 2);

            }

        }

    }

};

const Direction = enum {

    input,
    output,

};

/// Sets both channels of an amplifier to 0 dB, as near as its steps allow, or mutes them.
fn amplify(link: Link, node: u8, caps: u32, direction: Direction, index: u4, on: bool) void {

    const steps: u7 = @truncate(caps >> 8);
    const unity: u7 = @min(@as(u7, @truncate(caps)), steps);
    const which: u16 = if (direction == .output) 1 << 15 else 1 << 14;

    link.set(node, verbs.amp, which | 3 << 12 | @as(u16, index) << 8 | if (on) @as(u16, unity) else 1 << 7);

}

/// Reads `node`'s connection list into `widget`, expanding ranges, as far as it holds.
fn list(link: Link, node: u8, widget: *Widget) void {

    const shape = link.parameter(node, .connections);
    const long = shape & 0x80 != 0;
    const length: u8 = @truncate(shape & 0x7f);
    const per: u8 = if (long) 2 else 4;
    var previous: u16 = 0;
    var index: u8 = 0;

    while (index < length) : (index += per) {

        const response = link.get(node, verbs.connection, index) orelse return;

        for (0..@min(per, length - index)) |slot| {

            const entry: u16 = if (long) @truncate(response >> @intCast(slot * 16)) else @as(u8, @truncate(response >> @intCast(slot * 8)));
            const range = entry & @as(u16, if (long) 0x8000 else 0x80) != 0;
            const value = @min(entry & @as(u16, if (long) 0x7fff else 0x7f), 0xff);

            var next = if (range and widget.count != 0) previous + 1 else value;

            while (next <= value and widget.count < reach) : (next += 1) {

                widget.inputs[widget.count] = @intCast(next);
                widget.count += 1;

            }

            previous = value;

        }

    }

}
