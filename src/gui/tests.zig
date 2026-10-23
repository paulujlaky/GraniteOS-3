const std = @import("std");

const font = @import("font.zig");
const canvas = @import("canvas.zig");
const draw = @import("draw.zig");
const node = @import("node.zig");
const quartz = @import("quartz.zig");
const sketch = @import("sketch.zig");
const text = @import("text.zig");

comptime {

    _ = @import("png.zig");

}

test "font rasterizes every printable ASCII glyph with solid stems and open counters" {

    const face = font.sans();

    for ('!'..'~' + 1) |ascii| {

        const glyph = face.lookup(@intCast(ascii));

        try std.testing.expect(glyph != 0);
        try std.testing.expect(face.render(glyph, 40 / face.units, 0.5) != null);

    }

    try std.testing.expectEqual(null, face.render(face.lookup(' '), 40 / face.units, 0));

    const letter = face.render(face.lookup('H'), 64 / face.units, 0).?;
    const center = letter.width / 2;

    for (letter.coverage) |cell| try std.testing.expect(cell >= 0 and cell <= 1);
    try std.testing.expect(letter.coverage[letter.height / 4 * letter.width + center] < 0.01);
    try std.testing.expect(letter.coverage[letter.height / 2 * letter.width + center] > 0.99);
    try std.testing.expect(std.mem.indexOfScalar(f32, letter.coverage[letter.height / 4 * letter.width ..][0..letter.width], 1) != null);
    try std.testing.expect(letter.top < -40 and letter.top > -50);

}

test "every named icon has a distinct glyph in the icon font that renders" {

    const face = font.face(.icons);
    var seen = std.AutoHashMap(u16, void).init(std.testing.allocator);

    defer seen.deinit();

    for (std.enums.values(font.Icon)) |icon| {

        const glyph = face.lookup(@intFromEnum(icon));

        try std.testing.expect(glyph != 0);
        try std.testing.expect(face.render(glyph, 24 / face.units, 0) != null);
        try std.testing.expect(!(try seen.getOrPut(glyph)).found_existing);

    }

}

test "font kerns letter pairs from its table and measures with them" {

    const face = font.sans();
    const scale = 40 / face.units;

    try std.testing.expect(face.pairs.len > 0);
    try std.testing.expect(face.kerning(face.lookup('A'), face.lookup('V')) < 0);
    try std.testing.expect(face.kerning(face.lookup('T'), face.lookup('o')) < 0);
    try std.testing.expectEqual(0, face.kerning(face.lookup('H'), face.lookup('H')));
    try std.testing.expect(face.measure("AV", scale) < face.measure("A", scale) + face.measure("V", scale));
    try std.testing.expectEqual(face.measure("HH", scale), 2 * face.measure("H", scale));

}

test "canvas clips fills, rounds corners, and blits only the overlap" {

    var pixels = [_]u32{0} ** (32 * 24);

    var target = canvas.Canvas{

        .pixels = &pixels,
        .width = 32,
        .height = 24,

    };

    target.round(.{

        .x = -4,
        .y = 2,
        .width = 40,
        .height = 20,

    }, 8, 0xffffff);

    try std.testing.expectEqual(0xffffff, pixels[12 * 32 + 16]);
    try std.testing.expectEqual(0, pixels[0]);
    try std.testing.expect(pixels[2 * 32 + 31] != 0xffffff);

    var small = [_]u32{0x123456} ** (4 * 4);

    const source = canvas.Canvas{

        .pixels = &small,
        .width = 4,
        .height = 4,

    };

    target.blit(&source, .{

        .x = 30,
        .y = -2,

    }, target.bounds());

    try std.testing.expectEqual(0x123456, pixels[0 * 32 + 30]);
    try std.testing.expectEqual(0x123456, pixels[1 * 32 + 31]);
    try std.testing.expect(pixels[2 * 32 + 30] != 0x123456);

    target.fill(target.bounds(), 0xffffff);
    target.label(font.sans(), "Hi", 16, target.bounds(), 0x000000, .center);

    try std.testing.expect(std.mem.indexOfScalar(u32, &pixels, 0x000000) != null);

}

test "flex layout grows, centres, and stretches children and reports what moved" {

    var fixed = node.Node{

        .style = .{

            .width = 40,
            .height = 10,

        },

    };

    var grown = node.Node{

        .style = .{

            .grow = 1,

        },

    };

    var hidden = node.Node{

        .hidden = true,

    };

    var row = node.Node{

        .style = .{

            .direction = .row,
            .gap = 4,
            .items = .center,
            .padding = .all(2),

        },
        .content = .{

            .box = &.{ &fixed, &hidden, &grown },

        },

    };

    var damage = canvas.Rect{};

    row.arrange(.{

        .width = 100,
        .height = 30,

    }, &damage);

    try std.testing.expectEqual(canvas.Rect{ .x = 2, .y = 10, .width = 40, .height = 10 }, fixed.rect);
    try std.testing.expectEqual(canvas.Rect{ .x = 46, .y = 15, .width = 52, .height = 0 }, grown.rect);
    try std.testing.expectEqual(canvas.Rect{}, hidden.rect);
    try std.testing.expectEqual(canvas.Rect{ .width = 100, .height = 30 }, damage);

    var column = node.Node{

        .style = .{

            .justify = .center,

        },
        .content = .{

            .box = &.{&fixed},

        },

    };

    damage = .{};

    column.arrange(.{

        .width = 100,
        .height = 30,

    }, &damage);

    try std.testing.expectEqual(canvas.Rect{ .y = 10, .width = 40, .height = 10 }, fixed.rect);

}

test "text wraps after spaces and moves the caret between wrapped lines" {

    const face = font.sans();
    const width: i32 = @intFromFloat(face.measure("hello ", 20 / face.units) + 1);
    var lines = text.Lines.init(face, "hello world\nx", 20, width);

    try std.testing.expectEqual(text.Line{ .start = 0, .end = 6 }, lines.next().?);
    try std.testing.expectEqual(text.Line{ .start = 6, .end = 11 }, lines.next().?);
    try std.testing.expectEqual(text.Line{ .start = 12, .end = 13 }, lines.next().?);
    try std.testing.expectEqual(null, lines.next());

    var bytes = "hello world\nx".*;

    var edit = text.Text{

        .buffer = &bytes,
        .length = bytes.len,
        .caret = 1,

    };

    try std.testing.expect(edit.vertical(face, 20, width, 1, false));
    try std.testing.expectEqual(7, edit.caret);
    try std.testing.expect(edit.vertical(face, 20, width, 1, false));
    try std.testing.expectEqual(13, edit.caret);
    try std.testing.expect(!edit.vertical(face, 20, width, 1, false));

}

