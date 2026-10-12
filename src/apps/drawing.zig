//! Drawing: paint on a white page with a brush, lines, rectangles, ellipses, and fills, step back and forth through changes, and save PNG pictures.

const std = @import("std");

const catalog = @import("catalog.zig");

const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;
pub const panic = api.panic;

const control = api.Event.Modifiers{

    .control = true,

};
const control_shift = api.Event.Modifiers{

    .shift = true,
    .control = true,

};

const Tool = enum {

    brush,
    line,
    rectangle,
    ellipse,
    fill,
    eraser,
    picker,

};

const tool_icons = [_]gui.Icon{ .brush, .line, .rectangle, .circle, .fill, .eraser, .picker };
const tool_names = [_][]const u8{ "Brush", "Line", "Rectangle", "Ellipse", "Fill", "Eraser", "Picker" };

/// Typed letters that pick each tool.
const tool_keys = "blrofei";

const palette = [_]u32{ 0x111111, 0x7a7a7a, 0xffffff, 0xe5534b, 0xf0883e, 0xe3b341, 0x57ab5a, 0x539bf5, 0x986ee2, 0x8d5a3b };
const sizes = [_]f32{ 2, 5, 10, 20 };

const paper = 0xffffff;

/// A new page's size, and the largest picture opened.
const page = gui.Rect{

    .width = 800,
    .height = 520,

};
const largest = 4096;

/// Changes kept for undoing.
const depth = 32;

var window: gui.Window = undefined;
var files = api.Files{};
var dialog = gui.Dialog{};

/// The page, and a transparent layer over it showing the shape being dragged out.
var picture: gui.Image = undefined;
var preview: gui.Image = undefined;

var tool = Tool.brush;
var color: u32 = palette[0];
var size: usize = 1;
var modified = false;

var home_bytes: [64]u8 = undefined;
var home: []const u8 = "";
var path_bytes: [512]u8 = undefined;
var path: []const u8 = "";

/// A press is being dragged, from `start`, last seen at `last`, in page pixels; `dirty` covers what it changed.
var dragging = false;
var start = [2]f32{ 0, 0 };
var last = [2]f32{ 0, 0 };
var dirty: ?gui.Rect = null;

/// What of the preview layer holds the shape being dragged out.
var previewed: ?gui.Rect = null;

/// One change: the area it touched, as it was and as it became.
const Step = struct {

    area: gui.Rect,
    before: []u32,
    after: []u32,

};

var steps: [depth]Step = undefined;
var step_count: usize = 0;

/// Steps before this are done; those after it were undone and can be redone.
var position: usize = 0;

/// The page as it was when the current change began.
var original: []u32 = &.{};

// Toolbar: tools, colours, sizes, then history and file actions.
var tool_nodes: [tool_icons.len]gui.Node = undefined;
var swatches: [palette.len]gui.Node = undefined;
var size_dots: [sizes.len]gui.Node = undefined;
var size_dot_parts: [sizes.len][1]*gui.Node = undefined;
var size_nodes: [sizes.len]gui.Node = undefined;
var first_divider = gui.box(theme.divider, &.{});
var second_divider = gui.box(theme.divider, &.{});
var third_divider = gui.box(theme.divider, &.{});
var spring = gui.box(theme.spring, &.{});
var undo_tool = gui.tool(.undo, &undo);
var redo_tool = gui.tool(.redo, &redo);
var new_tool = gui.tool(.new, &renew);
var open_tool = gui.tool(.folder_open, &open);
var save_tool = gui.tool(.save, &save);
var bar_list: [tool_icons.len + palette.len + sizes.len + 9]*gui.Node = undefined;
var bar = gui.box(theme.bar, &bar_list);

var canvas = gui.custom(&paint, .{

    .grow = 1,
    .padding = .all(theme.spacing),

});
var status_bytes: [64]u8 = undefined;
var status = gui.label("", theme.caption.with(.{

    .grow = 1,

}));
var name_label = gui.label("", theme.caption);
var footer_parts = [_]*gui.Node{ &status, &name_label };
var footer = gui.box(.{

    .height = 28,
    .padding = .axes(0, theme.spacing),
    .direction = .row,
    .items = .center,

    .background = theme.raised,

}, &footer_parts);
var parts = [_]*gui.Node{ &bar, &canvas, &footer };
var root = gui.box(.{

    .background = 0x101010,

}, &parts);

