//! Intel e1000e Ethernet controllers, such as VMware's 82574L: one receive and one transmit ring of legacy descriptors,
//! each buffer half a DMA page.

const std = @import("std");

const wire = @import("wire.zig");

const api = @import("api");

// Registers, by offset into BAR 0.
const control = 0x0000;
const status = 0x0008;
const eeprom = 0x0010;
const extended = 0x0018;
const causes = 0x00c0;
const throttle = 0x00c4;
const enable = 0x00d0;
const disable = 0x00d8;
const receive_control = 0x0100;
const transmit_control = 0x0400;
const transmit_gap = 0x0410;
const receive_ring = 0x2800;
const transmit_ring = 0x3800;
const transmit_queue = 0x3828;
const multicast = 0x5200;
const address_low = 0x5400;
const address_high = 0x5404;

// Ring registers, by offset from the ring's base: address, length in bytes, head, and tail.
const base_low = 0x00;
const base_high = 0x04;
const length = 0x08;
const head = 0x10;
const tail = 0x18;

// Interrupt causes: link status changed, receive ring running low, receiver overrun, and a frame received.
const link_changed = 1 << 2;
const running_low = 1 << 4;
const overrun = 1 << 6;
const received = 1 << 7;

/// Descriptors in each ring: one page of them.
const count = 256;

/// Bytes each buffer holds, two to a page.
const buffer_size = 2048;

const Receive = extern struct {

    address: u64,
    length: u16,
    checksum: u16,

    /// Bit 0: the device filled it; bit 1: it ends a frame.
    status: u8,
    errors: u8,
    special: u16,

};

const Transmit = extern struct {

    address: u64,
    length: u16,
    offset: u8,
    command: u8,

    /// Bit 0: the device sent it.
    status: u8,
    start: u8,
    special: u16,

};