test "recorded commands replay exactly as direct drawing and survive hostile bytes" {

    var bytes: [1024]u8 align(4) = undefined;

    var list = draw.List{

        .bytes = &bytes,
        .width = 32,
        .height = 24,

    };

    list.fill(list.bounds(), 0x202020);

    list.limit = .{

        .x = 2,
        .width = 28,
        .height = 20,

    };

    list.round(.{

        .x = -4,
        .y = 2,
        .width = 40,
        .height = 20,

    }, 8, 0xffffff);

    list.label("Hi", .sans, 16, list.bounds(), 0x000000, .center);

    var direct = [_]u32{0} ** (32 * 24);
    var replayed = [_]u32{0} ** (32 * 24);

    var expected = canvas.Canvas{

        .pixels = &direct,
        .width = 32,
        .height = 24,

    };

    var actual = canvas.Canvas{

        .pixels = &replayed,
        .width = 32,
        .height = 24,

    };

    expected.fill(expected.bounds(), 0x202020);
    expected.limit = list.limit;

    expected.round(.{

        .x = -4,
        .y = 2,
        .width = 40,
        .height = 20,

    }, 8, 0xffffff);

    expected.label(font.sans(), "Hi", 16, expected.bounds(), 0x000000, .center);
    draw.replay(&actual, list.commands(), .{}, actual.bounds(), null);

    try std.testing.expectEqualSlices(u32, &direct, &replayed);

    // Truncated, oversized, and garbage commands are skipped rather than trusted.
    var commands = draw.iterate(list.commands()[0 .. list.length - 3]);
    var count: usize = 0;

    while (commands.next()) |_| count += 1;
    try std.testing.expectEqual(2, count);

    @memset(bytes[4..8], 0xff);
    commands = draw.iterate(list.commands());
    try std.testing.expectEqual(null, commands.next());

}

test "translucent backgrounds keep their transparency through recording, stacking, and replay" {

    var under = node.Node{

        .style = .{

            .background = 0x808080,

        },

    };

    var dim = node.Node{

        .style = .{

            .background = canvas.shade(0x000000, 128),

        },

    };

    var stack = node.Node{

        .style = .{

            .direction = .stack,

        },
        .content = .{

            .box = &.{ &under, &dim },

        },

    };

    var damage = canvas.Rect{};
    var bytes: [1024]u8 align(4) = undefined;

    var list = draw.List{

        .bytes = &bytes,
        .width = 8,
        .height = 8,

    };

    stack.arrange(list.bounds(), &damage);
    stack.paint(&list, .{}, 0);

    var commands = draw.iterate(list.commands());
    var colors: [2]u32 = undefined;
    var count: usize = 0;

    while (commands.next()) |command| : (count += 1) colors[count] = command.shape.color;

    try std.testing.expectEqual(2, count);
    try std.testing.expectEqual(0x7f000000, colors[1]);

    var pixels = [_]u32{0} ** 64;

    var target = canvas.Canvas{

        .pixels = &pixels,
        .width = 8,
        .height = 8,

    };

    draw.replay(&target, list.commands(), .{}, target.bounds(), null);
    try std.testing.expect(pixels[27] & 0xff > 0x38 and pixels[27] & 0xff < 0x48);

}

test "stacked children share the container and scrolled ones slide by its offset" {

    var under = node.Node{};
    var over = node.Node{};

    var stack = node.Node{

        .style = .{

            .direction = .stack,
            .padding = .all(2),

        },
        .content = .{

            .box = &.{ &under, &over },

        },

    };

    var damage = canvas.Rect{};

    stack.arrange(.{

        .width = 40,
        .height = 30,

    }, &damage);

    try std.testing.expectEqual(canvas.Rect{ .x = 2, .y = 2, .width = 36, .height = 26 }, under.rect);
    try std.testing.expectEqual(under.rect, over.rect);

    var rows: [5]node.Node = undefined;
    var children: [5]*node.Node = undefined;

    for (&rows, &children) |*row, *child| {

        row.* = .{

            .style = .{

                .height = 20,

            },

        };

        child.* = row;

    }

    var list = node.Node{

        .style = .{

            .scroll = true,

        },
        .content = .{

            .box = &children,

        },
        .offset = 80,

    };

    const area = canvas.Rect{

        .width = 40,
        .height = 50,

    };

    list.arrange(area, &damage);

    // Scrolling stops once the last row shows.
    try std.testing.expectEqual(100, list.extent);
    try std.testing.expectEqual(50, list.offset);
    try std.testing.expectEqual(10, rows[3].rect.y);

    list.offset = 0;
    list.arrange(area, &damage);
    try std.testing.expectEqual(&list, list.wheel(.{ .x = 5, .y = 5 }, 30).?);
    try std.testing.expectEqual(30, list.offset);

    list.offset = 0;
    list.arrange(area, &damage);
    try std.testing.expect(list.reveal(&rows[4]));
    try std.testing.expectEqual(50, list.offset);

}

test "text selections extend, replace, erase, and snap to words" {

    var bytes: [32]u8 = undefined;

    var edit = text.Text{

        .buffer = &bytes,

    };

    edit.set("hello world");
    edit.select(5, false);
    edit.select(11, true);

    try std.testing.expectEqualStrings(" world", edit.selected());
    try std.testing.expect(edit.paste("!"));
    try std.testing.expectEqualStrings("hello!", edit.text());
    try std.testing.expectEqual(6, edit.caret);

    edit.select(2, false);
    edit.word();
    try std.testing.expectEqualStrings("hello", edit.selected());
    try std.testing.expect(edit.erase());
    try std.testing.expectEqualStrings("!", edit.text());

    // Secret text never leaves through a selection.
    edit.secret = true;
    edit.set("hunter2");
    edit.all();
    try std.testing.expectEqualStrings("", edit.selected());

}

test "style changes reach into nested colours and keep the rest of the base" {

    const style = @import("style.zig");

    const base = style.Style{

        .radius = 4,
        .hover = .{

            .background = 1,
            .border = 2,

        },

    };

    const changed = base.with(.{

        .width = 10,
        .hover = .{

            .background = 3,

        },

    });

    try std.testing.expectEqual(10, changed.width.?);
    try std.testing.expectEqual(4, changed.radius);
    try std.testing.expectEqual(3, changed.hover.background.?);
    try std.testing.expectEqual(2, changed.hover.border.?);

}

test "UTF-8 text decodes leniently, keeps the caret on whole characters, and draws accented letters" {

    const face = font.sans();
    var characters = font.decode("a\u{e9}\xff");

    try std.testing.expectEqual('a', characters.next().?);
    try std.testing.expectEqual(0xe9, characters.next().?);
    try std.testing.expectEqual(0xfffd, characters.next().?);
    try std.testing.expectEqual(null, characters.next());

    // Accented letters are composites of a base letter and a mark, so they ink more than the plain letter.
    const plain = face.render(face.lookup('e'), 40 / face.units, 0).?;
    var ink: f32 = 0;

    for (plain.coverage) |cell| ink += cell;

    const accented = face.render(face.lookup(0xe9), 40 / face.units, 0).?;
    var accented_ink: f32 = 0;

    for (accented.coverage) |cell| accented_ink += cell;
    try std.testing.expect(accented_ink > ink * 1.05);

    var bytes = "\u{e9}\u{e9}\n\u{e9}\u{e9}".*;

    var edit = text.Text{

        .buffer = &bytes,
        .length = bytes.len,
        .caret = 2,

    };

    try std.testing.expect(edit.vertical(face, 20, 1000, 1, false));
    try std.testing.expectEqual(7, edit.caret);

}

