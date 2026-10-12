const cpu = @import("../../arch/x86/cpu.zig");

pub const Bar = struct {

    base: u64,
    size: u64,
    ports: bool = false,

};

pub const Match = union(enum) {

    /// Class, subclass, and programming interface.
    class: u24,

    /// Vendor in the low half, device in the high half.
    id: u32,

};

/// Finds the first function matching by class code or vendor and device id.
pub fn find(match: Match) ?u32 {

    // ponytail: brute-force scan of every bus; walk bridges if boot time matters.
    for (0..256) |bus| {

        for (0..32) |device| {

            const first = address(bus, device, 0);
            if (read(first, 0) & 0xffff == 0xffff) continue;

            const functions: usize = if (read(first, 0x0c) & 0x800000 != 0) 8 else 1;

            for (0..functions) |function| {

                const at = address(bus, device, function);
                if (read(at, 0) & 0xffff == 0xffff) continue;

                const found = switch (match) {

                    .class => |code| read(at, 8) >> 8 == code,
                    .id => |wanted| read(at, 0) == wanted,

                };

                if (found) return at;

            }

        }

    }

    return null;

}

/// Sizes BAR `index` of function `at`, then enables its decoding and bus mastering.
pub fn bar(at: u32, index: u3) ?Bar {

    const offset = 0x10 + @as(u8, index) * 4;
    const command = read(at, 4) & 0xffff;
    const original = read(at, offset);
    const ports = original & 1 != 0;
    const mask: u32 = if (ports) ~@as(u32, 3) else ~@as(u32, 0xf);

    // A 64-bit memory BAR takes the next register for its upper half, as xHCI controllers' do.
    const wide = !ports and original & 6 == 4;
    const upper: u32 = if (wide and index < 5) read(at, offset + 4) else 0;

    if (!ports and original & 6 != 0 and !wide or wide and index == 5) return null;
    if (original & mask == 0 and upper == 0) return null;

    // Sizing a BAR while it decodes would briefly move the device.
    write(at, 4, command & ~@as(u32, 3));
    write(at, offset, 0xffffffff);
    if (wide) write(at, offset + 4, 0xffffffff);

    const low: u64 = read(at, offset) & mask;
    const high: u64 = if (wide) read(at, offset + 4) else 0xffffffff;
    var size = ~(high << 32 | low) +% 1;

    // I/O BARs may leave their upper half unimplemented.
    if (ports) size &= 0xffff;

    write(at, offset, original);
    if (wide) write(at, offset + 4, upper);
    write(at, 4, command | 0x407);
    if (size == 0) return null;

    return .{

        .base = @as(u64, upper) << 32 | (original & mask),
        .size = size,
        .ports = ports,

    };

}

/// The vendor id of function `at`, with its device id in the upper half.
pub fn id(at: u32) u32 {

    return read(at, 0);

}

fn address(bus: usize, device: usize, function: usize) u32 {

    return @intCast(0x80000000 | bus << 16 | device << 11 | function << 8);

}

fn read(at: u32, offset: u8) u32 {

    cpu.out32(0xcf8, at | offset);

    return cpu.in32(0xcfc);

}

fn write(at: u32, offset: u8, value: u32) void {

    cpu.out32(0xcf8, at | offset);
    cpu.out32(0xcfc, value);

}
