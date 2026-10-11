const std = @import("std");

pub const Error = error{ Invalid, Unsupported, OutOfMemory };

pub const Size = struct {

    width: u32,
    height: u32,

};

const signature = "\x89PNG\r\n\x1a\n";

// Caps both sides, so no byte count below comes near overflowing.
const limit = 16384;

/// Adam7's passes, each as its first column and row and its spacing across and down.
const adam7 = [7][4]u32{ .{ 0, 0, 8, 8 }, .{ 4, 0, 8, 8 }, .{ 0, 4, 4, 8 }, .{ 2, 0, 4, 4 }, .{ 0, 2, 2, 4 }, .{ 1, 0, 2, 2 }, .{ 0, 1, 1, 2 } };

/// The one pass of an image that is not interlaced.
const whole = [1][4]u32{.{ 0, 0, 1, 1 }};

const Chunk = struct {

    kind: *const [4]u8,
    body: []const u8,

};

/// What the chunks before the pixel data say about an image.
const Image = struct {

    width: u32,
    height: u32,
    depth: u5,
    color: u8,
    channels: u8,
    interlaced: bool,

    /// Premultiplied colours of an indexed image.
    palette: [256]u32 = @splat(0),
    entries: usize = 0,

    /// Samples of the one colour tRNS makes transparent in a grey or truecolour image.
    key: ?[3]u16 = null,

    /// Converts pixel `x` of an unfiltered scanline to premultiplied 0xAARRGGBB.
    fn pixel(self: *const Image, line: []const u8, x: usize) Error!u32 {

        var values = [4]u16{ 0, 0, 0, 0 };
        var levels: [4]u32 = undefined;

        for (0..self.channels) |channel| {

            values[channel] = sample(line, x * self.channels + channel, self.depth);
            levels[channel] = level(values[channel], self.depth);

        }

        const keyed = if (self.key) |key| std.mem.eql(u16, values[0..3], &key) else false;
        const alpha: u32 = if (keyed) 0 else 255;

        return switch (self.color) {

            0 => premultiply(alpha, levels[0], levels[0], levels[0]),
            2 => premultiply(alpha, levels[0], levels[1], levels[2]),
            3 => if (values[0] < self.entries) self.palette[values[0]] else error.Invalid,
            4 => premultiply(levels[1], levels[0], levels[0], levels[0]),
            else => premultiply(levels[3], levels[0], levels[1], levels[2]),

        };

    }

};

/// Reads the image size from the header without decoding.
pub fn size(bytes: []const u8) Error!Size {

    const image = try header(bytes);

    return .{

        .width = image.width,
        .height = image.height,

    };

}

