const std = @import("std");

const api = @import("root.zig");

/// Whole pages from the kernel, each allocation its own region; wrap it in an arena for many small objects.
pub const pages = std.mem.Allocator{

    .ptr = undefined,
    .vtable = &.{

        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,

    },

};

// ponytail: a fixed table of live allocations; arenas keep it small, but raise it if an app holds hundreds.
var held: [256]api.Shared = undefined;
var count: usize = 0;

fn alloc(_: *anyopaque, length: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {

    if (alignment.toByteUnits() > 4096 or count == held.len) return null;

    const memory = api.share(std.math.divCeil(usize, @max(length, 1), 4096) catch return null) catch return null;

    held[count] = memory;
    count += 1;

    return memory.bytes.ptr;

}

fn resize(_: *anyopaque, memory: []u8, _: std.mem.Alignment, length: usize, _: usize) bool {

    const index = find(memory.ptr) orelse return false;

    return length <= held[index].bytes.len;

}

fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, length: usize, address: usize) ?[*]u8 {

    return if (resize(context, memory, alignment, length, address)) memory.ptr else null;

}

fn free(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {

    const index = find(memory.ptr) orelse return;

    api.detach(held[index].handle);
    count -= 1;
    held[index] = held[count];

}

fn find(address: [*]u8) ?usize {

    for (held[0..count], 0..) |memory, index| {

        if (memory.bytes.ptr == address) return index;

    }

    return null;

}
