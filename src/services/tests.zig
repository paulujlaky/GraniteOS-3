const std = @import("std");

const policy = @import("policy.zig");
const line = @import("../apps/line.zig");
const protocol = @import("../api/protocol.zig");
const volume = @import("volume.zig");
const gpt = @import("gpt.zig");
const fat = @import("fat.zig");
const gpu = @import("gpu.zig");
const hid = @import("hid.zig");

test "GPU quads cover exactly their pixels and sample texel centres under either pixel-centre convention" {

    for ([_]f32{ 0.5, 0 }) |shift| {

        // A four-by-two area at (3, 5) of a 16 by 8 frame, where pixel n's centre lies at n + 0.5 - shift.
        const left = (gpu.edge(3, 16, shift) + 1) * 8;
        const right = (gpu.edge(7, 16, shift) + 1) * 8;
        const top = (gpu.edge(5, 8, shift) + 1) * 4;
        const bottom = (gpu.edge(7, 8, shift) + 1) * 4;

        try std.testing.expectApproxEqAbs(0.125, (3.5 - shift - left) / (right - left), 1e-5);
        try std.testing.expectApproxEqAbs(0.875, (6.5 - shift - left) / (right - left), 1e-5);
        try std.testing.expectApproxEqAbs(0.25, (5.5 - shift - top) / (bottom - top), 1e-5);
        try std.testing.expect(2.5 - shift < left and 7.5 - shift > right);

    }

    // Texture coordinates run from a slot's near edge, or its far edge when mirrored.
    try std.testing.expectEqual(10.0 / 1024.0, gpu.texel(8, 6, 2, false));
    try std.testing.expectEqual(12.0 / 1024.0, gpu.texel(8, 6, 2, true));

}

test "restart policy backs off and stops after three replacements" {

    var entry = policy.Entry{

    };

    try std.testing.expect(entry.ready(0));

    entry.id = 42;

    try std.testing.expect(!entry.ready(100));
    entry.failed(100);

    try std.testing.expectEqual(0, entry.id);
    try std.testing.expect(!entry.ready(109));
    try std.testing.expect(entry.ready(110));
    entry.failed(110);

    try std.testing.expect(!entry.ready(129));
    try std.testing.expect(entry.ready(130));
    entry.failed(130);

    try std.testing.expect(!entry.ready(169));
    try std.testing.expect(entry.ready(170));
    entry.failed(170);

    try std.testing.expect(entry.offline);
    try std.testing.expect(!entry.ready(std.math.maxInt(u64)));

}

test "terminal editing handles CRLF erase cancel and full input" {

    var input = line.Line{

    };

    try std.testing.expectEqual(.none, input.push(8));
    try std.testing.expectEqual(.echo, input.push('a'));
    try std.testing.expectEqual(.echo, input.push('b'));
    try std.testing.expectEqual(.erase, input.push(127));
    try std.testing.expectEqualStrings("a", input.text());
    try std.testing.expectEqual(.submit, input.push('\r'));
    try std.testing.expectEqual(.none, input.push('\n'));
    input.reset();

    try std.testing.expectEqual(.cancel, input.push(3));
    try std.testing.expectEqual(0, input.len);

    for (0..input.bytes.len) |_| try std.testing.expectEqual(.echo, input.push('x'));

    try std.testing.expectEqual(.bell, input.push('x'));
    try std.testing.expectEqual(256, input.len);
    try std.testing.expectEqual(.erase, input.push(8));
    try std.testing.expectEqual(.echo, input.push('y'));

}

test "terminal editing moves the cursor and recalls history" {

    var input = line.Line{

    };

    for ("echo hed") |byte| _ = input.push(byte);
    for ("\x1b[D") |byte| _ = input.push(byte);

    try std.testing.expectEqual(.redraw, input.push('l'));
    try std.testing.expectEqualStrings("echo held", input.text());

    for ("\x1b[1~") |byte| _ = input.push(byte);
    for ("\x1b[3~") |byte| _ = input.push(byte);

    try std.testing.expectEqualStrings("cho held", input.text());
    try std.testing.expectEqual(.redraw, input.push(5));
    try std.testing.expectEqual(.redraw, input.push(23));
    try std.testing.expectEqualStrings("cho ", input.text());
    try std.testing.expectEqual(.submit, input.push('\r'));
    input.reset();

    for ("id\rid\r") |byte| {

        if (input.push(byte) == .submit) input.reset();

    }

    try std.testing.expectEqual(2, input.total);
    _ = input.push('x');
    try std.testing.expectEqual(.redraw, input.push(16));
    try std.testing.expectEqualStrings("id", input.text());
    try std.testing.expectEqual(.redraw, input.push(16));
    try std.testing.expectEqualStrings("cho ", input.text());
    try std.testing.expectEqual(.bell, input.push(16));
    for ("\x1b[B\x1b[B") |byte| _ = input.push(byte);

    try std.testing.expectEqualStrings("x", input.text());
    try std.testing.expectEqual(.none, input.push(14));

}