test "sketches cover anti-aliased discs, lines, arcs, and outlines, and skip glyphs outside a canvas's limit" {

    var pixels = [_]u32{0} ** (32 * 32);

    var target = sketch.Sketch{

        .pixels = &pixels,
        .width = 32,
        .height = 32,

    };

    // Solid inside, clear outside, and part-covered on the edge, premultiplied.
    target.disc(16, 16, 6.3, 0xffffff);
    try std.testing.expectEqual(0xffffffff, pixels[16 * 32 + 16]);
    try std.testing.expectEqual(0, pixels[16 * 32 + 26]);

    const edge = pixels[16 * 32 + 22];

    try std.testing.expect(edge >> 24 > 0 and edge >> 24 < 255 and edge & 0xff == edge >> 24);

    // A quarter arc from twelve to three o'clock inks the top right only.
    target.clear(sketch.transparent);
    target.arc(16, 16, 10, 2, 0, 0.25, 0xffffff);
    try std.testing.expect(pixels[6 * 32 + 22] >> 24 > 0 or pixels[8 * 32 + 23] >> 24 > 0);
    try std.testing.expectEqual(0, pixels[26 * 32 + 16]);
    try std.testing.expectEqual(0, pixels[16 * 32 + 6]);

    // A translucent line blends over what is there; an outlined rectangle leaves its middle alone.
    target.clear(0x000000);
    target.line(2, 16, 30, 16, 4, canvas.shade(0xffffff, 128));
    try std.testing.expect(pixels[16 * 32 + 16] & 0xff > 100 and pixels[16 * 32 + 16] & 0xff < 140);
    target.rectangle(.{ 4, 4, 28, 28 }, 0, 2, 0xff0000);
    try std.testing.expectEqual(0xffff0000, pixels[4 * 32 + 16]);
    try std.testing.expectEqual(0xff000000, pixels[10 * 32 + 10]);

    // Text wholly outside the limit draws nothing, as when only a window's corner is redrawn.
    var screen = [_]u32{0} ** (64 * 64);

    var surface = canvas.Canvas{

        .pixels = &screen,
        .width = 64,
        .height = 64,
        .limit = .{ .x = 0, .y = 0, .width = 8, .height = 8 },

    };

    surface.text(font.sans(), "Hidden", 14, 20, 40, 0xffffff);
    for (screen) |pixel| try std.testing.expectEqual(0, pixel);

}

test "recorded shapes, curves, and shadows replay where a sketch would paint them" {

    var bytes: [4096]u8 align(4) = undefined;

    var list = draw.List{

        .bytes = &bytes,
        .width = 48,
        .height = 48,

    };

    var recorder = sketch.Sketch{

        .width = 40,
        .height = 40,
        .list = &list,
        .origin = .{

            .x = 4,
            .y = 4,

        },

    };

    const points = [_][2]f32{ .{ 2, 30 }, .{ 20, 10 }, .{ 38, 20 } };

    recorder.disc(20, 20, 9.5, 0xffffff);
    recorder.line(2, 2, 38, 38, 3, 0xff0000);
    recorder.curve(&points, 2, 0x00ff00, null);

    var screen = [_]u32{0} ** (48 * 48);

    var target = canvas.Canvas{

        .pixels = &screen,
        .width = 48,
        .height = 48,

    };

    draw.replay(&target, list.commands(), .{}, target.bounds(), null);

    // Moved by the sketch's origin: the disc's middle, the line along the diagonal, and the curve's middle point.
    try std.testing.expectEqual(0xff0000, screen[24 * 48 + 24]);
    try std.testing.expectEqual(0xff0000, screen[40 * 48 + 40]);
    try std.testing.expectEqual(0x00ff00, screen[14 * 48 + 24]);
    try std.testing.expectEqual(0, screen[2 * 48 + 46]);

    // A shadow darkens towards its edge and leaves its middle to whatever casts it.
    @memset(&screen, 0xffffff);

    target.shadow(.{

        .x = 8,
        .y = 8,
        .width = 32,
        .height = 32,

    }, 4, 6, 0x000000);

    try std.testing.expectEqual(0xffffff, screen[24 * 48 + 24]);
    try std.testing.expect(screen[24 * 48 + 7] & 0xff < screen[24 * 48 + 4] & 0xff);
    try std.testing.expectEqual(0xffffff, screen[24 * 48 + 0]);

}

test "labels keep descenders inside a box one line tall and stay centred in taller ones" {

    const face = font.sans();

    for ([_]f32{ 13, 15, 20 }) |size| {

        const line = canvas.Rect{

            .width = 100,
            .height = text.leading(face, size),

        };

        const start = canvas.anchor(face, "gyp", size, line, .left);
        const descent = @as(f32, @floatFromInt(@abs(face.descent))) * size / face.units;

        try std.testing.expect(@as(f32, @floatFromInt(start.y)) + descent <= @as(f32, @floatFromInt(line.bottom())) + 0.5);

    }

    // Capitals sit midway down a control, as before.
    const button = canvas.Rect{

        .width = 100,
        .height = 32,

    };

    const capital = @as(f32, @floatFromInt(face.capital)) * 15 / face.units;

    try std.testing.expectEqual(@as(i32, @intFromFloat(@round((32 + capital) / 2))), canvas.anchor(face, "Save", 15, button, .center).y);

}

test "recorded Quartz softens what lies beneath under its tint, rounds its corners, and draws solid without room" {

    var pixels: [64 * 48]u32 = undefined;
    var spare: [quartz.room(64, 48)]u32 = undefined;
    var bytes: [256]u8 align(4) = undefined;

    var target = canvas.Canvas{

        .pixels = &pixels,
        .width = 64,
        .height = 48,
        .spare = &spare,

    };

    var list = draw.List{

        .bytes = &bytes,
        .width = 64,
        .height = 48,

    };

    const area = canvas.Rect{

        .x = 8,
        .y = 8,
        .width = 48,
        .height = 32,

    };

    // Black meets white at x = 32; a clear tint shows the blur alone.
    for (0..48) |y| {

        for (0..64) |x| pixels[y * 64 + x] = if (x < 32) 0x000000 else 0xffffff;

    }

    list.quartz(area, 8, 0xff000000);
    draw.replay(&target, list.commands(), .{}, target.bounds(), null);

    try std.testing.expect(pixels[24 * 64 + 10] & 0xff < 0x08);
    try std.testing.expect(pixels[24 * 64 + 53] & 0xff > 0xf7);
    try std.testing.expect(pixels[24 * 64 + 26] & 0xff > 0x10);
    try std.testing.expect(pixels[24 * 64 + 31] & 0xff > 0x40 and pixels[24 * 64 + 32] & 0xff < 0xc0);
    try std.testing.expectEqual(0x000000, pixels[24 * 64 + 6]);

    // Over flat grey, a quarter-opaque white tint lightens it evenly, and the corners stay outside the curve.
    @memset(&pixels, 0x808080);
    list.reset();
    list.quartz(area, 8, canvas.shade(0xffffff, 64));
    draw.replay(&target, list.commands(), .{}, target.bounds(), null);

    try std.testing.expect(pixels[24 * 64 + 32] & 0xff >= 0x9d and pixels[24 * 64 + 32] & 0xff <= 0xa1);
    try std.testing.expectEqual(pixels[24 * 64 + 32], pixels[12 * 64 + 50]);
    try std.testing.expectEqual(0x808080, pixels[8 * 64 + 8]);

    target.spare = &.{};
    draw.replay(&target, list.commands(), .{}, target.bounds(), null);

    try std.testing.expectEqual(0xffffff, pixels[24 * 64 + 32]);

    // The GPU's merged taps weigh the same as the CPU's.
    var total = quartz.pairs[0][1];

    for (quartz.pairs[1..]) |pair| total += 2 * pair[1];

    try std.testing.expectApproxEqAbs(1, total, 0.0001);

}