/// Decodes `bytes` into `pixels` (at least width * height entries, row after row) as premultiplied 0xAARRGGBB; `allocator` only holds scratch space.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, pixels: []u32) Error!Size {

    var image = try header(bytes);

    if (pixels.len < @as(usize, image.width) * image.height) return error.Invalid;

    var stream: std.ArrayList(u8) = .empty;
    var palette: []const u8 = &.{};
    var transparency: []const u8 = &.{};
    var position: usize = signature.len;

    defer stream.deinit(allocator);

    // Steps over the IHDR `header` already read.
    _ = try next(bytes, &position);

    while (true) {

        const chunk = try next(bytes, &position);

        if (std.mem.eql(u8, chunk.kind, "IEND")) break;

        if (std.mem.eql(u8, chunk.kind, "IDAT")) {

            try stream.appendSlice(allocator, chunk.body);

        } else if (std.mem.eql(u8, chunk.kind, "PLTE")) {

            if (chunk.body.len == 0 or chunk.body.len > 768 or chunk.body.len % 3 != 0) return error.Invalid;
            palette = chunk.body;

        } else if (std.mem.eql(u8, chunk.kind, "tRNS")) {

            transparency = chunk.body;

        } else if (std.mem.eql(u8, chunk.kind, "IHDR")) {

            return error.Invalid;

        } else if (chunk.kind[0] & 0x20 == 0) {

            // An unknown critical chunk may change what the rest means, so the spec forbids guessing.
            return error.Unsupported;

        }

    }

    if (image.color == 3) {

        if (palette.len == 0 or transparency.len > palette.len / 3) return error.Invalid;

        image.entries = palette.len / 3;

        for (0..image.entries) |index| {

            const color = palette[index * 3 ..][0..3];
            const alpha: u32 = if (index < transparency.len) transparency[index] else 255;

            image.palette[index] = premultiply(alpha, color[0], color[1], color[2]);

        }

    } else if (transparency.len > 0 and (image.color == 0 or image.color == 2)) {

        var key = [3]u16{ 0, 0, 0 };

        if (transparency.len != image.channels * 2) return error.Invalid;

        for (0..image.channels) |channel| key[channel] = std.mem.readInt(u16, transparency[channel * 2 ..][0..2], .big);
        image.key = key;

    }

    const passes: []const [4]u32 = if (image.interlaced) &adam7 else &whole;
    var total: usize = 0;

    for (passes) |pass| {

        _, const rows, const stride = grid(&image, pass);

        total += rows * stride;

    }

    const data = try allocator.alloc(u8, total);
    var offset: usize = 0;

    defer allocator.free(data);
    try inflate(stream.items, data);

    for (passes) |pass| {

        const column, const row, const across, const down = pass;
        const columns, const rows, const stride = grid(&image, pass);
        const lines = data[offset..][0 .. rows * stride];

        offset += lines.len;
        try unfilter(lines, stride, @max(1, image.channels * image.depth / 8));

        for (0..rows) |y| {

            const line = lines[y * stride + 1 ..][0 .. stride - 1];

            for (0..columns) |x| pixels[(row + y * down) * image.width + column + x * across] = try image.pixel(line, x);

        }

    }

    return .{

        .width = image.width,
        .height = image.height,

    };

}

/// Encodes opaque 0x00RRGGBB `pixels` as an 8-bit RGB PNG the caller frees.
pub fn encode(allocator: std.mem.Allocator, pixels: []const u32, width: u32, height: u32) Error![]u8 {

    if (width == 0 or height == 0 or pixels.len < @as(usize, width) * height) return error.Invalid;
    if (width > limit or height > limit) return error.Unsupported;

    const stride = 1 + @as(usize, width) * 3;
    const scanlines = try allocator.alloc(u8, stride * height);

    defer allocator.free(scanlines);

    for (0..height) |y| {

        const line = scanlines[y * stride ..][0..stride];

        line[0] = 0;

        for (pixels[y * width ..][0..width], 0..) |color, x| line[1 + x * 3 ..][0..3].* = .{ @truncate(color >> 16), @truncate(color >> 8), @truncate(color) };

    }

    const length = stored(scanlines.len);
    const bytes = try allocator.alloc(u8, signature.len + 25 + 12 + length + 12);

    // IHDR's data after its length and type: size, 8-bit truecolour, standard compression and filtering, not interlaced.
    @memcpy(bytes[0..signature.len], signature);
    std.mem.writeInt(u32, bytes[16..20], width, .big);
    std.mem.writeInt(u32, bytes[20..24], height, .big);
    bytes[24..29].* = .{ 8, 2, 0, 0, 0 };

    var position = seal(bytes, signature.len, "IHDR", 13);

    store(bytes[position + 8 ..][0..length], scanlines);
    position = seal(bytes, position, "IDAT", length);
    _ = seal(bytes, position, "IEND", 0);

    return bytes;

}