test "service protocol preserves operation and payload boundaries" {

    const value = std.math.maxInt(u56);
    const message = protocol.pack(.ping, value);

    try std.testing.expectEqual(.ping, protocol.operation(message));
    try std.testing.expectEqual(value, protocol.value(message));
    try std.testing.expectEqual(@as(protocol.Operation, @enumFromInt(255)), protocol.operation(255));

}

const Memory = struct {

    bytes: []u8,

    pub fn read(self: Memory, lba: u64, out: []u8) volume.Error!void {

        if (lba * 512 + out.len > self.bytes.len) return error.Device;
        @memcpy(out, self.bytes[lba * 512 ..][0..out.len]);

    }

    pub fn write(self: Memory, lba: u64, bytes: []const u8) volume.Error!void {

        if (lba * 512 + bytes.len > self.bytes.len) return error.Device;
        @memcpy(self.bytes[lba * 512 ..][0..bytes.len], bytes);

    }

    pub fn flush(_: Memory) volume.Error!void {

    }

};

test "volume persists fragmented files and directories and reclaims every block" {

    const allocator = std.testing.allocator;

    const disk = Memory{

        .bytes = try allocator.alloc(u8, 8 << 20),

    };

    defer allocator.free(disk.bytes);
    @memset(disk.bytes, 0);

    var sector: [512]u8 = undefined;
    const capacity = disk.bytes.len / 512;

    try std.testing.expectEqual(null, try volume.find(disk, &sector, capacity));
    @memcpy(disk.bytes[512..520], "EFI PART");
    std.mem.writeInt(u64, disk.bytes[512 + 72 ..][0..8], 2, .little);
    std.mem.writeInt(u32, disk.bytes[512 + 80 ..][0..4], 8, .little);
    std.mem.writeInt(u32, disk.bytes[512 + 84 ..][0..4], 128, .little);

    const record = disk.bytes[1024 + 5 * 128 ..][0..128];

    @memcpy(record[0..16], &volume.partition);
    std.mem.writeInt(u64, record[32..40], 64, .little);
    std.mem.writeInt(u64, record[40..48], capacity - 1, .little);

    const range = (try volume.find(disk, &sector, capacity)).?;

    try std.testing.expectEqual(64, range.first);

    const mounted = try allocator.create(volume.Volume(Memory));
    defer allocator.destroy(mounted);

    try std.testing.expect(try mounted.mount(disk, range));
    const initial = mounted.usage();

    try mounted.create("/docs", .directory);
    try mounted.create("/docs/note", .file);
    try mounted.write("/docs/note", 0, "hello");
    try std.testing.expectError(error.Exists, mounted.create("/docs", .directory));
    try std.testing.expectError(error.Invalid, mounted.create("/docs/note/child", .file));
    try std.testing.expectError(error.Missing, mounted.write("/nowhere", 0, "x"));
    try std.testing.expectError(error.Invalid, mounted.create("/docs/..", .file));

    try mounted.create("/a", .file);
    try mounted.create("/b", .file);

    var block: [volume.block_size]u8 = undefined;

    // Interleaving two files defeats contiguous growth, forcing continuation extent pages.
    for (0..600) |index| {

        @memset(&block, @truncate(index));
        try mounted.write("/a", index * block.len, &block);
        @memset(&block, @truncate(index +% 128));
        try mounted.write("/b", index * block.len, &block);

    }

    try mounted.write("/docs/note", 10000, "!");

    const again = try allocator.create(volume.Volume(Memory));
    defer allocator.destroy(again);

    try std.testing.expect(!try again.mount(disk, range));

    var out: [volume.block_size]u8 = undefined;

    try std.testing.expectEqual(out.len, try again.read("/docs/note", 0, &out));
    try std.testing.expectEqualStrings("hello", out[0..5]);
    try std.testing.expect(std.mem.allEqual(u8, out[5..], 0));
    try std.testing.expectEqual(11, try again.read("/docs/note", 9990, &out));
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 10 ++ [_]u8{'!'}), out[0..11]);
    try std.testing.expectEqual(0, try again.read("/docs/note", 10001, &out));

    for ([_]usize{ 0, 253, 254, 255, 598 }) |index| {

        try std.testing.expectEqual(200, try again.read("/a", index * block.len + 4000, out[0..200]));
        try std.testing.expectEqual(@as(u8, @truncate(index)), out[0]);
        try std.testing.expectEqual(@as(u8, @truncate(index + 1)), out[199]);

    }

    try std.testing.expectEqual(10001, (try again.entry("/docs", 0)).?.size);
    try std.testing.expectEqualStrings("b", (try again.entry("/", 2)).?.name);
    try std.testing.expectEqual(null, try again.entry("/", 3));

    try std.testing.expectError(error.Busy, again.remove("/docs"));
    try again.remove("/a");
    try again.create("/b", .file);
    try std.testing.expectEqual(0, try again.read("/b", 0, &out));
    try again.remove("/docs/note");
    try again.remove("/docs");
    try again.remove("/b");
    try std.testing.expectEqual(null, try again.entry("/", 0));
    try std.testing.expectEqual(initial.free, again.usage().free);

}