test "every pointer image points at a pixel of its own" {

    const cursor = @import("cursor.zig");

    for (std.enums.values(cursor.Cursor)) |look| {

        const image = cursor.sprite(look);

        try std.testing.expectEqual(image.width * image.height, image.pixels.len);
        try std.testing.expect(image.hotspot.x >= 0 and image.hotspot.x < image.width);
        try std.testing.expect(image.hotspot.y >= 0 and image.hotspot.y < image.height);

    }

    // Turned images keep their outline: the upright double arrow is the sideways one across the diagonal.
    const sideways = cursor.sprite(.horizontal);
    const upright = cursor.sprite(.vertical);

    try std.testing.expectEqual(sideways.width, upright.height);
    try std.testing.expectEqual(sideways.pixels[4 * sideways.width + 0], upright.pixels[0 * upright.width + 4]);

}

const document = @import("document.zig");

/// Checks every line start against a count of the text's newlines.
fn indexed(page: *const document.Document) !void {

    const string = page.text();

    try std.testing.expectEqual(std.mem.count(u8, string, "\n") + 1, page.count());

    var line: usize = 0;

    for (string, 0..) |byte, index| {

        try std.testing.expectEqual(line, page.line(index));
        if (byte == '\n') line += 1;
        if (byte == '\n') try std.testing.expectEqual(index + 1, page.start(line));

    }

    try std.testing.expectEqual(line, page.line(string.len));

}

test "documents keep their line index through random edits and grow past any fixed size" {

    var page = document.Document.init(std.testing.allocator);

    defer page.deinit();

    try page.set("one\ntwo\n\nthree");
    try indexed(&page);
    try std.testing.expectEqualStrings("two", page.content(1));
    try std.testing.expectEqualStrings("", page.content(2));
    try std.testing.expectEqual(4, page.end(1) + 1 - page.start(1) + 0);

    var random = std.Random.DefaultPrng.init(7);
    const pieces = [_][]const u8{ "", "x", "\n", "ab\ncd", "\n\n", "é\n" };

    for (0..400) |_| {

        const length = page.length();
        const from = random.random().uintAtMost(usize, length);
        const to = @min(length, from + random.random().uintAtMost(usize, 6));
        const piece = pieces[random.random().uintLessThan(usize, pieces.len)];

        try page.replace(from, to, piece, .at(from), .other);
        try indexed(&page);

    }

    // Well past the editor's old four-mebibyte limit.
    const chunk = "0123456789abcde\n" ** 4096;

    for (0..80) |_| try page.replace(page.length(), page.length(), chunk, .at(0), .joined);

    try std.testing.expect(page.length() > 5 << 20);
    try std.testing.expectEqual(page.length(), page.end(page.count() - 1));
    try indexed(&page);

}

test "undo and redo walk many steps, gathering typed words and deletions into one step each" {

    var page = document.Document.init(std.testing.allocator);

    defer page.deinit();

    try page.set("");

    for ("hi there", 0..) |byte, index| try page.replace(index, index, &.{byte}, .at(index), .typing);

    try page.replace(8, 8, "\n", .at(8), .typing);
    try page.replace(9, 9, "x", .at(9), .typing);
    try std.testing.expectEqualStrings("hi there\nx", page.text());

    // Backspacing three characters is one step.
    try page.replace(9, 10, "", .at(10), .deleting);
    try page.replace(8, 9, "", .at(9), .deleting);
    try page.replace(7, 8, "", .at(8), .deleting);
    try std.testing.expectEqualStrings("hi ther", page.text());

    try std.testing.expectEqual(document.Selection.at(10), (try page.undo()).?);
    try std.testing.expectEqualStrings("hi there\nx", page.text());
    try std.testing.expectEqual(document.Selection.at(9), (try page.undo()).?);
    try std.testing.expectEqualStrings("hi there\n", page.text());
    _ = try page.undo();
    try std.testing.expectEqualStrings("hi ", page.text());
    _ = try page.undo();
    try std.testing.expectEqualStrings("", page.text());
    try std.testing.expectEqual(null, try page.undo());

    try std.testing.expectEqual(document.Selection.at(3), (try page.redo()).?);
    try std.testing.expectEqualStrings("hi ", page.text());

    for (0..4) |_| _ = try page.redo();
    try std.testing.expectEqualStrings("hi ther", page.text());
    try std.testing.expectEqual(null, try page.redo());
    try indexed(&page);

    // Steps of one command undo together, and a new edit drops what was undone.
    page.seal();
    try page.replace(0, 0, "a", .at(0), .joined);
    try page.replace(page.length(), page.length(), "z", .at(0), .joined);
    try std.testing.expectEqualStrings("ahi therz", page.text());
    _ = try page.undo();
    try std.testing.expectEqualStrings("hi ther", page.text());
    try page.replace(0, 2, "yo", .at(0), .other);
    try std.testing.expectEqual(null, try page.redo());
    try std.testing.expectEqualStrings("yo ther", page.text());

}

test "a document's revision returns to the saved one when its changes are undone" {

    var page = document.Document.init(std.testing.allocator);

    defer page.deinit();

    try page.set("text");

    const opened = page.revision();

    try page.replace(4, 4, "s", .at(4), .typing);

    const saved = page.revision();

    page.seal();
    try page.replace(5, 5, "!", .at(5), .typing);
    try std.testing.expect(page.revision() != saved);
    _ = try page.undo();
    try std.testing.expectEqual(saved, page.revision());
    _ = try page.undo();
    try std.testing.expectEqual(opened, page.revision());

    // Another edit after undoing is a different text, even at the same depth.
    try page.replace(0, 1, "n", .at(0), .typing);
    try std.testing.expect(page.revision() != saved and page.revision() != opened);

}

const regex = @import("regex.zig");
const search = @import("search.zig");

/// The first match of `pattern` in `haystack` as text, or null.
fn matched(pattern: []const u8, haystack: []const u8, fold: bool) !?[]const u8 {

    var expression = try regex.Regex.compile(std.testing.allocator, pattern, fold);

    defer expression.deinit();

    const captures = expression.find(haystack, 0) orelse return null;

    return haystack[captures[0]..captures[1]];

}