var title_bytes: [96]u8 = undefined;

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .application);
    dialog.init();

    var argument_bytes: [256]u8 = undefined;
    const argument = api.argument(&argument_bytes);

    home = std.fmt.bufPrint(&home_bytes, "{s}", .{catalog.home(argument) orelse ""}) catch "";
    build();

    if (!(catalog.picture(argument) and load(argument))) blank(page) catch api.exit(3);

    canvas.track = &drag;
    canvas.cursor = .crosshair;

    window = gui.Window.open(&root, .{

        .title = "Drawing",
        .application = .drawing,
        .width = 900,
        .height = 640,

    }) catch api.exit(3);

    retitle();
    sync();

    while (true) {

        const event = window.next(1000) orelse continue;

        if (event.kind == .close) {

            if (!modified) window.quit();
            dialog.check(&window, "Close without saving?", "Changes to this drawing will be lost.", "Close", leave);

        }

        if (event.kind == .key and event.pressed) key(event);

    }

}

fn build() void {

    var count: usize = 0;

    for (&tool_nodes, tool_icons, 0..) |*node, icon, index| {

        node.* = gui.tool(icon, &choose_tool);
        node.data = index;
        bar_list[count] = node;
        count += 1;

    }

    bar_list[count] = &first_divider;
    count += 1;

    for (&swatches, palette, 0..) |*node, shade, index| {

        node.* = gui.box(.{

            .width = 20,
            .height = 20,

            .background = shade,
            .border = theme.faint,
            .border_width = theme.border,
            .radius = 10,

            .hover = .{

                .border = theme.text,

            },
            .selected = .{

                .border = theme.accent,

            },

        }, &.{});
        node.action = &choose_color;
        node.data = index;
        bar_list[count] = node;
        count += 1;

    }

    bar_list[count] = &second_divider;
    count += 1;

    for (&size_nodes, sizes, 0..) |*node, diameter, index| {

        const across: i32 = @intFromFloat(@min(diameter, 16));

        size_dots[index] = gui.box(.{

            .width = across,
            .height = across,

            .background = theme.text,
            .radius = @divTrunc(across, 2),

        }, &.{});
        size_dot_parts[index] = .{&size_dots[index]};
        node.* = gui.box(theme.tool.with(.{

            .justify = .center,
            .items = .center,

        }), &size_dot_parts[index]);
        node.action = &choose_size;
        node.data = index;
        bar_list[count] = node;
        count += 1;

    }

    for ([_]*gui.Node{ &third_divider, &spring, &undo_tool, &redo_tool, &new_tool, &open_tool, &save_tool }) |node| {

        bar_list[count] = node;
        count += 1;

    }

}

fn key(event: api.Event) void {

    if (dialog.open()) return;

    if (event.chord(control, 'z')) return undo(&undo_tool);
    if (event.chord(control, 'y') or event.chord(control_shift, 'z')) return redo(&redo_tool);
    if (event.chord(control, 's')) return save(&save_tool);
    if (event.chord(control, 'o')) return open(&open_tool);
    if (event.chord(control, 'n')) return renew(&new_tool);
    if (event.key() != .character or @as(u4, @bitCast(event.modifiers)) & 0b1110 != 0) return;

    switch (event.char) {

        '[' => size -|= 1,
        ']' => size = @min(size + 1, sizes.len - 1),
        else => {

            const index = std.mem.indexOfScalar(u8, tool_keys, @truncate(event.char | 0x20)) orelse return;

            tool = @enumFromInt(index);

        },

    }

    sync();

}

// The page.

/// Starts over on a white page `area` big.
fn blank(area: gui.Rect) !void {

    try adopt(try gui.Image.init(@intCast(area.width), @intCast(area.height)));

    var sketch = picture.sketch();

    sketch.clear(paper);
    try picture.publish();

}