test "volume enforces owner and other permissions" {

    const allocator = std.testing.allocator;

    const disk = Memory{

        .bytes = try allocator.alloc(u8, 2 << 20),

    };

    defer allocator.free(disk.bytes);
    @memset(disk.bytes, 0);

    const mounted = try allocator.create(volume.Volume(Memory));
    defer allocator.destroy(mounted);

    _ = try mounted.mount(disk, .{

        .first = 0,
        .sectors = disk.bytes.len / 512,

    });

    try mounted.create("/home", .directory);
    try mounted.create("/home/alice", .directory);
    try mounted.change("/home/alice", 0o700, 1000);

    mounted.user = 1000;
    try mounted.create("/home/alice/note", .file);
    try mounted.write("/home/alice/note", 0, "private");
    try std.testing.expectEqual(1000, (try mounted.entry("/home/alice", 0)).?.owner);
    try std.testing.expectError(error.Denied, mounted.create("/home/bob", .directory));
    try std.testing.expectError(error.Denied, mounted.change("/home/alice", 0o755, 1001));

    var out: [16]u8 = undefined;

    mounted.user = 1001;
    try std.testing.expectError(error.Denied, mounted.read("/home/alice/note", 0, &out));
    try std.testing.expectError(error.Denied, mounted.entry("/home/alice", 0));
    try std.testing.expectError(error.Denied, mounted.remove("/home/alice/note"));
    try std.testing.expectError(error.Denied, mounted.change("/home/alice", 0o777, null));

    mounted.user = 1000;
    try mounted.change("/home/alice", 0o755, null);

    mounted.user = 1001;
    try std.testing.expectEqual(7, try mounted.read("/home/alice/note", 0, &out));
    try std.testing.expectError(error.Denied, mounted.write("/home/alice/note", 0, "x"));
    try std.testing.expectError(error.Denied, mounted.create("/home/alice/note", .file));
    try std.testing.expectError(error.Denied, mounted.create("/home/alice/other", .file));

    mounted.user = volume.system;
    try mounted.remove("/home/alice/note");

}