test "regular expressions match literals, classes, anchors, alternation, and greedy or lazy repeats leftmost first" {

    const cases = [_]struct { []const u8, []const u8, ?[]const u8 }{

        .{ "abc", "xxabcxx", "abc" },
        .{ "a.c", "a\nc abc", "abc" },
        .{ "colou?r", "my color", "color" },
        .{ "\\d+", "id 4521x", "4521" },
        .{ "[^a-z ]+", "abc DEF ghi", "DEF" },
        .{ "[a-c-]+", "zz-ab-c", "-ab-c" },
        .{ "\\bcat\\b", "concat cat", "cat" },
        .{ "^b", "a\nb", "b" },
        .{ "a$", "ab\na\r\n", "a" },
        .{ "cat|category", "category", "cat" },
        .{ "(cat|category)s", "categorys", "categorys" },
        .{ "<.+>", "<a><b>", "<a><b>" },
        .{ "<.+?>", "<a><b>", "<a>" },
        .{ "x{2,3}", "x xx xxxx", "xx" },
        .{ "x{3,}", "xx xxxxx", "xxxxx" },
        .{ "(?:ab){2}", "ab abab", "abab" },
        .{ "a{,2}", "a{,2}", "a{,2}" },
        .{ "é.", "café!", "é!" },
        .{ "\\w+", "  _id9 ", "_id9" },
        .{ "\\s\\S", "ab c", " c" },
        .{ "\\x41\\.", "A. A.", "A." },
        .{ "(a*)*b", "aaab", "aaab" },
        .{ "z", "abc", null },

    };

    for (cases) |case| {

        const pattern, const haystack, const want = case;
        const got = try matched(pattern, haystack, false);

        if (want) |expected| try std.testing.expectEqualStrings(expected, got.?) else try std.testing.expectEqual(null, got);

    }

    try std.testing.expectEqualStrings("HeLLo", (try matched("hello", "say HeLLo", true)).?);
    try std.testing.expectEqualStrings("Q", (try matched("[p-r]", "Q", true)).?);
    try std.testing.expectEqual(null, try matched("hello", "say HeLLo", false));

    for ([_][]const u8{ "(ab", "ab)", "*a", "a**", "[a-", "[z-a]", "\\q","(?<x>a)", "a{2}{3}" }) |broken| {

        try std.testing.expectError(error.Invalid, regex.Regex.compile(std.testing.allocator, broken, false));

    }

    try std.testing.expectError(error.Complex, regex.Regex.compile(std.testing.allocator, "((a{100}){100}){100}", false));

}

test "regular expressions capture groups and take time linear in the text" {

    var expression = try regex.Regex.compile(std.testing.allocator, "(\\w+)@(\\w+)(x)?", false);

    defer expression.deinit();

    const haystack = "mail: ann@example now";
    const captures = expression.find(haystack, 0).?;

    try std.testing.expectEqualStrings("ann", haystack[captures[2]..captures[3]]);
    try std.testing.expectEqualStrings("example", haystack[captures[4]..captures[5]]);
    try std.testing.expectEqual(regex.unset, captures[6]);

    // A pattern that backtracking engines take exponential time over finishes at once.
    var nasty = try regex.Regex.compile(std.testing.allocator, "(a*)*(a*)*c", false);

    defer nasty.deinit();

    try std.testing.expectEqual(null, nasty.find("a" ** 4000, 0));

}

test "finders match case and whole words, step both ways, count, and fill in replacements" {

    var finder = search.Finder.init(std.testing.allocator);

    defer finder.deinit();

    const haystack = "Cat cat concat CAT";

    try finder.set("cat", .{});
    try std.testing.expectEqual(search.Match{ .start = 0, .end = 3 }, finder.next(haystack, 0).?);
    try std.testing.expectEqual(4, finder.count(haystack, 100));
    try std.testing.expectEqual(2, finder.count(haystack, 2));

    try finder.set("cat", .{ .case = true, .word = true });
    try std.testing.expectEqual(search.Match{ .start = 4, .end = 7 }, finder.next(haystack, 0).?);
    try std.testing.expectEqual(null, finder.next(haystack, 5));
    try std.testing.expectEqual(1, finder.count(haystack, 100));

    try finder.set("cat", .{ .word = true });
    try std.testing.expectEqual(search.Match{ .start = 4, .end = 7 }, finder.previous(haystack, 15).?);
    try std.testing.expectEqual(search.Match{ .start = 15, .end = 18 }, finder.previous(haystack, haystack.len + 1).?);
    try std.testing.expectEqual(null, finder.previous(haystack, 0));

    var out: std.ArrayList(u8) = .empty;

    defer out.deinit(std.testing.allocator);

    try finder.set("(\\w+)=(\\d+)", .{ .regex = true });

    const pairs = "a=1 bb=22";
    const found = finder.next(pairs, 0).?;

    try finder.expand(pairs, found, "$2:$1 $$ $& \\t$9.", &out, std.testing.allocator);
    try std.testing.expectEqualStrings("1:a $ a=1 \t.", out.items);
    try std.testing.expectEqual(2, finder.count(pairs, 100));

    // Empty matches step past themselves, so a search for line starts finds each line once.
    try finder.set("^", .{ .regex = true });
    try std.testing.expectEqual(3, finder.count("a\nb\nc", 100));

    try std.testing.expectError(error.Invalid, finder.set("(", .{ .regex = true }));
    try std.testing.expect(finder.idle());
    try std.testing.expectEqual(null, finder.next(haystack, 0));

}

const syntax = @import("syntax.zig");
const theme = @import("theme.zig");

/// Each span of `line` as its text and kind, starting in `state`, and the state it leaves.
fn spans(language: *const syntax.Language, line: []const u8, state: syntax.State, out: []syntax.Span) !struct { []const syntax.Span, syntax.State } {

    const count, const next = syntax.split(language, line, state, out);

    try std.testing.expectEqual(line.len, if (count == 0) 0 else out[count - 1].end);

    return .{ out[0..count], next };

}

/// The kind of the span covering byte `at`.
fn kind(found: []const syntax.Span, at: usize) syntax.Kind {

    for (found) |span| if (at < span.end) return span.kind;

    return .plain;

}