/// Checks the signature and the IHDR chunk every PNG opens with.
fn header(bytes: []const u8) Error!Image {

    if (bytes.len < signature.len or !std.mem.eql(u8, bytes[0..signature.len], signature)) return error.Invalid;

    var position: usize = signature.len;
    const chunk = try next(bytes, &position);

    if (!std.mem.eql(u8, chunk.kind, "IHDR") or chunk.body.len != 13) return error.Invalid;

    const body = chunk.body;
    const width = std.mem.readInt(u32, body[0..4], .big);
    const height = std.mem.readInt(u32, body[4..8], .big);
    const depth = body[8];
    const color = body[9];
    const power = depth > 0 and depth <= 16 and depth & (depth - 1) == 0;
    const valid = power and switch (color) {

        0 => true,
        3 => depth <= 8,
        2, 4, 6 => depth >= 8,
        else => false,

    };

    if (width == 0 or height == 0 or !valid or body[10] != 0 or body[11] != 0 or body[12] > 1) return error.Invalid;
    if (width > limit or height > limit) return error.Unsupported;

    return .{

        .width = width,
        .height = height,
        .depth = @intCast(depth),
        .color = color,
        .channels = switch (color) {

            0, 3 => 1,
            4 => 2,
            2 => 3,
            else => 4,

        },
        .interlaced = body[12] == 1,

    };

}

/// Reads the chunk at `position`, checking its bounds and CRC, and moves `position` past it.
fn next(bytes: []const u8, position: *usize) Error!Chunk {

    const start = position.*;

    if (bytes.len - start < 12) return error.Invalid;

    const length = std.mem.readInt(u32, bytes[start..][0..4], .big);

    if (length > bytes.len - start - 12) return error.Invalid;

    const end = start + 8 + length;

    if (std.hash.Crc32.hash(bytes[start + 4 .. end]) != std.mem.readInt(u32, bytes[end..][0..4], .big)) return error.Invalid;

    position.* = end + 4;

    return .{

        .kind = bytes[start + 4 ..][0..4],
        .body = bytes[start + 8 .. end],

    };

}

/// The columns and rows `pass` covers and the bytes in each of its scanlines, filter byte included; an empty pass has no rows.
fn grid(image: *const Image, pass: [4]u32) [3]usize {

    const column, const row, const across, const down = pass;
    const columns = if (image.width > column) (image.width - column + across - 1) / across else 0;
    const rows = if (columns > 0 and image.height > row) (image.height - row + down - 1) / down else 0;

    return .{ columns, rows, 1 + (columns * image.channels * image.depth + 7) / 8 };

}

/// Inflates zlib `stream` so it exactly fills `output`, also checking the header and Adler-32 that std leaves unchecked.
fn inflate(stream: []const u8, output: []u8) Error!void {

    if (stream.len < 2 or std.mem.readInt(u16, stream[0..2], .big) % 31 != 0 or stream[1] & 0x20 != 0) return error.Invalid;

    var input = std.Io.Reader.fixed(stream);
    var writer = std.Io.Writer.fixed(output);
    var decompress = std.compress.flate.Decompress.init(&input, .zlib, &.{});
    const length = decompress.reader.streamRemaining(&writer) catch return error.Invalid;

    // std reads the footer but never checks it (and stores it byte-swapped), so this takes it from the stream.
    if (length != output.len or std.mem.readInt(u32, stream[input.seek - 4 ..][0..4], .big) != std.hash.Adler32.hash(output)) return error.Invalid;

}

/// Undoes each scanline's filter in place; `lines` holds rows of `stride` bytes, filter byte first, and `unit` is the bytes per pixel, at least one.
fn unfilter(lines: []u8, stride: usize, unit: usize) Error!void {

    for (0..lines.len / stride) |y| {

        const filter = lines[y * stride];

        if (filter > 4) return error.Invalid;

        for (1..stride) |x| {

            const index = y * stride + x;
            const left = if (x > unit) lines[index - unit] else 0;
            const up = if (y > 0) lines[index - stride] else 0;
            const corner = if (x > unit and y > 0) lines[index - stride - unit] else 0;

            lines[index] +%= predict(filter, left, up, corner);

        }

    }

}