/// Makes `fresh` the page, with an empty preview layer and history to match.
fn adopt(fresh: gui.Image) !void {

    var next = fresh;
    var layer = try gui.Image.init(next.width, next.height);

    errdefer layer.deinit();

    const copy = api.pages.alloc(u32, @as(usize, next.width) * next.height) catch {

        next.deinit();
        return error.Exhausted;

    };

    if (original.len != 0) {

        picture.deinit();
        preview.deinit();
        api.pages.free(original);

    }

    picture = next;
    preview = layer;
    original = copy;
    forget(0);
    step_count = 0;
    position = 0;
    previewed = null;
    modified = false;
    try preview.publish();

}

/// Opens the PNG at `target` as the page, over white where it is see-through; false when it cannot be read.
fn load(target: []const u8) bool {

    var arena = std.heap.ArenaAllocator.init(api.pages);
    defer arena.deinit();

    const bytes = files.load(arena.allocator(), target) catch return false;
    const dimensions = gui.png.size(bytes) catch return false;

    if (dimensions.width > largest or dimensions.height > largest) return false;

    var fresh = gui.Image.init(dimensions.width, dimensions.height) catch return false;

    _ = gui.png.decode(arena.allocator(), bytes, fresh.pixels()) catch {

        fresh.deinit();
        return false;

    };

    // Premultiplied pixels over white keep their colour and fill in the rest.
    for (fresh.pixels()) |*dot| {

        const keep = 255 - (dot.* >> 24);
        var result: u32 = 0xff000000;

        for ([_]u5{ 0, 8, 16 }) |shift| result |= @as(u32, @min((dot.* >> shift & 0xff) + keep, 255)) << shift;

        dot.* = result;

    }

    adopt(fresh) catch return false;
    picture.publish() catch return false;
    path = std.fmt.bufPrint(&path_bytes, "{s}", .{target}) catch "";

    return true;

}

/// Where the page shows within `area`: centred, and shrunk to fit if it must.
fn placed(area: gui.Rect) gui.Rect {

    const across: f32 = @floatFromInt(picture.width);
    const tall: f32 = @floatFromInt(picture.height);
    const scale = @min(@min(@as(f32, @floatFromInt(area.width)) / across, @as(f32, @floatFromInt(area.height)) / tall), 1);

    return area.centered(@intFromFloat(across * scale), @intFromFloat(tall * scale));

}

fn paint(node: *gui.Node, target: *gui.List) void {

    const area = placed(node.inner());

    if (area.width <= 0 or area.height <= 0) return;

    target.round(area.inset(-1), 2, theme.line);
    target.image(picture.handle, area);
    if (previewed != null) target.image(preview.handle, area);

}

// Drawing.

fn drag(node: *gui.Node, track: gui.Track) void {

    const area = placed(node.inner());
    const point = [2]f32{

        (@as(f32, @floatFromInt(track.at.x - area.x)) + 0.5) * @as(f32, @floatFromInt(picture.width)) / @as(f32, @floatFromInt(@max(area.width, 1))),
        (@as(f32, @floatFromInt(track.at.y - area.y)) + 0.5) * @as(f32, @floatFromInt(picture.height)) / @as(f32, @floatFromInt(@max(area.height, 1))),

    };

    const layered = previewed != null;

    switch (track.phase) {

        .down => begin(point),
        .move => if (dragging) extend(point),
        .up => if (dragging) end(point),

    }

    // Strokes reach the display as image changes alone; the window repaints only when the preview layer comes or goes.
    if (track.phase != .move or layered != (previewed != null)) window.invalidate(node);

}

fn begin(point: [2]f32) void {

    if (!inside(point)) return;

    if (tool == .picker) {

        color = picture.pixels()[pixel(point)] & 0xffffff;
        tool = .brush;

        return sync();

    }

    @memcpy(original, picture.pixels());
    dirty = null;

    if (tool == .fill) {

        flood(point);
        return commit();

    }

    dragging = true;
    start = point;
    last = point;

    if (tool == .brush or tool == .eraser) {

        var sketch = picture.sketch();

        sketch.disc(point[0], point[1], width() / 2, ink());
        touch(point, point);
        show(reach(point, point));

    }

}