test "code splits into keywords, types, builtins, strings, numbers, and comments, carrying open ones to the next line" {

    var out: [64]syntax.Span = undefined;

    const zig_line = "pub fn main() !u8 { const x = @import(\"std\"); return 0x1F; } // done";
    const found, const after = try spans(&syntax.zig, zig_line, .normal, &out);

    try std.testing.expectEqual(.normal, after);
    try std.testing.expectEqual(.keyword, kind(found, 0));
    try std.testing.expectEqual(.function, kind(found, 7));
    try std.testing.expectEqual(.types, kind(found, 15));
    try std.testing.expectEqual(.builtin, kind(found, 31));
    try std.testing.expectEqual(.string, kind(found, 39));
    try std.testing.expectEqual(.number, kind(found, 55));
    try std.testing.expectEqual(.comment, kind(found, zig_line.len - 1));
    try std.testing.expectEqual(.punctuation, kind(found, 11));

    // Neighbouring spans of a kind join, and a full list runs its last span to the end yet still finds the state.
    for (found[1..], 0..) |span, index| try std.testing.expect(span.kind != found[index].kind);
    try std.testing.expectEqual(.comment, (try spans(&syntax.c, "x /* open", .normal, out[0..1]))[1]);

    const opened = try spans(&syntax.c, "int a; /* begins", .normal, &out);
    const middle = try spans(&syntax.c, "still inside", opened[1], &out);
    const closed = try spans(&syntax.c, "ends */ int b;", middle[1], &out);

    try std.testing.expectEqual(.comment, opened[1]);
    try std.testing.expectEqual(.comment, kind(middle[0], 0));
    try std.testing.expectEqual(.normal, closed[1]);
    try std.testing.expectEqual(.comment, kind(closed[0], 5));
    try std.testing.expectEqual(.types, kind(closed[0], 8));

    const docstring = try spans(&syntax.python, "    \"\"\"Doc", .normal, &out);

    try std.testing.expectEqual(.triple_double, docstring[1]);
    try std.testing.expectEqual(.normal, (try spans(&syntax.python, "end\"\"\" if True:", docstring[1], &out))[1]);
    try std.testing.expectEqual(.backtick, (try spans(&syntax.javascript, "const s = `tem", .normal, &out))[1]);

    const shell_line = try spans(&syntax.shell, "echo \"$HOME\" a#b # note", .normal, &out);

    try std.testing.expectEqual(.function, kind(shell_line[0], 0));
    try std.testing.expectEqual(.punctuation, kind(shell_line[0], 14));
    try std.testing.expectEqual(.comment, kind(shell_line[0], 18));

    const rust_line = try spans(&syntax.rust, "fn f<'a>(x: &'a str) { println!(\"{}\", 'c'); }", .normal, &out);

    try std.testing.expectEqual(.types, kind(rust_line[0], 5));
    try std.testing.expectEqual(.builtin, kind(rust_line[0], 23));
    try std.testing.expectEqual(.string, kind(rust_line[0], 39));

    const json_line = try spans(&syntax.json, "{ \"key\": \"value\", \"n\": -1.5e+3 }", .normal, &out);

    try std.testing.expectEqual(.types, kind(json_line[0], 3));
    try std.testing.expectEqual(.string, kind(json_line[0], 10));
    try std.testing.expectEqual(.number, kind(json_line[0], 25));

}

test "Markdown source shows headings, fences, markers, and inline styles, and languages come from names" {

    var out: [32]syntax.Span = undefined;

    try std.testing.expectEqual(.heading, kind((try spans(&syntax.markdown, "## Title", .normal, &out))[0], 3));
    try std.testing.expectEqual(.fence, (try spans(&syntax.markdown, "```zig", .normal, &out))[1]);
    try std.testing.expectEqual(.code, kind((try spans(&syntax.markdown, "# not a heading", .fence, &out))[0], 0));
    try std.testing.expectEqual(.normal, (try spans(&syntax.markdown, "```", .fence, &out))[1]);

    const line = "- **bold** and *em* `x` [a](b) snake_case_word";
    const found = (try spans(&syntax.markdown, line, .normal, &out))[0];

    try std.testing.expectEqual(.marker, kind(found, 0));
    try std.testing.expectEqual(.strong, kind(found, 4));
    try std.testing.expectEqual(.emphasis, kind(found, 16));
    try std.testing.expectEqual(.code, kind(found, 21));
    try std.testing.expectEqual(.link, kind(found, 25));
    try std.testing.expectEqual(.plain, kind(found, 40));

    try std.testing.expectEqual(&syntax.zig, syntax.detect("/home/a/main.zig", ""));
    try std.testing.expectEqual(&syntax.markdown, syntax.detect("README.MD", ""));
    try std.testing.expectEqual(&syntax.shell, syntax.detect("/bin/run", "#!/bin/sh"));
    try std.testing.expectEqual(&syntax.plain, syntax.detect("notes", "hello"));
    try std.testing.expectEqual(&syntax.python, syntax.find("Python").?);
    try std.testing.expectEqual(2, syntax.bullet("- x").?);
    try std.testing.expectEqual(4, syntax.bullet("12. x").?);
    try std.testing.expectEqual(null, syntax.bullet("12.x"));
    try std.testing.expect(syntax.rule("* * *") and !syntax.rule("**x"));

}

test "synthetic bold widens strokes and advances, and synthetic italics lean right" {

    const regular = font.face(.sans);
    const bold = font.face(.bold);
    const italic = font.face(.italic);
    const scale = 40 / regular.units;
    const glyph = regular.lookup('l');

    try std.testing.expect(bold.advance(glyph) > regular.advance(glyph));
    try std.testing.expect(bold.measure("Hello", scale) > regular.measure("Hello", scale));
    try std.testing.expectEqual(regular.measure("Hello", scale), italic.measure("Hello", scale));

    // Ink per row: a bold stem covers more, and an italic stem sits further right at its top than at its foot.
    const inked = struct {

        fn row(bitmap: font.Bitmap, y: usize) struct { f32, f32 } {

            var total: f32 = 0;
            var weighted: f32 = 0;

            for (0..bitmap.width) |x| {

                const cell = bitmap.coverage[y * bitmap.width + x];

                total += cell;
                weighted += cell * @as(f32, @floatFromInt(x));

            }

            return .{ total, weighted / @max(total, 0.001) + @as(f32, @floatFromInt(bitmap.left)) };

        }

    };

    const plain_bitmap = regular.render(glyph, scale, 0).?;
    const plain_ink = inked.row(plain_bitmap, plain_bitmap.height / 2)[0];
    const bold_bitmap = bold.render(glyph, scale, 0).?;

    try std.testing.expect(inked.row(bold_bitmap, bold_bitmap.height / 2)[0] > plain_ink * 1.3);

    const leaning = italic.render(glyph, scale, 0).?;
    const top = inked.row(leaning, 3)[1];
    const foot = inked.row(leaning, leaning.height - 4)[1];

    try std.testing.expect(top > foot + 4);

}

const code = @import("code.zig");

/// A code view over `string` in `language`, its caret at the `|` marking a place in it.
fn editing(language: *const syntax.Language, string: []const u8) !code.Code {

    var view = code.Code.init(std.testing.allocator);
    const at = std.mem.indexOfScalar(u8, string, '|').?;

    try view.document.set(string[0..at]);
    try view.document.replace(at, at, string[at + 1 ..], .at(0), .other);
    view.document.records.clearRetainingCapacity();
    view.document.log.clearRetainingCapacity();
    view.document.done = 0;
    view.speak(language);
    view.select(at, at);

    return view;

}

/// Checks the text, with `|` at the caret.
fn shows(view: *const code.Code, expected: []const u8) !void {

    var buffer: [256]u8 = undefined;
    const all = view.bytes();

    const marked = try std.fmt.bufPrint(&buffer, "{s}|{s}", .{ all[0..view.caret], all[view.caret..] });

    try std.testing.expectEqualStrings(expected, marked);

}