/// What `filter` predicts a byte to be from its already reconstructed neighbours.
fn predict(filter: u8, left: u8, up: u8, corner: u8) u8 {

    switch (filter) {

        1 => return left,
        2 => return up,
        3 => return @intCast((@as(u9, left) + up) / 2),
        4 => {

            const guess = @as(i16, left) + up - corner;
            const distances = [3]u16{ @abs(guess - left), @abs(guess - up), @abs(guess - corner) };

            if (distances[0] <= distances[1] and distances[0] <= distances[2]) return left;

            return if (distances[1] <= distances[2]) up else corner;

        },
        else => return 0,

    }

}

/// Reads sample `index` from a scanline packed at `depth` bits per sample.
fn sample(line: []const u8, index: usize, depth: u5) u16 {

    if (depth == 16) return std.mem.readInt(u16, line[index * 2 ..][0..2], .big);

    const bit = index * depth;
    const shift: u3 = @intCast(8 - depth - bit % 8);
    const mask = (@as(u16, 1) << @intCast(depth)) - 1;

    return line[bit / 8] >> shift & mask;

}

/// Brings a sample of `depth` bits to eight: 16-bit samples keep their high byte, smaller ones scale up.
fn level(value: u16, depth: u5) u32 {

    if (depth == 16) return value >> 8;

    return @as(u32, value) * 255 / ((@as(u32, 1) << depth) - 1);

}

/// Packs 0xAARRGGBB with red, green, and blue scaled by alpha and rounded.
fn premultiply(alpha: u32, red: u32, green: u32, blue: u32) u32 {

    return alpha << 24 | (red * alpha + 127) / 255 << 16 | (green * alpha + 127) / 255 << 8 | (blue * alpha + 127) / 255;

}

/// Bytes in a zlib stream holding `length` bytes in stored blocks.
fn stored(length: usize) usize {

    return 2 + (length + 0xfffe) / 0xffff * 5 + length + 4;

}

/// Fills `stream` with `data` as a zlib stream of stored blocks.
fn store(stream: []u8, data: []const u8) void {

    var position: usize = 2;
    var start: usize = 0;

    stream[0..2].* = .{ 0x78, 0x01 };

    while (start < data.len) {

        const length: u16 = @intCast(@min(data.len - start, 0xffff));

        stream[position] = @intFromBool(start + length == data.len);
        std.mem.writeInt(u16, stream[position + 1 ..][0..2], length, .little);
        std.mem.writeInt(u16, stream[position + 3 ..][0..2], ~length, .little);
        @memcpy(stream[position + 5 ..][0..length], data[start..][0..length]);
        position += 5 + @as(usize, length);
        start += length;

    }

    std.mem.writeInt(u32, stream[position..][0..4], std.hash.Adler32.hash(data), .big);

}

/// Fills in the length, type, and CRC around `length` bytes of data already at `bytes[position + 8 ..]`; returns where the next chunk starts.
fn seal(bytes: []u8, position: usize, kind: *const [4]u8, length: usize) usize {

    const end = position + 8 + length;

    std.mem.writeInt(u32, bytes[position..][0..4], @intCast(length), .big);
    bytes[position + 4 ..][0..4].* = kind.*;
    std.mem.writeInt(u32, bytes[end..][0..4], std.hash.Crc32.hash(bytes[position + 4 .. end]), .big);

    return end + 4;

}

