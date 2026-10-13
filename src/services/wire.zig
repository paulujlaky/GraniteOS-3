//! Frames and packets as they cross the wire: Ethernet, ARP, IPv4, ICMP, UDP, and TCP headers in network byte order,
//! and the Internet checksum. IPv4 addresses are host-order numbers here.

const std = @import("std");

pub const Mac = [6]u8;
pub const broadcast: Mac = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };

pub const ethernet_length = 14;
pub const ip_length = 20;
pub const udp_length = 8;
pub const tcp_length = 20;

/// The largest IPv4 packet one Ethernet frame carries.
pub const mtu = 1500;

pub const arp = 0x0806;
pub const ipv4 = 0x0800;

pub const icmp = 1;
pub const tcp = 6;
pub const udp = 17;

pub const Flags = packed struct(u8) {

    fin: bool = false,
    syn: bool = false,
    rst: bool = false,
    psh: bool = false,
    ack: bool = false,
    urg: bool = false,
    ece: bool = false,
    cwr: bool = false,

};

pub const Frame = struct {

    destination: Mac,
    source: Mac,
    kind: u16,
    payload: []const u8,

};

pub const Arp = struct {

    request: bool,
    sender: Mac,
    sender_address: u32,
    target_address: u32,

};

pub const Ip = struct {

    protocol: u8,
    source: u32,
    destination: u32,
    payload: []const u8,

};

pub const Udp = struct {

    source: u16,
    destination: u16,
    payload: []const u8,

};

pub const Segment = struct {

    source: u16 = 0,
    destination: u16 = 0,
    sequence: u32 = 0,
    acknowledgment: u32 = 0,
    flags: Flags = .{},
    window: u16 = 0,

    /// The largest segment the sender takes, offered with a SYN.
    mss: ?u16 = null,

    payload: []const u8 = &.{},

    /// Sequence space it takes: its bytes, plus one each for SYN and FIN.
    pub fn span(self: Segment) u32 {

        return @intCast(self.payload.len + @intFromBool(self.flags.syn) + @intFromBool(self.flags.fin));

    }

};

pub fn frame(bytes: []const u8) ?Frame {

    if (bytes.len < ethernet_length) return null;

    return .{

        .destination = bytes[0..6].*,
        .source = bytes[6..12].*,
        .kind = be(u16, bytes[12..14]),
        .payload = bytes[ethernet_length..],

    };

}

/// Writes an Ethernet header to the front of `out`.
pub fn ethernet(out: []u8, destination: Mac, source: Mac, kind: u16) void {

    out[0..6].* = destination;
    out[6..12].* = source;
    put(u16, out[12..14], kind);

}

/// Reads an ARP packet for IPv4 over Ethernet.
pub fn parseArp(bytes: []const u8) ?Arp {

    if (bytes.len < 28 or be(u16, bytes[0..2]) != 1 or be(u16, bytes[2..4]) != ipv4 or bytes[4] != 6 or bytes[5] != 4) return null;

    const operation = be(u16, bytes[6..8]);
    if (operation != 1 and operation != 2) return null;

    return .{

        .request = operation == 1,
        .sender = bytes[8..14].*,
        .sender_address = be(u32, bytes[14..18]),
        .target_address = be(u32, bytes[24..28]),

    };

}

/// Writes a 28-byte ARP request, or a reply when `target` is known.
pub fn writeArp(out: []u8, sender: Mac, sender_address: u32, target: ?Mac, target_address: u32) void {

    put(u16, out[0..2], 1);
    put(u16, out[2..4], ipv4);
    out[4] = 6;
    out[5] = 4;
    put(u16, out[6..8], if (target == null) 1 else 2);
    out[8..14].* = sender;
    put(u32, out[14..18], sender_address);
    out[18..24].* = target orelse .{ 0, 0, 0, 0, 0, 0 };
    put(u32, out[24..28], target_address);

}

/// Reads an IPv4 packet whose header checks out; fragments are refused, as nothing here reassembles them.
pub fn parseIp(bytes: []const u8) ?Ip {

    if (bytes.len < ip_length or bytes[0] >> 4 != 4) return null;

    const header = @as(usize, bytes[0] & 0xf) * 4;
    const total = be(u16, bytes[2..4]);

    if (header < ip_length or total < header or total > bytes.len) return null;
    if (be(u16, bytes[6..8]) & 0x3fff != 0) return null;
    if (fold(sum(0, bytes[0..header])) != 0) return null;

    return .{

        .protocol = bytes[9],
        .source = be(u32, bytes[12..16]),
        .destination = be(u32, bytes[16..20]),
        .payload = bytes[header..total],

    };

}

/// Writes a 20-byte IPv4 header for `length` bytes of payload, which follow it in `out`.
pub fn writeIp(out: []u8, protocol: u8, source: u32, destination: u32, length: usize, id: u16) void {

    out[0] = 0x45;
    out[1] = 0;
    put(u16, out[2..4], @intCast(ip_length + length));
    put(u16, out[4..6], id);

    // Don't fragment: segments are sized to fit.
    put(u16, out[6..8], 0x4000);

    out[8] = 64;
    out[9] = protocol;
    put(u16, out[10..12], 0);
    put(u32, out[12..16], source);
    put(u32, out[16..20], destination);
    put(u16, out[10..12], fold(sum(0, out[0..ip_length])));

}