test "Enter keeps indentation, indents after an opener or a colon, and splits a bracket pair around a blank line" {

    var view = try editing(&syntax.zig, "    fn f() {|}");

    defer view.deinit();

    try view.enter();
    try shows(&view, "    fn f() {\n        |\n    }");
    try view.typed('x');
    try view.enter();
    try shows(&view, "    fn f() {\n        x\n        |\n    }");

    // Enter on a line of only indentation leaves it empty.
    try view.enter();
    try shows(&view, "    fn f() {\n        x\n\n        |\n    }");

    var python = try editing(&syntax.python, "if ready:|   ");

    defer python.deinit();

    try python.enter();
    try shows(&python, "if ready:\n    |");

    // The whole Enter undoes as a step, giving the caret back.
    try std.testing.expect(try python.undo());
    try shows(&python, "if ready:|   ");

}

test "brackets close themselves, step over their twins, delete in pairs, and closers dedent on a blank line" {

    var view = try editing(&syntax.zig, "call|");

    defer view.deinit();

    try view.typed('(');
    try shows(&view, "call(|)");
    try view.typed('a');
    try view.typed(')');
    try shows(&view, "call(a)|");
    try view.backspace(false);
    try view.backspace(false);
    try shows(&view, "call(|");
    try view.document.set("call(");
    view.select(5, 5);
    try view.typed('[');
    try shows(&view, "call([|]");
    try view.backspace(false);
    try shows(&view, "call(|");

    // Before a word, an opener stays alone; around a selection it wraps.
    try view.document.set("word");
    view.select(0, 0);
    try view.typed('(');
    try shows(&view, "(|word");
    view.select(1, 5);
    try view.typed('{');
    try std.testing.expectEqualStrings("({word}", view.bytes());
    try std.testing.expectEqualStrings("word", view.selected());

    var block = try editing(&syntax.c, "if (x) {\n    y;\n        |");

    defer block.deinit();

    try block.typed('}');
    try shows(&block, "if (x) {\n    y;\n}|");

    const pair = block.bracket().?;

    try std.testing.expectEqual([2]usize{ 16, 7 }, pair);

}

test "Tab indents and Shift+Tab dedents selected lines, comments toggle, and soft tabs backspace to their stop" {

    var view = try editing(&syntax.zig, "|a\n  b\nc");

    defer view.deinit();

    view.select(0, 6);
    try view.tab();
    try std.testing.expectEqualStrings("    a\n      b\nc", view.bytes());
    try std.testing.expectEqualStrings("    a\n      b\n", view.selected());
    try view.untab();
    try view.untab();
    try std.testing.expectEqualStrings("a\nb\nc", view.bytes());

    view.select(0, 3);
    try view.comment();
    try std.testing.expectEqualStrings("// a\n// b\nc", view.bytes());
    try view.comment();
    try std.testing.expectEqualStrings("a\nb\nc", view.bytes());

    // One undo brings back each whole rewrite.
    try std.testing.expect(try view.undo());
    try std.testing.expectEqualStrings("// a\n// b\nc", view.bytes());

    var spaces = try editing(&syntax.zig, "      |x");

    defer spaces.deinit();

    try spaces.backspace(false);
    try shows(&spaces, "    |x");
    try spaces.tab();
    try shows(&spaces, "        |x");
    spaces.home(false);
    try shows(&spaces, "|        x");
    spaces.home(false);
    try shows(&spaces, "        |x");
    spaces.select(9, 9);
    spaces.home(false);
    try shows(&spaces, "        |x");

}

test "Markdown lists carry on with the next marker and end on an empty item; wrapping and surrounding" {

    var view = try editing(&syntax.markdown, "- milk|");

    defer view.deinit();

    try view.enter();
    try shows(&view, "- milk\n- |");
    try view.enter();
    try shows(&view, "- milk\n|");

    try view.document.set("  9. nine");
    view.select(9, 9);
    try view.enter();
    try shows(&view, "  9. nine\n  10. |");

    try view.document.set("- [x] done");
    view.select(10, 10);
    try view.enter();
    try shows(&view, "- [x] done\n- [ ] |");

    try view.document.set("bold");
    view.select(0, 4);
    try view.surround("**", "**");
    try std.testing.expectEqualStrings("**bold**", view.bytes());
    try std.testing.expectEqualStrings("bold", view.selected());
    try view.surround("**", "**");
    try std.testing.expectEqualStrings("bold", view.bytes());

}

test "the caret moves by words, keeps its column through shorter lines, and walks wrapped rows" {

    var view = try editing(&syntax.plain, "|alpha beta\nab\ngamma delta");

    defer view.deinit();

    view.horizontal(1, true, false);
    try shows(&view, "alpha| beta\nab\ngamma delta");
    view.horizontal(1, true, true);
    try std.testing.expectEqualStrings(" beta", view.selected());
    view.horizontal(-1, false, false);
    try shows(&view, "alpha| beta\nab\ngamma delta");

    view.select(9, 9);
    view.vertical(1, false);
    try shows(&view, "alpha beta\nab|\ngamma delta");
    view.vertical(1, false);
    try shows(&view, "alpha beta\nab\ngamma del|ta");
    view.vertical(1, false);
    try shows(&view, "alpha beta\nab\ngamma delta|");

    // Wrapped at eight columns, each word sits on a row of its own.
    view.wrap = true;
    view.frame.columns = 8;
    view.select(1, 1);
    view.vertical(1, false);
    try shows(&view, "alpha b|eta\nab\ngamma delta");
    view.vertical(2, false);
    try shows(&view, "alpha beta\nab\ng|amma delta");
    view.vertical(-3, false);
    try shows(&view, "a|lpha beta\nab\ngamma delta");

    try std.testing.expectEqual(.{ 1, 2 }, view.position());

}

test "search selects matches around the ends, replaces one at a time or all in one step, and marks the bracket pair" {

    var view = try editing(&syntax.plain, "|one two one two");

    defer view.deinit();

    var finder = search.Finder.init(std.testing.allocator);

    defer finder.deinit();

    try finder.set("two", .{});
    try std.testing.expect(view.seek(&finder, true, view.caret));
    try std.testing.expectEqual(4, view.selection().start());
    try std.testing.expect(view.seek(&finder, true, view.selection().end()));
    try std.testing.expectEqual(12, view.selection().start());
    try std.testing.expect(view.seek(&finder, true, view.selection().end()));
    try std.testing.expectEqual(4, view.selection().start());
    try std.testing.expect(view.seek(&finder, false, view.selection().start()));
    try std.testing.expectEqual(12, view.selection().start());

    try std.testing.expect(try view.substitute(&finder, "2"));
    try std.testing.expectEqualStrings("one two one 2", view.bytes());
    try std.testing.expectEqual(4, view.selection().start());

    try finder.set("(o)ne", .{ .regex = true });
    try std.testing.expectEqual(2, try view.substituteAll(&finder, "[$1]"));
    try std.testing.expectEqualStrings("[o] two [o] 2", view.bytes());
    try std.testing.expect(try view.undo());
    try std.testing.expectEqualStrings("one two one 2", view.bytes());

}

