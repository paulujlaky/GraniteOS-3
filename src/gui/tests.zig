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

    for ('!'..'~' + 1) |code| {

        const glyph = face.lookup(@intCast(code));

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