test "GPT edit fills the largest aligned gap and keeps both tables valid" {

    const allocator = std.testing.allocator;
    const sectors = 65536;

    const disk = Memory{

        .bytes = try allocator.alloc(u8, sectors * 512),

    };

    defer allocator.free(disk.bytes);
    @memset(disk.bytes, 0);

    const header = disk.bytes[512..1024];
    const entries = disk.bytes[1024..][0 .. 128 * 128];

    @memcpy(header[0..8], "EFI PART");
    std.mem.writeInt(u32, header[12..16], 92, .little);
    std.mem.writeInt(u64, header[24..32], 1, .little);
    std.mem.writeInt(u64, header[32..40], sectors - 1, .little);
    std.mem.writeInt(u64, header[40..48], 34, .little);
    std.mem.writeInt(u64, header[48..56], sectors - 34, .little);
    std.mem.writeInt(u64, header[72..80], 2, .little);
    std.mem.writeInt(u32, header[80..84], 128, .little);
    std.mem.writeInt(u32, header[84..88], 128, .little);

    for ([_][3]u64{ .{ 0, 2048, 4095 }, .{ 1, 4096, 20479 }, .{ 2, 40960, 49151 } }) |part| {

        const entry = entries[part[0] * 128 ..][0..128];

        entry[0..16].* = if (part[0] == 0) gpt.esp else [_]u8{0xaa} ** 16;
        std.mem.writeInt(u64, entry[32..40], part[1], .little);
        std.mem.writeInt(u64, entry[40..48], part[2], .little);

    }

    std.mem.writeInt(u32, header[88..92], std.hash.Crc32.hash(entries), .little);
    std.mem.writeInt(u32, header[16..20], std.hash.Crc32.hash(header[0..92]), .little);
    @memset(disk.bytes[4096 * 512 .. 20480 * 512], 0x5a);

    const table = try allocator.create(gpt.Table);
    defer allocator.destroy(table);

    try std.testing.expect(try table.read(disk, sectors));
    try std.testing.expectEqual(2048, table.find(gpt.esp).?.first);

    const free = table.gap();

    try std.testing.expectEqual(20480, free.first);
    try std.testing.expectEqual(20480, free.sectors);
    try table.add(disk, volume.partition, [_]u8{1} ** 16, free, "GraniteOS Data");

    try std.testing.expect(try table.read(disk, sectors));
    try std.testing.expectEqual(4, table.find(volume.partition).?.number);
    try std.testing.expectEqual(40959, table.find(volume.partition).?.last);
    try std.testing.expect(std.mem.allEqual(u8, disk.bytes[4096 * 512 .. 20480 * 512], 0x5a));

    var backup = disk.bytes[(sectors - 1) * 512 ..][0..512].*;
    const checksum = std.mem.readInt(u32, backup[16..20], .little);

    try std.testing.expectEqual(1, std.mem.readInt(u64, backup[32..40], .little));
    try std.testing.expectEqual(sectors - 33, std.mem.readInt(u64, backup[72..80], .little));
    try std.testing.expectEqualSlices(u8, entries, disk.bytes[(sectors - 33) * 512 ..][0 .. 128 * 128]);
    @memset(backup[16..20], 0);
    try std.testing.expectEqual(checksum, std.hash.Crc32.hash(backup[0..92]));

    header[40] ^= 1;
    try std.testing.expect(!try table.read(disk, sectors));

}

test "FAT32 writer fills only free clusters and survives fragmentation and rewrites" {

    const allocator = std.testing.allocator;
    const base = 64;
    const total = 4096;

    const disk = Memory{

        .bytes = try allocator.alloc(u8, (base + total) * 512),

    };

    defer allocator.free(disk.bytes);
    @memset(disk.bytes, 0);

    const boot = disk.bytes[base * 512 ..][0..512];
    const info = disk.bytes[(base + 1) * 512 ..][0..512];

    std.mem.writeInt(u16, boot[11..13], 512, .little);
    boot[13] = 1;
    std.mem.writeInt(u16, boot[14..16], 32, .little);
    boot[16] = 2;
    std.mem.writeInt(u32, boot[32..36], total, .little);
    std.mem.writeInt(u32, boot[36..40], 32, .little);
    std.mem.writeInt(u32, boot[44..48], 2, .little);
    std.mem.writeInt(u16, boot[48..50], 1, .little);
    boot[510] = 0x55;
    boot[511] = 0xaa;
    std.mem.writeInt(u32, info[0..4], 0x41615252, .little);
    std.mem.writeInt(u32, info[484..488], 0x61417272, .little);
    std.mem.writeInt(u32, info[488..492], 1234, .little);

    // Clusters 0-4 are reserved, root, and an existing two-cluster file; every third from 30 is taken.
    for (0..2) |copy| {

        const table = disk.bytes[(base + 32 + copy * 32) * 512 ..][0..512];

        for ([_]u32{ 0x0ffffff8, 0x0fffffff, 0x0fffffff, 4, 0x0fffffff }, 0..) |value, index| std.mem.writeInt(u32, table[index * 4 ..][0..4], value, .little);

        var cluster: usize = 30;

        while (cluster < 90) : (cluster += 3) std.mem.writeInt(u32, table[cluster * 4 ..][0..4], 0x0fffffff, .little);

    }

    @memset(disk.bytes[(base + 97) * 512 ..][0 .. 2 * 512], 0x77);

    const esp = try allocator.create(fat.Fat(Memory));
    defer allocator.destroy(esp);

    try std.testing.expect(try esp.mount(disk, base));

    const efi = try esp.directory(esp.root, "EFI        ");

    try std.testing.expectEqual(efi, try esp.directory(esp.root, "EFI        "));

    const home = try esp.directory(efi, "GRANITE    ");

    // Twenty more entries overflow the one-cluster root directory.
    for (0..20) |index| {

        var name = "DIR00      ".*;

        name[3] = '0' + @as(u8, @intCast(index / 10));
        name[4] = '0' + @as(u8, @intCast(index % 10));
        _ = try esp.directory(esp.root, &name);

    }

    var data: [9000]u8 = undefined;
    var out: [9000]u8 = undefined;

    for (&data, 0..) |*byte, index| byte.* = @truncate(index * 7 + index / 251);

    try esp.write(home, "BOOTX64 EFI", &data);
    try std.testing.expectEqualSlices(u8, &data, out[0..try fatFile(disk.bytes, base, home, "BOOTX64 EFI", &out)]);
    try esp.write(home, "BOOTX64 EFI", data[0..700]);
    try std.testing.expectEqualSlices(u8, data[0..700], out[0..try fatFile(disk.bytes, base, home, "BOOTX64 EFI", &out)]);
    try std.testing.expectEqual(0, try fatFile(disk.bytes, base, esp.root, "DIR19      ", &out));

    try std.testing.expect(std.mem.allEqual(u8, disk.bytes[(base + 97) * 512 ..][0 .. 2 * 512], 0x77));
    try std.testing.expectEqualSlices(u8, disk.bytes[(base + 32) * 512 ..][0 .. 32 * 512], disk.bytes[(base + 64) * 512 ..][0 .. 32 * 512]);
    try std.testing.expectEqual(0xffffffff, std.mem.readInt(u32, info[488..492], .little));

}