/// Builds a PNG from IHDR `fields` (width, height, depth, colour, interlace), `chunks`, and zlib `stream` split over two IDAT chunks.
fn fixture(allocator: std.mem.Allocator, fields: [5]u32, chunks: []const Chunk, stream: []const u8) ![]u8 {

    var bytes: std.ArrayList(u8) = .empty;
    var body: [13]u8 = @splat(0);

    std.mem.writeInt(u32, body[0..4], fields[0], .big);
    std.mem.writeInt(u32, body[4..8], fields[1], .big);
    body[8] = @intCast(fields[2]);
    body[9] = @intCast(fields[3]);
    body[12] = @intCast(fields[4]);
    try bytes.appendSlice(allocator, signature);
    try append(allocator, &bytes, "IHDR", &body);

    for (chunks) |chunk| try append(allocator, &bytes, chunk.kind, chunk.body);

    try append(allocator, &bytes, "IDAT", stream[0 .. stream.len / 2]);
    try append(allocator, &bytes, "IDAT", stream[stream.len / 2 ..]);
    try append(allocator, &bytes, "IEND", "");

    return bytes.items;

}

fn append(allocator: std.mem.Allocator, bytes: *std.ArrayList(u8), kind: *const [4]u8, body: []const u8) !void {

    const position = bytes.items.len;

    @memcpy((try bytes.addManyAsSlice(allocator, 12 + body.len))[8..][0..body.len], body);
    _ = seal(bytes.items, position, kind, body.len);

}

/// Appends `rows` of `stride` bytes to `scanlines`, filtering each with the next of the five filter types from `first`.
fn filtered(allocator: std.mem.Allocator, scanlines: *std.ArrayList(u8), rows: []const u8, stride: usize, unit: usize, first: usize) !void {

    for (0..rows.len / stride) |y| {

        const filter: u8 = @intCast((first + y) % 5);

        try scanlines.append(allocator, filter);

        for (0..stride) |x| {

            const index = y * stride + x;
            const left = if (x >= unit) rows[index - unit] else 0;
            const up = if (y > 0) rows[index - stride] else 0;
            const corner = if (x >= unit and y > 0) rows[index - stride - unit] else 0;

            try scanlines.append(allocator, rows[index] -% predict(filter, left, up, corner));

        }

    }

}

/// Wraps `scanlines` in a zlib stream of stored blocks.
fn deflate(allocator: std.mem.Allocator, scanlines: []const u8) ![]u8 {

    const stream = try allocator.alloc(u8, stored(scanlines.len));

    store(stream, scanlines);

    return stream;

}

/// zlib.compress at level 6, one dynamic Huffman block, of 3 x 5 16-bit RGBA pixels filtered with types 0 to 4 row by row:
/// red x * 0x5000 + y * 0x123, green y * 0x3000 + 0xff, blue (x + y) * 0x1111, alpha 0xffff but 0x80ff at (1, 2) and 0 at (2, 4).
const huffman = "789c3dccb10d80301043d17f81058e8afa52d165042a6a466094b0099b1a290954cfb2640308a413e42e3da008c92c97569c803b7c26cba585ee3d84291d578da8755b56dc77ba30ff8b71d1357b011d4314e6";

test "png round trips encoded pixels through several stored blocks" {

    const allocator = std.testing.allocator;
    const width = 200;
    const height = 150;
    const pixels = try allocator.alloc(u32, width * height);
    const decoded = try allocator.alloc(u32, width * height);

    defer allocator.free(pixels);
    defer allocator.free(decoded);

    for (pixels, 0..) |*pixel, index| pixel.* = @as(u32, @truncate(index)) *% 0x9e3779b1 >> 8;

    const bytes = try encode(allocator, pixels, width, height);

    defer allocator.free(bytes);

    try std.testing.expectEqual(Size{ .width = width, .height = height }, try size(bytes));
    try std.testing.expectEqual(Size{ .width = width, .height = height }, try decode(allocator, bytes, decoded));

    for (pixels, decoded) |pixel, result| try std.testing.expectEqual(pixel | 0xff000000, result);

}

