const arch = @import("../arch/root.zig");
const root = @import("root.zig");
const process = @import("process.zig");
const Lock = @import("lock.zig").Lock;

const paging = arch.paging;
pub const SharedError = error{ Denied, Invalid, Exhausted, NoProcess };

// 256 MiB bounds a single allocation.
const limit = 0x10000;

const Holder = struct {

    id: u64 = 0,
    address: usize = 0,

};

/// Pages mapped into every holder, wherever they lie physically; freed once the last holder lets go.
const Region = struct {

    next: ?*Region = null,
    handle: u64,
    pages: usize = 0,

    /// Physical page addresses, 512 to a list page.
    lists: [limit / 512]?*[512]usize = [_]?*[512]usize{null} ** (limit / 512),

    holders: [128]Holder = [_]Holder{.{}} ** 128,

    fn frame(self: *const Region, page: usize) usize {

        return self.lists[page / 512].?[page % 512];

    }

};

pub const Mapping = struct {

    handle: u64,
    address: usize,
    pages: usize,

};

// Guards the regions, their holders, and handle numbers.
var lock: Lock = .{};

var regions: ?*Region = null;
var handles: u64 = 0;

pub fn create(task: *process.Process, pages: u64) !Mapping {

    if (pages == 0 or pages > limit) return error.Invalid;

    const region: *Region = @ptrFromInt(try root.frames.alloc());

    region.* = .{

        .handle = 0,

    };

    errdefer destroy(region);

    while (region.pages < pages) : (region.pages += 1) {

        const list = &region.lists[region.pages / 512];
        if (list.* == null) list.* = @ptrFromInt(try root.frames.alloc());

        const physical = try root.frames.alloc();

        @memset(@as(*[4096]u8, @ptrFromInt(physical)), 0);
        list.*.?[region.pages % 512] = physical;

    }

    // Nothing else reaches the region until it is listed, so only listing it takes the lock.
    const address = try map(task, region);

    lock.acquire();
    defer lock.release();

    handles += 1;
    region.handle = handles;
    region.next = regions;
    regions = region;

    return describe(region, address);

}

/// Lets process `target` attach the region; only a current holder may lend it.
pub fn lend(task: *process.Process, handle: u64, target: u64) !void {

    lock.acquire();
    defer lock.release();

    const region = try find(handle);
    if (holder(region, task.id) == null) return error.Denied;

    const borrower = root.processes.find(target) orelse return error.NoProcess;
    try borrower.allow(.region, handle, 1);

}

pub fn attach(task: *process.Process, handle: u64) !Mapping {

    lock.acquire();
    defer lock.release();

    const region = try find(handle);

    if (!task.permits(.region, handle, 1)) return error.Denied;
    if (holder(region, task.id) != null) return error.Invalid;

    return describe(region, try map(task, region));

}

pub fn detach(task: *process.Process, handle: u64) !void {

    lock.acquire();
    defer lock.release();

    const region = try find(handle);
    const slot = holder(region, task.id) orelse return error.Denied;

    // Pages stay owned by the region, so unmapping never frees them.
    for (0..region.pages) |page| task.space.unmap(slot.address + page * 4096) catch {

    };

    slot.* = .{};
    settle(region);

}

/// Drops every hold of a reaped process.
pub fn departed(id: u64) void {

    lock.acquire();
    defer lock.release();

    var current = regions;

    while (current) |region| {

        current = region.next;

        for (&region.holders) |*slot| {

            if (slot.id == id) slot.* = .{};

        }

        settle(region);

    }

}

fn map(task: *process.Process, region: *Region) !usize {

    const slot = holder(region, 0) orelse return error.Exhausted;
    const address = try task.reserve(region.pages);

    for (0..region.pages) |page| {

        task.space.map(address + page * 4096, region.frame(page), paging.user | paging.writable | paging.nx | paging.borrowed) catch |err| {

            for (0..page) |mapped| task.space.unmap(address + mapped * 4096) catch {

            };

            return err;

        };

    }

    task.mapped(address + (region.pages - 1) * 4096);

    slot.* = .{

        .id = task.id,
        .address = address,

    };

    return address;

}

fn describe(region: *const Region, address: usize) Mapping {

    return .{

        .handle = region.handle,
        .address = address,
        .pages = region.pages,

    };

}

fn find(handle: u64) !*Region {

    var current = regions;

    while (current) |region| : (current = region.next) {

        if (region.handle == handle) return region;

    }

    return error.Invalid;

}

fn holder(region: *Region, id: u64) ?*Holder {

    for (&region.holders) |*slot| {

        if (slot.id == id) return slot;

    }

    return null;

}

fn settle(region: *Region) void {

    for (region.holders) |slot| {

        if (slot.id != 0) return;

    }

    var link = &regions;

    while (link.*.? != region) link = &link.*.?.next;

    link.* = region.next;
    destroy(region);

}

fn destroy(region: *Region) void {

    for (0..region.pages) |page| root.frames.release(region.frame(page)) catch @panic("Shared page ownership");

    for (region.lists) |list| {

        if (list) |page| root.frames.release(@intFromPtr(page)) catch @panic("Shared list ownership");

    }

    root.frames.release(@intFromPtr(region)) catch @panic("Shared region ownership");

}

comptime {

    if (@sizeOf(Region) > 4096) @compileError("Shared region exceeds a page");

}