/// Reads `name` from a test volume with one-sector clusters, its FAT at sector 32 and data at 96.
fn fatFile(bytes: []const u8, base: usize, directory: u32, name: []const u8, out: []u8) !usize {

    const table = bytes[(base + 32) * 512 ..];
    var cluster = directory;

    while (cluster < 0x0ffffff8) : (cluster = std.mem.readInt(u32, table[cluster * 4 ..][0..4], .little) & 0x0fffffff) {

        const sector = bytes[(base + 96 + cluster - 2) * 512 ..][0..512];

        for (0..16) |index| {

            const entry = sector[index * 32 ..][0..32];
            if (!std.mem.eql(u8, entry[0..11], name)) continue;

            var file = @as(u32, std.mem.readInt(u16, entry[20..22], .little)) << 16 | std.mem.readInt(u16, entry[26..28], .little);
            const size = std.mem.readInt(u32, entry[28..32], .little);
            var done: usize = 0;

            while (done < size) : (file = std.mem.readInt(u32, table[file * 4 ..][0..4], .little) & 0x0fffffff) {

                const count = @min(512, size - done);

                @memcpy(out[done..][0..count], bytes[(base + 96 + file - 2) * 512 ..][0..count]);
                done += count;

            }

            return size;

        }

    }

    return error.Missing;

}

test "HID descriptors find boot keyboards and pointer reports, and keys translate to set-1 scancodes" {

    // VMware's virtual USB mouse: sixteen buttons, absolute X and Y, then a wheel and a pan.
    const descriptor = [_]u8{ 0x05, 0x01, 0x09, 0x02, 0xa1, 0x01, 0x09, 0x01, 0xa1, 0x00, 0x05, 0x09, 0x19, 0x01, 0x29, 0x10, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x10, 0x81, 0x02, 0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x00, 0x27, 0xff, 0x7f, 0x00, 0x00, 0x75, 0x10, 0x95, 0x02, 0x81, 0x02, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06, 0x05, 0x0c, 0x0a, 0x38, 0x02, 0x81, 0x06, 0xc0, 0xc0 };
    const shape = hid.layout(&descriptor) orelse return error.TestUnexpectedResult;

    // Right button held, at the middle of the screen, one wheel step towards the user.
    const report = [_]u8{ 0x02, 0x00, 0xff, 0x3f, 0xff, 0x3f, 0xff, 0x00 };

    try std.testing.expectEqual(2, shape.buttons.read(&report));
    try std.testing.expectEqual(0x3fff, shape.x.read(&report));
    try std.testing.expectEqual(0x3fff, shape.y.read(&report));
    try std.testing.expectEqual(-1, shape.wheel.read(&report));
    try std.testing.expect(!shape.x.relative and shape.wheel.relative);

    // A configuration with one boot keyboard interface and its interrupt-in endpoint.
    const configuration = [_]u8{ 9, 2, 34, 0, 1, 1, 0, 0xa0, 50, 9, 4, 0, 0, 1, 3, 1, 1, 0, 9, 0x21, 0x11, 0x01, 0, 1, 0x22, 63, 0, 7, 5, 0x81, 3, 8, 0, 10 };
    const found = hid.find(&configuration) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(.keyboard, found.kind);
    try std.testing.expectEqual(0x81, found.endpoint);
    try std.testing.expectEqual(63, found.report);
    try std.testing.expectEqual(0x1e, hid.translate(0x04));
    try std.testing.expectEqual(0x148, hid.translate(0x52));

}
