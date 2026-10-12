const std = @import("std");

pub const Header = extern struct {

    ident: [16]u8,
    kind: u16,
    machine: u16,
    version: u32,
    entry: u64,
    phoff: u64,
    shoff: u64,
    flags: u32,
    ehsize: u16,
    phentsize: u16,
    phnum: u16,
    shentsize: u16,
    shnum: u16,
    shstrndx: u16,

};

pub const Segment = extern struct {

    kind: u32,
    flags: u32,
    offset: u64,
    address: u64,
    physical: u64,
    file_size: u64,
    memory_size: u64,
    alignment: u64,

};

pub const LoadError = error{ InvalidElf, InvalidSegment, OverlappingSegments, InvalidEntry };

pub const Image = struct {

    bytes: []const u8,
    header: Header,

    pub fn parse(bytes: []const u8, base: u64, end: u64) LoadError!Image {

        if (bytes.len < @sizeOf(Header)) return error.InvalidElf;

        const header = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);

        if (!std.mem.eql(u8, header.ident[0..7], "\x7fELF\x02\x01\x01")) return error.InvalidElf;
        if (header.kind != 2 or header.machine != 62 or header.version != 1) return error.InvalidElf;
        if (header.ehsize != @sizeOf(Header) or header.phentsize != @sizeOf(Segment) or header.phnum == 0) return error.InvalidElf;
        if (header.phoff > bytes.len or @as(u64, header.phnum) * @sizeOf(Segment) > bytes.len - header.phoff) return error.InvalidElf;

        const self = Image{

            .bytes = bytes,
            .header = header,

        };

        var executable = false;

        for (0..header.phnum) |i| {

            const segment = self.program(i);

            if (segment.kind == 2 or segment.kind == 3) return error.InvalidElf;
            if (segment.kind != 1) continue;
            if (segment.file_size > segment.memory_size) return error.InvalidSegment;
            if (segment.memory_size == 0) continue;

            if (segment.address < base or segment.address >= end or segment.memory_size > end - segment.address) return error.InvalidSegment;
            if (segment.offset > bytes.len or segment.file_size > bytes.len - segment.offset) return error.InvalidSegment;
            if (segment.flags & 3 == 3 or segment.flags & ~@as(u32, 7) != 0) return error.InvalidSegment;
            if (segment.alignment > 1 and (!std.math.isPowerOfTwo(segment.alignment) or segment.address % segment.alignment != segment.offset % segment.alignment)) return error.InvalidSegment;

            for (0..i) |j| {

                const previous = self.program(j);

                if (previous.kind != 1 or previous.memory_size == 0) continue;

                const first = segment.address / 4096;
                const last = (segment.address + segment.memory_size - 1) / 4096;
                const previous_first = previous.address / 4096;
                const previous_last = (previous.address + previous.memory_size - 1) / 4096;

                if (first <= previous_last and previous_first <= last) return error.OverlappingSegments;

            }

            if (segment.flags & 1 != 0 and header.entry >= segment.address and header.entry - segment.address < segment.memory_size) executable = true;

        }

        if (!executable) return error.InvalidEntry;

        return self;

    }

    pub fn program(self: Image, index: usize) Segment {

        const offset = self.header.phoff + index * @sizeOf(Segment);

        return std.mem.bytesToValue(Segment, self.bytes[offset..][0..@sizeOf(Segment)]);

    }

};
