const std = @import("std");

const boot = @import("../boot/info.zig");

pub const page_size = 4096;
pub const physical_limit = 0x8000000000;
pub const MemoryError = error{ OutOfMemory, InvalidFrame, DoubleFree, InvalidMap };

pub const Frames = struct {

    bits: []u8,
    count: usize,
    free_count: usize = 0,
    cursor: usize = 0,

    /// Pages the allocator manages, free or not.
    total: usize = 0,

    pub fn storageSize(regions: []const boot.Region) MemoryError!usize {

        var end: u64 = 0;

        for (regions) |region| {

            if (region.kind != .available and region.kind != .firmware) continue;

            const limit = std.math.add(u64, region.base, region.size) catch return error.InvalidMap;

            if (limit > physical_limit) return error.InvalidMap;

            end = @max(end, limit);

        }

        if (end == 0) return error.InvalidMap;

        return std.math.divCeil(usize, @intCast(end / page_size), 4) catch return error.InvalidMap;

    }

    pub fn init(regions: []const boot.Region, storage: []u8, reserved_base: u64, reserved_size: u64) MemoryError!Frames {

        const size = try storageSize(regions);

        if (storage.len < size) return error.InvalidMap;

        @memset(storage[0..size], 0);

        var self = Frames{

            .bits = storage[0..size],
            .count = size * 4,

        };

        for (regions) |region| {

            if (region.kind != .available and region.kind != .firmware) continue;
            if (region.base % page_size != 0 or region.size % page_size != 0) return error.InvalidMap;

            var address = @max(region.base, 0x100000);

            while (address < region.base + region.size) : (address += page_size) {

                if (address >= reserved_base and address - reserved_base < reserved_size) continue;

                const index: usize = @intCast(address / page_size);

                if (self.state(index) != 0) return error.InvalidMap;

                self.set(index, 1);
                self.free_count += 1;

            }

        }

        self.total = self.free_count;

        return self;

    }

    pub fn alloc(self: *Frames) MemoryError!usize {

        if (self.free_count == 0) return error.OutOfMemory;

        var scanned: usize = 0;

        while (scanned < self.count) {

            const index = self.cursor;
            const byte = self.bits[index / 4];
            // Only the two-bit state 01 denotes a free frame.
            const step = if (byte & ~(byte >> 1) & 0x55 == 0) 4 - index % 4 else @as(usize, 1);

            self.cursor = (index + step) % self.count;
            scanned += step;
            if (self.state(index) != 1) continue;

            self.set(index, 2);
            self.free_count -= 1;

            return index * page_size;

        }

        return error.OutOfMemory;

    }

    pub fn release(self: *Frames, address: usize) MemoryError!void {

        if (address % page_size != 0 or address / page_size >= self.count) return error.InvalidFrame;

        const index = address / page_size;

        if (self.state(index) == 1) return error.DoubleFree;
        if (self.state(index) != 2) return error.InvalidFrame;

        self.set(index, 1);
        self.free_count += 1;
        self.cursor = @min(self.cursor, index);

    }

    pub fn allocRun(self: *Frames, pages: usize) MemoryError!usize {

        if (pages == 0 or pages > self.free_count) return error.OutOfMemory;

        var run: usize = 0;

        for (0..self.count) |index| {

            run = if (self.state(index) == 1) run + 1 else 0;
            if (run != pages) continue;

            const first = index + 1 - pages;

            for (first..index + 1) |frame| self.set(frame, 2);
            self.free_count -= pages;

            return first * page_size;

        }

        return error.OutOfMemory;

    }

    fn state(self: *const Frames, index: usize) u2 {

        return @truncate(self.bits[index / 4] >> @as(u3, @intCast((index % 4) * 2)));

    }

    fn set(self: *Frames, index: usize, value: u2) void {

        const shift: u3 = @intCast((index % 4) * 2);

        self.bits[index / 4] = (self.bits[index / 4] & ~(@as(u8, 3) << shift)) | (@as(u8, value) << shift);

    }

};