test "the code view paints visible lines with their numbers and colours, and a press puts the caret under the pointer" {

    var view = try editing(&syntax.zig, "|const a = 1;\n" ** 200);

    defer view.deinit();

    var shown = view.node(.{});
    var damage = canvas.Rect{};

    shown.arrange(.{ .width = 400, .height = 200 }, &damage);

    var bytes: [64 * 1024]u8 align(4) = undefined;

    var list = draw.List{

        .bytes = &bytes,
        .width = 400,
        .height = 200,

    };

    shown.paint(&list, .{ .focus = &shown }, 0);

    var numbers: usize = 0;
    var keywords: usize = 0;
    var commands = draw.iterate(list.commands());

    while (commands.next()) |command| switch (command) {

        .text => |run| {

            const gutter = run.color == theme.faint or run.color == theme.muted;

            if (std.fmt.parseInt(usize, run.string, 10)) |_| numbers += @intFromBool(gutter) else |_| {}
            if (std.mem.eql(u8, run.string, "const") and run.color == theme.syntax.keyword) keywords += 1;

        },
        else => {},

    };

    try std.testing.expectEqual(view.frame.rows, numbers);
    try std.testing.expectEqual(view.frame.rows, keywords);
    try std.testing.expect(view.frame.rows < 20);

    // Two rows down and a few columns in.
    const area = view.frame.area;
    const at = canvas.Point{

        .x = area.x + @as(i32, @intFromFloat(view.frame.cell * 3)) + 1,
        .y = area.y + view.frame.height * 2 + 1,

    };

    shown.track.?(&shown, .{ .at = at, .phase = .down });
    try std.testing.expectEqual(.{ 3, 4 }, view.position());

    // The wheel scrolls without moving the caret, and the caret coming back into view only when it moves.
    try std.testing.expect(shown.scroll.?(&shown, view.frame.height * 5));
    try std.testing.expectEqual(5, view.top.line);
    shown.paint(&list, .{ .focus = &shown }, 0);
    try std.testing.expectEqual(5, view.top.line);
    view.vertical(1, false);
    shown.paint(&list, .{ .focus = &shown }, 0);
    try std.testing.expectEqual(3, view.top.line);

}

const markdown = @import("markdown.zig");

test "Markdown blocks: headings, lists, quotes, fenced and indented code, rules, and aligned tables" {

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();

    const source =
        \\# Title #
        \\Some *text*
        \\runs on.
        \\
        \\Setext
        \\---
        \\
        \\- one
        \\  more
        \\  - nested
        \\3. three
        \\- [x] done
        \\
        \\> quoted
        \\> > deeper
        \\
        \\```zig
        \\const a = 1;
        \\
        \\```
        \\
        \\    indented
        \\
        \\***
        \\| Name | Size |
        \\| :--- | ---: |
        \\| a | 1 |
    ;

    const blocks = try markdown.parse(arena.allocator(), source);
    const kinds = [_]markdown.Block.Kind{ .heading, .paragraph, .heading, .item, .item, .item, .item, .paragraph, .paragraph, .code, .code, .rule, .table };

    try std.testing.expectEqual(kinds.len, blocks.len);

    for (kinds, blocks) |want, block| try std.testing.expectEqual(want, block.kind);

    try std.testing.expectEqualStrings("Title", blocks[0].content);
    try std.testing.expectEqualStrings("Some *text*\nruns on.", blocks[1].content);
    try std.testing.expectEqual(1, blocks[1].line);
    try std.testing.expectEqual(2, blocks[2].level);
    try std.testing.expectEqualStrings("one\nmore", blocks[3].content);
    try std.testing.expectEqual(1, blocks[4].level);
    try std.testing.expectEqual(3, blocks[5].number.?);
    try std.testing.expectEqual(true, blocks[6].task.?);
    try std.testing.expectEqualStrings("done", blocks[6].content);
    try std.testing.expectEqual(1, blocks[7].quote);
    try std.testing.expectEqual(2, blocks[8].quote);
    try std.testing.expectEqualStrings("zig", blocks[9].info);
    try std.testing.expectEqualStrings("const a = 1;\n\n", blocks[9].content);
    try std.testing.expectEqualStrings("indented", blocks[10].content);
    try std.testing.expectEqualSlices(markdown.Align, &.{ .left, .right }, blocks[12].columns);
    try std.testing.expectEqualStrings("| Name | Size |\n| a | 1 |", blocks[12].content);

    var cells = markdown.Cells.init("| a \\| b | c |");

    try std.testing.expectEqualStrings("a \\| b", cells.next().?);
    try std.testing.expectEqualStrings("c", cells.next().?);
    try std.testing.expectEqual(null, cells.next());

}

test "Markdown inline text splits into looks, keeping escapes, intraword underscores, and lone stars as text" {

    var pieces = markdown.Pieces.init("a **b *c*** `d` [e](f) ~~g~~ x_y_z \\*h\\* 2 * 3 ![i](j) <https://k.l>\nm  \nn");
    var built: [512]u8 = undefined;
    var length: usize = 0;

    while (pieces.next()) |piece| {

        const look = piece.look;

        const tag: []const u8 = switch (piece.kind) {

            .space => "~",
            .line => "/",
            .words => if (look.image) "I" else if (look.code) "C" else if (look.link) "L" else if (look.strike) "S" else if (look.strong and look.emphasis) "BE" else if (look.strong) "B" else if (look.emphasis) "E" else "",

        };

        const written = try std.fmt.bufPrint(built[length..], "{s}<{s}>", .{ tag, piece.content });

        length += written.len;

    }

    try std.testing.expectEqualStrings("<a >B<b >BE<c>< >C<d>< >L<e>< >S<g>< x><_y><_z ><*><h><*>< 2 ><* 3 >I<i>< >L<https://k.l>~<><m  >/<><n>", built[0..length]);

}

test "Markdown previews wrap within their width, colour fenced code, and map source lines to where they show" {

    var preview = markdown.Preview.init(std.testing.allocator);

    defer preview.deinit();

    const source = "# Head\n\nword " ** 40 ++ "\n\n```zig\nconst x = 1;\n```\n\n- item\n";

    try preview.layout(source, 300);

    var lines = std.AutoHashMap(i32, void).init(std.testing.allocator);

    defer lines.deinit();

    var keyword = false;

    for (preview.items.items) |item| {

        if (item.kind != .words) continue;

        try std.testing.expect(item.area.x >= 0 and item.area.right() <= 300);
        if (std.mem.startsWith(u8, item.string, "word")) try lines.put(item.area.y, {});
        if (std.mem.eql(u8, item.string, "const") and item.color == theme.syntax.keyword) keyword = true;

    }

    try std.testing.expect(lines.count() > 4);
    try std.testing.expect(keyword);
    try std.testing.expect(preview.at(0) < preview.at(2));
    try std.testing.expect(preview.at(2) < preview.at(5));
    try std.testing.expect(preview.at(5) < preview.at(9));
    try std.testing.expect(preview.height > preview.at(9));

}