test "png decodes a 2-bit palette image with tRNS alpha" {

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();

    const allocator = arena.allocator();
    const colors = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255 };
    var scanlines: std.ArrayList(u8) = .empty;
    var pixels: [10]u32 = undefined;

    // Indices 0 1 2 3 1 and 3 2 1 0 0, four to a byte.
    try filtered(allocator, &scanlines, &.{ 0x1b, 0x40, 0xe4, 0x00 }, 2, 1, 0);

    const stream = try deflate(allocator, scanlines.items);
    const bytes = try fixture(allocator, .{ 5, 2, 2, 3, 0 }, &.{

        .{ .kind = "PLTE", .body = &colors },
        .{ .kind = "tRNS", .body = &.{ 0, 128 } },

    }, stream);

    _ = try decode(allocator, bytes, &pixels);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0x80008000, 0xff0000ff, 0xffffffff, 0x80008000, 0xffffffff, 0xff0000ff, 0x80008000, 0, 0 }, &pixels);

    const short = try fixture(allocator, .{ 5, 2, 2, 3, 0 }, &.{.{ .kind = "PLTE", .body = colors[0..9] }}, stream);

    try std.testing.expectError(error.Invalid, decode(allocator, short, &pixels));

}

test "png decodes 16-bit RGBA from a dynamic Huffman stream through all five filters" {

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();

    const allocator = arena.allocator();
    var stream: [huffman.len / 2]u8 = undefined;
    var pixels: [15]u32 = undefined;

    _ = try std.fmt.hexToBytes(&stream, huffman);
    _ = try decode(allocator, try fixture(allocator, .{ 3, 5, 16, 6, 0 }, &.{}, &stream), &pixels);

    for (pixels, 0..) |pixel, index| {

        const x: u32 = @intCast(index % 3);
        const y: u32 = @intCast(index / 3);
        const solid = 0xff000000 | (x * 0x5000 + y * 0x123) >> 8 << 16 | (y * 0x3000 + 0xff) >> 8 << 8 | (x + y) * 0x1111 >> 8;
        const expected: u32 = if (x == 1 and y == 2) 0x8029301a else if (x == 2 and y == 4) 0 else solid;

        try std.testing.expectEqual(expected, pixel);

    }

}

test "png decodes 1-bit greyscale with padding and a tRNS grey" {

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();

    const allocator = arena.allocator();
    var scanlines: std.ArrayList(u8) = .empty;
    var pixels: [20]u32 = undefined;

    // 1010110011 and 0000011111, padded with set bits the decoder must ignore.
    try filtered(allocator, &scanlines, &.{ 0xac, 0xff, 0x07, 0xff }, 2, 1, 3);

    const stream = try deflate(allocator, scanlines.items);
    const gamma = Chunk{

        .kind = "gAMA",
        .body = &.{ 0, 0, 0xb1, 0x8f },

    };

    _ = try decode(allocator, try fixture(allocator, .{ 10, 2, 1, 0, 0 }, &.{gamma}, stream), &pixels);

    for (pixels, "1010110011" ++ "0000011111") |pixel, bit| try std.testing.expectEqual(@as(u32, if (bit == '1') 0xffffffff else 0xff000000), pixel);

    _ = try decode(allocator, try fixture(allocator, .{ 10, 2, 1, 0, 0 }, &.{.{ .kind = "tRNS", .body = &.{ 0, 0 } }}, stream), &pixels);

    for (pixels, "1010110011" ++ "0000011111") |pixel, bit| try std.testing.expectEqual(@as(u32, if (bit == '1') 0xffffffff else 0), pixel);

}