/// Reads a UDP datagram, checking its checksum when it has one.
pub fn parseUdp(packet: Ip) ?Udp {

    const bytes = packet.payload;
    if (bytes.len < udp_length) return null;

    const length = be(u16, bytes[4..6]);

    if (length < udp_length or length > bytes.len) return null;
    if (be(u16, bytes[6..8]) != 0 and fold(pseudo(packet.source, packet.destination, udp, bytes[0..length])) != 0) return null;

    return .{

        .source = be(u16, bytes[0..2]),
        .destination = be(u16, bytes[2..4]),
        .payload = bytes[udp_length..length],

    };

}

/// Writes a UDP header over `out[0..8]` for the payload after it, checksum included.
pub fn writeUdp(out: []u8, source: u32, destination: u32, source_port: u16, destination_port: u16) void {

    put(u16, out[0..2], source_port);
    put(u16, out[2..4], destination_port);
    put(u16, out[4..6], @intCast(out.len));
    put(u16, out[6..8], 0);

    const check = fold(pseudo(source, destination, udp, out));

    put(u16, out[6..8], if (check == 0) 0xffff else check);

}

/// Reads a TCP segment whose checksum checks out.
pub fn parseTcp(packet: Ip) ?Segment {

    const bytes = packet.payload;
    if (bytes.len < tcp_length or fold(pseudo(packet.source, packet.destination, tcp, bytes)) != 0) return null;

    const header = @as(usize, bytes[12] >> 4) * 4;
    if (header < tcp_length or header > bytes.len) return null;

    var segment = Segment{

        .source = be(u16, bytes[0..2]),
        .destination = be(u16, bytes[2..4]),
        .sequence = be(u32, bytes[4..8]),
        .acknowledgment = be(u32, bytes[8..12]),
        .flags = @bitCast(bytes[13]),
        .window = be(u16, bytes[14..16]),
        .payload = bytes[header..],

    };

    // Options: only the maximum segment size matters here.
    var at: usize = tcp_length;

    while (at < header) {

        const kind = bytes[at];

        if (kind == 0) break;

        if (kind == 1) {

            at += 1;
            continue;

        }

        if (at + 1 >= header or bytes[at + 1] < 2) break;
        if (kind == 2 and bytes[at + 1] == 4 and at + 4 <= header) segment.mss = be(u16, bytes[at + 2 ..][0..2]);
        at += bytes[at + 1];

    }

    return segment;

}

/// Writes `segment`'s header to the front of `out`, whose payload already follows it, and checksums the whole; returns the
/// header's length.
pub fn writeTcp(out: []u8, source: u32, destination: u32, segment: Segment) usize {

    const header: usize = if (segment.mss == null) tcp_length else tcp_length + 4;

    put(u16, out[0..2], segment.source);
    put(u16, out[2..4], segment.destination);
    put(u32, out[4..8], segment.sequence);
    put(u32, out[8..12], segment.acknowledgment);
    out[12] = @intCast(header / 4 << 4);
    out[13] = @bitCast(segment.flags);
    put(u16, out[14..16], segment.window);
    put(u32, out[16..20], 0);

    if (segment.mss) |size| {

        out[20] = 2;
        out[21] = 4;
        put(u16, out[22..24], size);

    }

    const length = header + segment.payload.len;

    put(u16, out[16..18], fold(pseudo(source, destination, tcp, out[0..length])));

    return header;

}

/// The Internet checksum's running sum over `bytes`, an even number of them unless they come last.
pub fn sum(start: u32, bytes: []const u8) u32 {

    var total: u64 = start;
    var index: usize = 0;

    while (index + 1 < bytes.len) : (index += 2) total += be(u16, bytes[index..][0..2]);
    if (index < bytes.len) total += @as(u32, bytes[index]) << 8;

    while (total >> 32 != 0) total = (total & 0xffffffff) + (total >> 32);

    return @intCast(total);

}

/// Folds a running sum into the checksum written to the wire.
pub fn fold(total: u32) u16 {

    var value = total;

    while (value >> 16 != 0) value = (value & 0xffff) + (value >> 16);

    return ~@as(u16, @intCast(value));

}

/// The running sum over UDP's or TCP's pseudo-header and `bytes`.
fn pseudo(source: u32, destination: u32, protocol: u8, bytes: []const u8) u32 {

    var header: [12]u8 = undefined;

    put(u32, header[0..4], source);
    put(u32, header[4..8], destination);
    header[8] = 0;
    header[9] = protocol;
    put(u16, header[10..12], @intCast(bytes.len));

    return sum(sum(0, &header), bytes);

}

pub fn be(comptime T: type, bytes: *const [@sizeOf(T)]u8) T {

    return std.mem.readInt(T, bytes, .big);

}

pub fn put(comptime T: type, bytes: *[@sizeOf(T)]u8, value: T) void {

    std.mem.writeInt(T, bytes, value, .big);

}
