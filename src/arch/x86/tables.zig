const std = @import("std");

const Descriptor = packed struct {

    limit: u16,
    base: u64,

};

const Gate = extern struct {

    low: u16,
    selector: u16,
    ist: u8,
    flags: u8,
    middle: u16,
    high: u32,
    reserved: u32 = 0,

};

pub const Tss = extern struct {

    reserved0: u32 = 0,

    rsp: [3]u64 align(4) = std.mem.zeroes([3]u64),

    reserved1: u64 align(4) = 0,

    ist: [7]u64 align(4) = std.mem.zeroes([7]u64),

    reserved2: u64 align(4) = 0,
    reserved3: u16 = 0,
    iomap: u16 = 104,

};

pub const Tables = struct {

    gdt: [7]u64 = .{

        0,
        0x00af9a000000ffff,
        0x00cf92000000ffff,
        0x00cff2000000ffff,
        0x00affa000000ffff,
        0,
        0,

    },

    tss: Tss = .{

    },

    pub fn load(self: *Tables, stack: usize, emergency: [3]usize) void {

        self.tss.rsp[0] = stack;
        @memcpy(self.tss.ist[0..3], &emergency);

        const base = @intFromPtr(&self.tss);

        self.gdt[5] = 103 | ((base & 0xffffff) << 16) | (@as(u64, 0x89) << 40) | ((base & 0xff000000) << 32);
        self.gdt[6] = base >> 32;

        const gdtr = Descriptor{

            .limit = @sizeOf(@TypeOf(self.gdt)) - 1,
            .base = @intFromPtr(&self.gdt),

        };

        const idtr = Descriptor{

            .limit = @sizeOf(@TypeOf(idt)) - 1,
            .base = @intFromPtr(&idt),

        };

        load_tables(&gdtr, &idtr);

    }

};

var idt: [256]Gate = undefined;

extern const interrupt_stubs: [256]usize;
extern fn load_tables(gdt: *const Descriptor, idt: *const Descriptor) callconv(.c) void;

pub fn init() void {

    for (&idt, 0..) |*gate, vector| {

        const address = interrupt_stubs[vector];

        gate.* = .{

            .low = @truncate(address),
            .selector = 8,
            .ist = switch (vector) {

                8 => 1,
                2 => 2,
                18 => 3,
                else => 0,

            },
            .flags = if (vector == 128) 0xee else 0x8e,
            .middle = @truncate(address >> 16),
            .high = @truncate(address >> 32),

        };

    }

}

comptime {

    if (@sizeOf(Tss) != 104) @compileError("TSS layout");

}