fn extend(point: [2]f32) void {

    switch (tool) {

        .brush, .eraser => {

            var sketch = picture.sketch();

            sketch.line(last[0], last[1], point[0], point[1], width(), ink());
            touch(last, point);
            show(reach(last, point));
            last = point;

        },
        else => {

            var layer = preview.sketch();
            const before = previewed;

            // Only where the shape was and now is goes to the display.
            clear_preview();
            previewed = shape(&layer, start, point);
            last = point;
            preview.change(if (before) |old| old.join(previewed.?) else previewed) catch {

            };

        },

    }

}

fn end(point: [2]f32) void {

    dragging = false;

    if (tool != .brush and tool != .eraser) {

        var sketch = picture.sketch();
        const before = previewed;

        clear_preview();
        previewed = null;
        dirty = shape(&sketch, start, point);
        preview.change(before) catch {

        };
        show(dirty);

    }

    commit();

}

/// Draws the current shape tool's shape from `from` to `to` on `target`, returning the area it may have touched.
fn shape(target: *gui.Sketch, from: [2]f32, to: [2]f32) gui.Rect {

    switch (tool) {

        .line => target.line(from[0], from[1], to[0], to[1], width(), ink()),
        .rectangle => target.rectangle(.{ from[0], from[1], to[0], to[1] }, 0, width(), ink()),
        .ellipse => target.ellipse(.{ @min(from[0], to[0]), @min(from[1], to[1]), @max(from[0], to[0]), @max(from[1], to[1]) }, width(), ink()),
        else => {

        },

    }

    return reach(from, to);

}

/// Takes the last shape off the preview layer.
fn clear_preview() void {

    const area = previewed orelse return;
    const pixels = preview.pixels();

    for (0..@intCast(area.height)) |row| @memset(pixels[(@as(usize, @intCast(area.y)) + row) * preview.width + @as(usize, @intCast(area.x)) ..][0..@intCast(area.width)], 0);

}

/// Fills the run of similar colour around `point` with the current colour, as a paint bucket does.
fn flood(point: [2]f32) void {

    const pixels = picture.pixels();
    const columns: usize = picture.width;
    const rows: usize = picture.height;
    const first = pixel(point);
    const target = pixels[first];
    const replacement = (color & 0xffffff) | 0xff000000;

    // Filling with a colour this close would find its own paint again.
    if (similar(replacement, target)) return;

    var pending: std.ArrayList(u32) = .empty;
    defer pending.deinit(api.pages);

    pending.append(api.pages, @intCast(first)) catch return;

    var area: ?gui.Rect = null;

    while (pending.pop()) |next| {

        const y = next / columns;
        var left: usize = next % columns;
        var right = left;
        const row = pixels[y * columns ..][0..columns];

        if (!similar(row[left], target)) continue;

        while (left > 0 and similar(row[left - 1], target)) left -= 1;
        while (right + 1 < columns and similar(row[right + 1], target)) right += 1;

        @memset(row[left .. right + 1], replacement);

        const span = gui.Rect{

            .x = @intCast(left),
            .y = @intCast(y),
            .width = @intCast(right - left + 1),
            .height = 1,

        };

        area = if (area) |known| known.join(span) else span;

        // Each run of matching pixels just above and below needs filling too.
        for ([_]?usize{ if (y > 0) y - 1 else null, if (y + 1 < rows) y + 1 else null }) |neighbour| {

            const line = neighbour orelse continue;
            var x = left;

            while (x <= right) : (x += 1) {

                if (!similar(pixels[line * columns + x], target)) continue;

                pending.append(api.pages, @intCast(line * columns + x)) catch return;

                while (x < right and similar(pixels[line * columns + x + 1], target)) x += 1;

            }

        }

    }

    dirty = area;
    show(area);

}