pub const Nic = struct {

    registers: usize,
    mac: wire.Mac,

    receives: *[count]Receive,
    transmits: *[count]Transmit,
    inbound: [count / 2]api.Page,
    outbound: [count / 2]api.Page,

    /// The next descriptor the device fills, the next we fill to send, and the oldest we have not seen sent.
    taken: usize = 0,
    filled: usize = 0,
    cleaned: usize = 0,

    /// Resets the controller at `base` and starts it with every receive buffer handed over.
    pub fn init(self: *Nic, base: u64, size: u64) !void {

        self.registers = @intFromPtr(try api.map(base, size));

        self.write(disable, 0xffffffff);
        self.write(receive_control, 0);
        self.write(transmit_control, 0);
        _ = self.read(status);
        api.sleep(1);

        // The reset reloads the address and settings from the EEPROM.
        self.write(control, self.read(control) | 1 << 26);
        api.sleep(2);
        try self.until(control, 1 << 26, 0);
        try self.until(eeprom, 1 << 9, 1 << 9);
        self.write(disable, 0xffffffff);
        _ = self.read(causes);

        // Link up with the speed the PHY negotiates; no link reset, PHY reset, or loss-of-signal inversion. Then tell any
        // management firmware a driver has the controller.
        self.write(control, (self.read(control) & ~@as(u32, 1 << 3 | 1 << 7 | 1 << 30 | 1 << 31)) | 1 << 5 | 1 << 6);
        self.write(extended, self.read(extended) | 1 << 28);

        const low = self.read(address_low);
        const high = self.read(address_high);

        self.mac = .{ @truncate(low), @truncate(low >> 8), @truncate(low >> 16), @truncate(low >> 24), @truncate(high), @truncate(high >> 8) };
        self.write(address_high, high | 1 << 31);

        for (0..128) |index| self.write(multicast + index * 4, 0);

        const rings = try api.dma();
        const transmits = try api.dma();

        self.receives = @ptrCast(@alignCast(rings.bytes));
        self.transmits = @ptrCast(@alignCast(transmits.bytes));

        for (&self.inbound, &self.outbound) |*inbound, *outbound| {

            inbound.* = try api.dma();
            outbound.* = try api.dma();

        }

        for (self.receives, self.transmits, 0..) |*incoming, *outgoing, index| {

            incoming.* = std.mem.zeroes(Receive);
            incoming.address = self.inbound[index / 2].physical + index % 2 * buffer_size;
            outgoing.* = std.mem.zeroes(Transmit);
            outgoing.address = self.outbound[index / 2].physical + index % 2 * buffer_size;

        }

        self.ring(receive_ring, rings.physical);
        self.write(receive_ring + tail, count - 1);

        self.ring(transmit_ring, transmits.physical);
        // Descriptors written back one at a time, with the bit the 82571 family requires set.
        self.write(transmit_queue, (self.read(transmit_queue) & ~@as(u32, 0x3f0000)) | 0x01410000);
        self.write(transmit_gap, 8 | 8 << 10 | 6 << 20);

        // Enabled, broadcasts accepted, 2 KiB buffers, CRC stripped; transmitting pads short frames, with the standard
        // collision settings and retransmission on late collisions.
        self.write(receive_control, 1 << 1 | 1 << 15 | 1 << 26);
        self.write(transmit_control, 1 << 1 | 1 << 3 | 0xf << 4 | 0x3f << 12 | 1 << 24);

        // At most about 7800 interrupts a second, so a burst of frames arrives as a few batches.
        self.write(throttle, 500);
        self.write(enable, link_changed | running_low | overrun | received);

    }

    /// Link speed in Mb/s, or zero while the link is down.
    pub fn speed(self: *const Nic) u32 {

        const value = self.read(status);
        if (value & 2 == 0) return 0;

        return switch (value >> 6 & 3) {

            0 => 10,
            1 => 100,
            else => 1000,

        };

    }

    /// Reads and clears the interrupt causes; returns whether the link changed.
    pub fn acknowledge(self: *const Nic) bool {

        return self.read(causes) & link_changed != 0;

    }

    /// Passes each frame received intact to `handler`, then hands its buffer back to the device.
    pub fn receive(self: *Nic, context: anytype, comptime handler: fn (@TypeOf(context), []const u8) void) void {

        var last: ?usize = null;

        while (true) {

            const descriptor = &self.receives[self.taken];
            if (@atomicLoad(u8, &descriptor.status, .acquire) & 1 == 0) break;

            // Frames spanning buffers would exceed the MTU, so they are dropped along with any in error.
            if (descriptor.status & 2 != 0 and descriptor.errors == 0 and descriptor.length <= buffer_size) {

                const page = self.inbound[self.taken / 2];

                handler(context, page.bytes[self.taken % 2 * buffer_size ..][0..descriptor.length]);

            }

            descriptor.status = 0;
            last = self.taken;
            self.taken = (self.taken + 1) % count;

        }

        if (last) |index| self.write(receive_ring + tail, @intCast(index));

    }

    /// A transmit buffer to fill, or null while every one waits to be sent.
    pub fn buffer(self: *Nic) ?[]u8 {

        while (self.cleaned != self.filled and @atomicLoad(u8, &self.transmits[self.cleaned].status, .acquire) & 1 != 0) {

            self.cleaned = (self.cleaned + 1) % count;

        }

        if ((self.filled + 1) % count == self.cleaned) return null;

        return self.outbound[self.filled / 2].bytes[self.filled % 2 * buffer_size ..][0..buffer_size];

    }

    /// Sends the first `size` bytes of the buffer `buffer` gave.
    pub fn send(self: *Nic, size: usize) void {

        const descriptor = &self.transmits[self.filled];

        descriptor.length = @intCast(size);

        // End of packet, insert the CRC, and report status.
        descriptor.command = 1 << 0 | 1 << 1 | 1 << 3;
        descriptor.status = 0;
        self.filled = (self.filled + 1) % count;
        self.write(transmit_ring + tail, @intCast(self.filled));

    }

    fn ring(self: *const Nic, offset: usize, physical: u64) void {

        self.write(offset + base_low, @truncate(physical));
        self.write(offset + base_high, @intCast(physical >> 32));
        self.write(offset + length, count * @sizeOf(Receive));
        self.write(offset + head, 0);
        self.write(offset + tail, 0);

    }

    fn until(self: *const Nic, offset: usize, mask: u32, value: u32) !void {

        const deadline = api.ticks() + 50;

        while (self.read(offset) & mask != value) {

            if (api.ticks() >= deadline) return error.Timeout;
            api.sleep(1);

        }

    }

    fn read(self: *const Nic, offset: usize) u32 {

        return @as(*volatile u32, @ptrFromInt(self.registers + offset)).*;

    }

    fn write(self: *const Nic, offset: usize, value: u32) void {

        @as(*volatile u32, @ptrFromInt(self.registers + offset)).* = value;

    }

};