test "png decodes Adam7 interlaced truecolour with a tRNS colour" {

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();

    const allocator = arena.allocator();

    // Which pass each pixel of an 8 x 8 tile belongs to, as the spec draws it.
    const pattern = "16462646" ++ "77777777" ++ "56565656" ++ "77777777" ++ "36463646" ++ "77777777" ++ "56565656" ++ "77777777";

    for ([_][2]u32{ .{ 9, 7 }, .{ 5, 3 }, .{ 1, 1 } }) |dimensions| {

        const width, const height = dimensions;
        var scanlines: std.ArrayList(u8) = .empty;
        var pixels: [63]u32 = undefined;

        for ('1'..'8') |pass| {

            var rows: std.ArrayList(u8) = .empty;
            var columns: usize = 0;

            for (0..height) |y| {

                var found: usize = 0;

                for (0..width) |x| {

                    if (pattern[y % 8 * 8 + x % 8] != pass) continue;

                    try rows.appendSlice(allocator, &.{ @intCast(x * 20), @intCast(y * 30), 7 });
                    found += 1;

                }

                if (found > 0) columns = found;

            }

            if (rows.items.len > 0) try filtered(allocator, &scanlines, rows.items, columns * 3, 3, pass);

        }

        const stream = try deflate(allocator, scanlines.items);
        const bytes = try fixture(allocator, .{ width, height, 8, 2, 1 }, &.{.{ .kind = "tRNS", .body = &.{ 0, 20, 0, 30, 0, 7 } }}, stream);

        _ = try decode(allocator, bytes, &pixels);

        for (0..height) |y| {

            for (0..width) |x| {

                const expected: u32 = if (x == 1 and y == 1) 0 else @intCast(0xff000000 | x * 20 << 16 | y * 30 << 8 | 7);

                try std.testing.expectEqual(expected, pixels[y * width + x]);

            }

        }

    }

}

test "png rejects corrupt, truncated, and oversized input without crashing" {

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();

    const allocator = arena.allocator();
    const bytes = try encode(allocator, &.{ 0x102030, 0x405060, 0x708090, 0xa0b0c0 }, 2, 2);
    const length = std.mem.readInt(u32, bytes[33..37], .big);
    var pixels: [16]u32 = undefined;

    for (0..bytes.len) |end| try std.testing.expectError(error.Invalid, decode(allocator, bytes[0..end], &pixels));

    // A flipped bit fails its chunk's CRC; with the CRC redone, the zlib checks still catch it.
    for ([_]usize{ 41, 44, 48, bytes.len - 17 }) |index| {

        const corrupt = try allocator.dupe(u8, bytes);

        corrupt[index] ^= 1;
        try std.testing.expectError(error.Invalid, decode(allocator, corrupt, &pixels));
        _ = seal(corrupt, 33, "IDAT", length);
        try std.testing.expectError(error.Invalid, decode(allocator, corrupt, &pixels));

    }

    try std.testing.expectError(error.Invalid, decode(allocator, bytes, pixels[0..3]));
    try std.testing.expectError(error.Invalid, size(bytes[1..]));
    try std.testing.expectError(error.Unsupported, size(try fixture(allocator, .{ 16385, 1, 8, 2, 0 }, &.{}, "")));
    try std.testing.expectError(error.Unsupported, decode(allocator, try fixture(allocator, .{ 1, 0x7fffffff, 8, 2, 0 }, &.{}, ""), &pixels));
    try std.testing.expectError(error.Invalid, size(try fixture(allocator, .{ 0, 1, 8, 2, 0 }, &.{}, "")));
    try std.testing.expectError(error.Invalid, size(try fixture(allocator, .{ 1, 1, 16, 3, 0 }, &.{}, "")));
    try std.testing.expectError(error.Unsupported, decode(allocator, try fixture(allocator, .{ 1, 1, 8, 2, 0 }, &.{.{ .kind = "WHAT", .body = "" }}, ""), &pixels));

    // Every single-bit change to a real Huffman stream must decode or fail, never crash.
    var stream: [huffman.len / 2]u8 = undefined;

    _ = try std.fmt.hexToBytes(&stream, huffman);

    for (0..stream.len * 8) |bit| {

        var mutated = stream;

        mutated[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
        _ = decode(allocator, try fixture(allocator, .{ 3, 5, 16, 6, 0 }, &.{}, &mutated), &pixels) catch continue;

    }

}