/// Whether two opaque colours differ little enough to be the same area, anti-aliased edges included.
fn similar(left: u32, right: u32) bool {

    for ([_]u5{ 0, 8, 16 }) |shift| {

        const a: i32 = @intCast(left >> shift & 0xff);
        const b: i32 = @intCast(right >> shift & 0xff);

        if (@abs(a - b) > 40) return false;

    }

    return true;

}

fn inside(point: [2]f32) bool {

    return point[0] >= 0 and point[1] >= 0 and point[0] < @as(f32, @floatFromInt(picture.width)) and point[1] < @as(f32, @floatFromInt(picture.height));

}

fn pixel(point: [2]f32) usize {

    const x: usize = @intFromFloat(std.math.clamp(point[0], 0, @as(f32, @floatFromInt(picture.width - 1))));
    const y: usize = @intFromFloat(std.math.clamp(point[1], 0, @as(f32, @floatFromInt(picture.height - 1))));

    return y * picture.width + x;

}

fn ink() u32 {

    return if (tool == .eraser) paper else color;

}

fn width() f32 {

    return sizes[size] * @as(f32, if (tool == .eraser) 2 else 1);

}

/// The pixels a stroke from `from` to `to` may touch, within the page.
fn reach(from: [2]f32, to: [2]f32) gui.Rect {

    const margin = width() / 2 + 2;
    const left: i32 = @intFromFloat(@max(@floor(@min(from[0], to[0]) - margin), 0));
    const top: i32 = @intFromFloat(@max(@floor(@min(from[1], to[1]) - margin), 0));
    const right: i32 = @intFromFloat(@min(@ceil(@max(from[0], to[0]) + margin), @as(f32, @floatFromInt(picture.width))));
    const bottom: i32 = @intFromFloat(@min(@ceil(@max(from[1], to[1]) + margin), @as(f32, @floatFromInt(picture.height))));

    return .{

        .x = left,
        .y = top,
        .width = @max(right - left, 0),
        .height = @max(bottom - top, 0),

    };

}

fn touch(from: [2]f32, to: [2]f32) void {

    const area = reach(from, to);

    dirty = if (dirty) |known| known.join(area) else area;

}

/// Hands the display what changed on the page: `area`, or all of it when null.
fn show(area: ?gui.Rect) void {

    picture.change(area) catch {

    };

}

// History.

/// Records what the change just made touched, so it can be undone.
fn commit() void {

    const area = (dirty orelse return).intersect(.{

        .width = @intCast(picture.width),
        .height = @intCast(picture.height),

    }) orelse return;

    const count: usize = @intCast(area.width * area.height);
    const before = api.pages.alloc(u32, count) catch return;
    const after = api.pages.alloc(u32, count) catch {

        api.pages.free(before);
        return;

    };

    take(original, area, before);
    take(picture.pixels(), area, after);

    // A new change drops whatever was undone, and the oldest change once full.
    forget(position);

    if (step_count == depth) {

        free(steps[0]);
        std.mem.copyForwards(Step, steps[0 .. depth - 1], steps[1..]);
        step_count -= 1;

    }

    steps[step_count] = .{

        .area = area,
        .before = before,
        .after = after,

    };
    step_count += 1;
    position = step_count;
    dirty = null;

    if (!modified) {

        modified = true;
        retitle();

    }

    sync();

}

fn undo(_: *gui.Node) void {

    if (position == 0 or dragging) return;

    position -= 1;
    put(steps[position].before, steps[position].area);
    after_step();

}

fn redo(_: *gui.Node) void {

    if (position == step_count or dragging) return;

    put(steps[position].after, steps[position].area);
    position += 1;
    after_step();

}

fn after_step() void {

    show(null);
    modified = true;
    retitle();
    sync();

}

/// Frees the steps from `from` on.
fn forget(from: usize) void {

    for (steps[@min(from, step_count)..step_count]) |step| free(step);
    step_count = @min(step_count, from);

}

fn free(step: Step) void {

    api.pages.free(step.before);
    api.pages.free(step.after);

}

/// Copies `area` of page-sized `pixels` into `out`.
fn take(pixels: []const u32, area: gui.Rect, out: []u32) void {

    const span: usize = @intCast(area.width);

    for (0..@intCast(area.height)) |row| @memcpy(out[row * span ..][0..span], pixels[(@as(usize, @intCast(area.y)) + row) * picture.width + @as(usize, @intCast(area.x)) ..][0..span]);

}

/// Copies `saved` back over `area` of the page.
fn put(saved: []const u32, area: gui.Rect) void {

    const span: usize = @intCast(area.width);
    const pixels = picture.pixels();

    for (0..@intCast(area.height)) |row| @memcpy(pixels[(@as(usize, @intCast(area.y)) + row) * picture.width + @as(usize, @intCast(area.x)) ..][0..span], saved[row * span ..][0..span]);

}

// Toolbar and files.

fn choose_tool(node: *gui.Node) void {

    tool = @enumFromInt(node.data);
    sync();

}

fn choose_color(node: *gui.Node) void {

    color = palette[node.data];
    if (tool == .eraser or tool == .picker) tool = .brush;
    sync();

}

fn choose_size(node: *gui.Node) void {

    size = node.data;
    sync();

}

/// Marks the chosen tool, colour, and size, and says what they are.
fn sync() void {

    for (&tool_nodes, 0..) |*node, index| node.selected = index == @intFromEnum(tool);
    for (&swatches, palette) |*node, shade| node.selected = shade == color;
    for (&size_nodes, 0..) |*node, index| node.selected = index == size;

    undo_tool.style.color = if (position == 0) theme.faint else theme.text;
    redo_tool.style.color = if (position == step_count) theme.faint else theme.text;
    status.content.label = std.fmt.bufPrint(&status_bytes, "{s}  \u{00b7}  {d} px  \u{00b7}  {d} \u{00d7} {d}", .{ tool_names[@intFromEnum(tool)], @as(u32, @intFromFloat(width())), picture.width, picture.height }) catch "";
    name_label.content.label = if (path.len == 0) "Not saved yet" else std.fs.path.basename(path);
    window.refresh();

}

fn retitle() void {

    const name = if (path.len == 0) "Untitled" else std.fs.path.basename(path);

    window.retitle(std.fmt.bufPrint(&title_bytes, "{s}{s} - Drawing", .{ name, if (modified) " *" else "" }) catch "Drawing");

}

fn save(_: *gui.Node) void {

    if (path.len != 0) return write(path);

    var suggestion: [128]u8 = undefined;

    dialog.ask(&window, "Save as", std.fmt.bufPrint(&suggestion, "{s}/Drawing.png", .{home}) catch "Drawing.png", "Save", write);

}

/// Saves the page as a PNG at `target`, adding the extension when missing.
fn write(target: []const u8) void {

    var arena = std.heap.ArenaAllocator.init(api.pages);
    defer arena.deinit();

    var name_bytes: [512]u8 = undefined;
    const name = if (catalog.picture(target)) target else std.fmt.bufPrint(&name_bytes, "{s}.png", .{target}) catch return dialog.refuse("That name won't do; try another.");
    const bytes = gui.png.encode(arena.allocator(), picture.pixels(), picture.width, picture.height) catch return dialog.refuse("There isn't enough memory to save it.");

    files.save(arena.allocator(), name, bytes) catch return dialog.ask(&window, "Could not save there. Save as", name, "Save", write);

    path = std.fmt.bufPrint(&path_bytes, "{s}", .{name}) catch "";
    modified = false;
    retitle();
    sync();

}

fn open(_: *gui.Node) void {

    var suggestion: [96]u8 = undefined;

    dialog.ask(&window, "Open picture", std.fmt.bufPrint(&suggestion, "{s}/", .{home}) catch "/", "Open", read);

}

fn read(target: []const u8) void {

    if (!load(target)) return dialog.refuse("That isn't a picture this can open.");

    retitle();
    sync();

}

fn renew(_: *gui.Node) void {

    if (modified) return dialog.check(&window, "Start a new drawing?", "Unsaved changes will be lost.", "New", restart);

    restart("");

}

fn restart(_: []const u8) void {

    blank(page) catch return;
    path = "";
    retitle();
    sync();

}

fn leave(_: []const u8) void {

    window.quit();

}
