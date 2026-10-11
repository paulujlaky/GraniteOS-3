const std = @import("std");

const svga = @import("svga.zig");
const gpu = @import("gpu.zig");
const motion = @import("motion.zig");

const api = @import("api");
const gui = @import("gui");

const protocol = api.protocol;
const theme = gui.theme;
pub const panic = api.panic;

/// The mode until an administrator picks another, which is then saved in `saved`.
const default = gui.Rect{

    .width = 1280,
    .height = 800,

};

// The desktop is laid out for at least this much room.
const smallest = gui.Rect{

    .width = 640,
    .height = 480,

};

// No window shrinks below this, so its title bar keeps room for its controls.
const least = gui.Rect{

    .width = 200,
    .height = 100,

};

const saved = "/system/display";

const arrow = [_]*const [12]u8{

    "X...........",
    "XX..........",
    "XOX.........",
    "XOOX........",
    "XOOOX.......",
    "XOOOOX......",
    "XOOOOOX.....",
    "XOOOOOOX....",
    "XOOOOOOOX...",
    "XOOOOOOOOX..",
    "XOOOOOOOOOX.",
    "XOOOOOOXXXXX",
    "XOOOXOOX....",
    "XOOX.XOOX...",
    "XOX..XOOX...",
    "XX....XOOX..",
    "X.....XOOX..",
    ".......XX...",

};

/// The boot framebuffer, drawn by the CPU with a software pointer.
const Frame = struct {

    pixels: [*]u32,
    stride: usize,

    /// Bit positions of red, green, and blue.
    shifts: [3]u5,

    fn present(self: *Frame, source: *const gui.Canvas, area: gui.Rect) void {

        const visible = area.intersect(source.bounds()) orelse return;
        var line: [256]u32 = undefined;
        var y: usize = @intCast(visible.y);

        while (y < visible.bottom()) : (y += 1) {

            var x: usize = @intCast(visible.x);

            // Composing in RAM writes each device pixel once, so the pointer never flickers.
            while (x < visible.right()) {

                const row = line[0..@min(line.len, @as(usize, @intCast(visible.right())) - x)];

                for (row, source.pixels[y * source.width + x ..][0..row.len]) |*pixel, color| pixel.* = self.convert(color);
                self.overlay(row, x, y);
                @memcpy(self.pixels[y * self.stride + x ..][0..row.len], row);
                x += row.len;

            }

        }

    }

    fn overlay(self: *Frame, row: []u32, x: usize, y: usize) void {

        const line = @as(i64, @intCast(y)) - pointer.y;
        if (line < 0 or line >= arrow.len) return;

        for (arrow[@intCast(line)], 0..) |shape, column| {

            const offset = pointer.x + @as(i64, @intCast(column)) - @as(i64, @intCast(x));
            if (shape == '.' or offset < 0 or offset >= row.len) continue;

            row[@intCast(offset)] = self.convert(if (shape == 'X') 0x000000 else 0xffffff);

        }

    }

    fn convert(self: *const Frame, color: u32) u32 {

        return (color >> 16 & 0xff) << self.shifts[0] | (color >> 8 & 0xff) << self.shifts[1] | (color & 0xff) << self.shifts[2];

    }

};

const Screen = union(enum) {

    svga: svga.Device,
    frame: Frame,

};

const Layer = api.display.Layer;
const none = api.display.Spec.none;

const border = 1;

/// The invisible band around a window that grabs its edges for resizing.
const grip = 6;

/// How far a window's shadow spreads past its frame.
const spread = 16;

/// The radius of a window's content corners, inside its frame's border.
const curve = theme.corner - border;

/// Width of each control at the right of a title bar.
const control = 40;

/// A client's window: drawing commands it shares with us, stacked with the others.
const Surface = struct {

    client: u64 = 0,
    memory: api.Shared = undefined,
    area: gui.Rect = .{},

    layer: Layer = .window,
    options: api.display.Options = .{},
    application: u8 = none,
    title: [64]u8 = undefined,
    length: usize = 0,

    /// Which half of the shared buffer holds the presented commands, and how many bytes of them.
    half: u1 = 0,
    size: usize = 0,

    /// Presented at least once; until then nothing of it shows.
    shown: bool = false,

    minimized: bool = false,
    maximized: bool = false,

    /// Where a maximised window goes back to.
    restore: gui.Rect = .{},

    /// How it comes and goes, the transition it is in, if any, and the pose it shows in.
    effect: api.display.Motion = .auto,
    transition: ?motion.Transition = null,
    pose: motion.Pose = .rest,

    /// The screen it covered when last drawn in transition.
    painted: gui.Rect = .{},

    /// Closed by its client, and only showing until its leaving transition ends.
    leaving: bool = false,

    fn decorated(self: *const Surface) bool {

        return self.layer == .window;

    }

    /// The content plus its decorations.
    fn frame(self: *const Surface) gui.Rect {

        if (!self.decorated()) return self.area;

        return outline(self.area);

    }

    /// Everything it may draw on: the frame and its shadow.
    fn footprint(self: *const Surface) gui.Rect {

        return if (self.decorated()) self.frame().inset(-spread) else self.area;

    }

    /// Where the pointer reaches it, edges included.
    fn reach(self: *const Surface) gui.Rect {

        return if (self.resizable()) self.frame().inset(-grip) else self.frame();

    }

    fn resizable(self: *const Surface) bool {

        return self.decorated() and !self.options.fixed and !self.maximized;

    }

    /// Showing and taking input.
    fn visible(self: *const Surface) bool {

        return self.client != 0 and self.shown and !self.minimized and !self.leaving;

    }

    /// On the screen, if only for the rest of a transition.
    fn drawn(self: *const Surface) bool {

        return self.client != 0 and self.shown and (!self.minimized or self.transition != null);

    }

    /// Its motion, with `auto` settled: windows zoom, and everything else shows at once.
    fn movement(self: *const Surface) api.display.Motion {

        if (self.effect != .auto) return self.effect;

        return if (self.decorated() and !self.options.fill) .zoom else .none;

    }

    // A client may rewrite these bytes at any moment; the reader checks every command, and only this window suffers.
    fn commands(self: *const Surface) []const u8 {

        const half = self.memory.bytes.len / 2;

        return self.memory.bytes[@as(usize, self.half) * half ..][0..self.size];

    }

    fn name(self: *const Surface) []const u8 {

        return self.title[0..self.length];

    }

};

/// An event waiting for a client, and which of its surfaces it is for.
const Item = struct {

    surface: u8,
    event: api.Event,

};

/// A process with surfaces: its undelivered input, oldest at `head`, and whether it waits for more.
const Client = struct {

    id: u64 = 0,
    events: [128]Item = undefined,
    head: usize = 0,
    queued: usize = 0,
    waiting: ?api.Request = null,

    /// Input was dropped because the client stopped reading; logged once.
    behind: bool = false,

};

/// Pixels a client shared for image commands.
const Picture = struct {

    client: u64 = 0,
    handle: u64 = 0,
    memory: api.Shared = undefined,
    canvas: gui.Canvas = undefined,

};

/// What a press on a window's frame grabbed.
const Part = enum {

    content,
    title,
    minimize,
    maximize,
    close,
    edge,

};

/// A window following the pointer: moved by its title bar, or resized by the `edges` it was grabbed by.
const Grab = struct {

    index: usize,
    start: gui.Point,
    origin: gui.Rect,
    edges: Edges = .{},

};

const Edges = packed struct(u4) {

    left: bool = false,
    right: bool = false,
    top: bool = false,
    bottom: bool = false,

};

/// A control on a title bar under the pointer, or pressed.
const Hot = struct {

    index: usize,
    part: Part,

};

var settings: *const api.abi.Environment = undefined;
var screen: Screen = undefined;
var back: gui.Canvas = undefined;
var backing: ?api.Shared = null;
var files = api.Files{};

var renderer: ?gpu.Gpu = null;

var surfaces = [_]Surface{.{}} ** 64;
var clients = [_]Client{.{}} ** 32;
var pictures = [_]Picture{.{}} ** gpu.textures;

/// Surface indices bottom to top, grouped by layer.
var stack: [surfaces.len]usize = undefined;
var depth: usize = 0;

/// The window keys go to unless an overlay is up.
var focused: ?usize = null;

var grabbed: ?Grab = null;
var hot: ?Hot = null;
var armed: ?Hot = null;

/// The surface a press landed in, which keeps the pointer until release.
var capture: ?usize = null;

/// The surface last sent a pointer position.
var hovered: ?usize = null;

/// The last press on a title bar, to spot a double-click.
var titled: ?usize = null;
var titled_at: u64 = 0;

var pointer = gui.Point{};
var buttons: u8 = 0;
var modifiers = api.Event.Modifiers{};

/// Rows at the top and bottom of the screen the session keeps for its bars.
var reserved = [2]i32{ 0, 0 };

/// The window list changed since the session last heard.
var changed = false;

/// The part of the screen to redraw before waiting for the next request.
var stale: gui.Rect = .{};

/// The rounded window corners a redraw lays over the GPU's frame.
var patches: [2 * surfaces.len]gui.Rect = undefined;

var clipboard: [64 * 1024]u8 = undefined;
var copied: usize = 0;

/// The client whose commands are being drawn, so its image commands find only its own images.
var drawing: u64 = 0;

var chrome: [2048]u8 align(4) = undefined;
var kept: gui.Corners = .{};
var listed: [surfaces.len]api.display.Window = undefined;

var sweep: u64 = 0;

pub export fn app_main(_: usize, base: usize, environment: *const api.abi.Environment, geometry: usize, shifts: usize) callconv(.c) noreturn {

    api.start(environment, .service);
    if (!api.permits(.memory) or api.permits(.management)) api.exit(2);

    settings = environment;

    // The supervisor waits on our handshake, so answer it before asking the files service for the saved mode.
    greet();

    const wanted = load() orelse default;

    if (!open(wanted) and !open(default)) framebuffer(base, geometry, shifts);

    pointer = .{

        .x = @divTrunc(@as(i32, @intCast(back.width)), 2),
        .y = @divTrunc(@as(i32, @intCast(back.height)), 2),

    };

    switch (screen) {

        .svga => |*device| {

            device.point(pointer);
            api.log(if (renderer != null) "display: ready (svga, 3D on)\n" else if (device.accelerated) "display: ready (svga, 3D failed)\n" else "display: ready (svga, 3D off)\n");

        },
        .frame => api.log("display: ready (framebuffer)\n"),

    }

    compose(back.bounds());

    while (true) {

        // Everything the last request changed draws once, after its answer let the client carry on.
        const moving = animate();

        redraw();

        // While something moves, waiting for a request must not stall its next pose, a tick away.
        const request = api.receive(!moving) catch {

            if (moving) api.sleep(1);
            continue;

        };

        if (respond(request)) |result| api.reply(request, result) catch {

        };

        announce();

        // ponytail: exited clients are pruned on the next request; add a timer if an idle screen must drop them.
        if (api.ticks() >= sweep) prune();

    }

}

/// Answers the supervisor's `hello`; nothing else should arrive before it.
fn greet() void {

    while (true) {

        const request = api.receive(true) catch continue;
        const hello = protocol.operation(request.second) == .hello;

        api.reply(request, if (hello) protocol.version else protocol.invalid) catch {

        };

        if (hello) return;

    }

}

/// Takes over the SVGA adapter at `size`, drawing on its GPU when it has one; false when the adapter cannot show it.
fn open(size: gui.Rect) bool {

    const width: u32 = @intCast(size.width);
    const height: u32 = @intCast(size.height);
    const device = svga.Device.init(&settings.bars, width, height) orelse return false;

    screen = .{

        .svga = device,

    };

    const memory = api.share((width * height * 4 + 4095) / 4096) catch return false;

    if (!screen.svga.bind(memory.bytes, width * 4)) {

        api.detach(memory.handle);
        return false;

    }

    adopt(memory, size);

    var cursor: [arrow.len * arrow[0].len]u32 = undefined;

    for (arrow, 0..) |row, y| {

        for (row, 0..) |shape, x| cursor[y * row.len + x] = switch (shape) {

            'X' => 0xff000000,
            'O' => 0xffffffff,
            else => 0,

        };

    }

    screen.svga.shape(&cursor, arrow[0].len, arrow.len, .{});
    screen.svga.point(pointer);

    if (renderer) |*old| old.release();
    renderer = gpu.Gpu.init(&screen.svga, width, height);

    // A new device forgot every texture, so images go back up.
    if (renderer) |*drawer| {

        for (&pictures, 0..) |*picture, slot| {

            if (picture.client != 0) drawer.upload(slot, picture.canvas.pixels, @intCast(picture.canvas.width), @intCast(picture.canvas.height));

        }

    }

    return true;

}

/// Falls back to the boot framebuffer, drawn by the CPU at whatever mode the firmware left.
fn framebuffer(base: usize, geometry: usize, shifts: usize) void {

    if (base == 0) api.exit(3);

    const height = geometry >> 16 & 0xffff;
    const stride = geometry >> 32;
    const mapped = api.map(base, stride * height * 4) catch api.exit(3);
    const size = gui.Rect{

        .width = @intCast(geometry & 0xffff),
        .height = @intCast(height),

    };

    screen = .{

        .frame = .{

            .pixels = @ptrCast(@alignCast(mapped)),
            .stride = stride,
            .shifts = .{ @intCast(shifts & 0xff), @intCast(shifts >> 8 & 0xff), @intCast(shifts >> 16 & 0xff) },

        },

    };

    adopt(api.share((@as(usize, @intCast(size.width * size.height)) * 4 + 4095) / 4096) catch api.exit(3), size);

}

/// Makes `memory` the CPU's copy of a `size` screen, freeing the last one.
fn adopt(memory: api.Shared, size: gui.Rect) void {

    if (backing) |old| api.detach(old.handle);

    const count: usize = @intCast(size.width * size.height);

    backing = memory;
    back = .{

        .pixels = std.mem.bytesAsSlice(u32, memory.bytes[0 .. count * 4]),
        .width = @intCast(size.width),
        .height = @intCast(size.height),

    };

}

/// Switches to a `width` by `height` mode for an administrator, then tells every window.
fn mode(request: api.Request, value: u64) u64 {

    if (!api.sender(request).admin) return protocol.denied;
    if (screen != .svga) return protocol.invalid;

    const size = gui.Rect{

        .width = @intCast(value & 0xffff),
        .height = @intCast(value >> 16 & 0xffff),

    };
    const previous = back.bounds();

    if (size.width < smallest.width or size.height < smallest.height or !screen.svga.fits(@intCast(size.width), @intCast(size.height))) return protocol.invalid;
    if (!open(size) and !open(previous)) api.exit(3);
    if (back.width != size.width or back.height != size.height) return protocol.invalid;

    settle();
    compose(back.bounds());
    save(size);

    return 0;

}

/// Keeps the pointer and every title bar on the new screen, and resizes what follows the screen.
fn settle() void {

    const width: i32 = @intCast(back.width);
    const height: i32 = @intCast(back.height);

    pointer = .{

        .x = @min(pointer.x, width - 1),
        .y = @min(pointer.y, height - 1),

    };

    for (&surfaces, 0..) |*surface, index| {

        // Transitions were drawn for the old screen, so they end at once.
        if (surface.transition != null) conclude(index);
        if (surface.client == 0 or surface.leaving) continue;

        if (surface.options.fill) {

            reshape(index, back.bounds());

        } else if (surface.maximized) {

            reshape(index, inside(work()));

        } else if (surface.decorated()) {

            surface.area.x = std.math.clamp(surface.area.x, theme.title - surface.area.width, width - theme.title);
            surface.area.y = std.math.clamp(surface.area.y, work().y + theme.title, height - border);

        }

    }

}

fn load() ?gui.Rect {

    const bytes = files.read(saved, 0, 4) catch return null;
    if (bytes.len != 4) return null;

    const value = std.mem.readInt(u32, bytes[0..4], .little);
    const size = gui.Rect{

        .width = @intCast(value & 0xffff),
        .height = @intCast(value >> 16),

    };

    return if (size.width >= smallest.width and size.height >= smallest.height) size else null;

}

fn save(size: gui.Rect) void {

    const value: u32 = @intCast(size.width | size.height << 16);

    files.directory("/system") catch {

    };
    files.create(saved) catch {

    };
    files.write(saved, 0, &std.mem.toBytes(std.mem.nativeToLittle(u32, value))) catch api.log("display: could not save the mode\n");

}

/// Returns the reply, or null when the request waits for input.
fn respond(request: api.Request) ?u64 {

    const value = protocol.value(request.second);

    return switch (protocol.operation(request.second)) {

        .hello => protocol.version,
        .info => back.width | back.height << 16,
        .surface => attach(request, value),
        .place => place(request, value),
        .mode => mode(request, value),
        .present => present(request, value),
        .wait => wait(request),
        .input => input(request),
        .windows => windows(request),
        .activate => activate(request, value),
        .reserve => reserve(request, value),
        .image => image(request, value),
        .forget => forget(request, value),
        .clipboard => paste(request, value),
        .capture => snapshot(request),
        .crash => if (request.first == api.raw(.owner, 0, 0, 0).first) fault() else protocol.invalid,
        else => protocol.invalid,

    };

}

fn attach(request: api.Request, region: u64) u64 {

    const spec = fetch(request, api.display.Spec) orelse return protocol.invalid;
    var area = rect(spec.area);

    if (!fits(area)) return protocol.invalid;
    if (!allowed(request.first, spec.layer)) return protocol.denied;
    if (client(request.first) == null) return protocol.full;

    const index = for (&surfaces, 0..) |*surface, slot| {

        if (surface.client == 0) break slot;

    } else return protocol.full;

    const memory = api.attach(region) catch return protocol.denied;

    if (memory.bytes.len < 2 * 4096) {

        api.detach(memory.handle);
        return protocol.invalid;

    }

    if (spec.options.fill) area = back.bounds();
    if (spec.layer == .window) area = arrival(area);

    const surface = &surfaces[index];

    surface.* = .{

        .client = request.first,
        .memory = memory,
        .area = area,
        .layer = spec.layer,
        .options = spec.options,
        .application = spec.application,
        .effect = spec.motion,

    };
    name(surface, spec);
    insert(index);
    if (spec.layer != .background) focus(index);

    // A window that had to shrink to fit learns its size before it first draws.
    if (area.width != spec.area.width or area.height != spec.area.height) tell(index);

    changed = true;

    return index;

}

/// Moves, resizes, restacks, or retitles a surface; a placement with no area drops it.
fn place(request: api.Request, id: u64) u64 {

    const surface = owned(request, id) orelse return protocol.invalid;
    const spec = fetch(request, api.display.Spec) orelse return protocol.invalid;
    const index: usize = @intCast(id);

    if (spec.area.width == 0 and spec.area.height == 0) {

        close(index);
        return 0;

    }

    var area = rect(spec.area);

    if (!fits(area)) return protocol.invalid;
    if ((spec.layer == .window) != surface.decorated()) return protocol.invalid;
    if (!allowed(request.first, spec.layer)) return protocol.denied;

    // The window manager owns where windows sit; apps may only change their size.
    if (surface.decorated()) {

        area.x = surface.area.x;
        area.y = surface.area.y;
        if (surface.maximized) area = surface.area;

    }

    const before = surface.footprint();

    surface.area = area;
    surface.layer = spec.layer;
    surface.effect = spec.motion;
    name(surface, spec);
    remove(index);
    insert(index);
    if (spec.layer == .overlay) focus(index);
    compose(before.join(surface.footprint()));
    changed = true;

    return 0;

}

/// Shows the commands a client finished writing into one half of its buffer.
fn present(request: api.Request, value: u64) u64 {

    const surface = owned(request, value & 0xff) orelse return protocol.invalid;
    const length = value >> 9;

    if (length > surface.memory.bytes.len / 2) return protocol.invalid;

    surface.half = @intCast(value >> 8 & 1);
    surface.size = length;

    // A surface's first frame plays it in.
    if (!surface.shown) {

        surface.shown = true;
        if (motion.away(surface.movement())) |away| _ = begin(@intCast(value & 0xff), .enter, away.pose, .rest, away.length);

    }

    if (!surface.minimized) compose(surface.footprint());

    return 0;

}

fn wait(request: api.Request) ?u64 {

    const owner = client(request.first) orelse return protocol.full;

    owner.waiting = request;
    deliver(owner);

    return null;

}

/// Session only: describes every window, bottom to top.
fn windows(request: api.Request) u64 {

    if (request.first != session()) return protocol.denied;

    var count: usize = 0;

    for (stack[0..depth]) |index| {

        const surface = &surfaces[index];
        if (!surface.decorated() or surface.leaving) continue;

        listed[count] = .{

            .id = @intCast(index),
            .application = surface.application,
            .state = .{

                .focused = focused == index,
                .minimized = surface.minimized,
                .maximized = surface.maximized,

            },
            .length = @intCast(surface.length),
            .title = surface.title,

        };
        count += 1;

    }

    const bytes = std.mem.sliceAsBytes(listed[0..@min(count, request.fourth / @sizeOf(api.display.Window))]);

    api.store(request, 0, bytes) catch return protocol.invalid;

    return count;

}

/// Session only: raises, minimises, or closes another client's window.
fn activate(request: api.Request, value: u64) u64 {

    if (request.first != session()) return protocol.denied;

    const index = value & 0xffffffff;
    if (index >= surfaces.len or surfaces[index].client == 0 or surfaces[index].leaving or !surfaces[index].decorated()) return protocol.invalid;

    switch (std.enums.fromInt(api.display.Action, value >> 32) orelse return protocol.invalid) {

        .raise => {

            // A minimised window flies back from wherever its minimising left it.
            if (surfaces[index].minimized) {

                surfaces[index].minimized = false;
                _ = begin(index, .restore, null, .rest, motion.tuck);

            }

            raise(index);
            focus(index);

        },
        .minimize => minimize(index),
        .close => queue(index, .{

            .kind = .close,

        }),
        _ => return protocol.invalid,

    }

    changed = true;

    return 0;

}

/// Session only: keeps rows at the top and bottom of the screen for its bars.
fn reserve(request: api.Request, value: u64) u64 {

    if (request.first != session()) return protocol.denied;

    const top: i32 = @intCast(value & 0xffff);
    const bottom: i32 = @intCast(value >> 16 & 0xffff);

    if (top + bottom > @divTrunc(@as(i32, @intCast(back.height)), 2)) return protocol.invalid;

    reserved = .{ top, bottom };

    for (&surfaces, 0..) |*surface, index| {

        if (surface.client != 0 and surface.maximized and !surface.leaving) reshape(index, inside(work()));

    }

    return 0;

}

/// Takes in, or refreshes, pixels a client shared for image commands.
fn image(request: api.Request, handle: u64) u64 {

    const size = fetch(request, [2]u32) orelse return protocol.invalid;
    const width = size[0];
    const height = size[1];

    if (width == 0 or height == 0 or width > 8192 or height > 8192) return protocol.invalid;

    var slot = find(request.first, handle);

    if (slot == null) {

        slot = for (&pictures, 0..) |*picture, index| {

            if (picture.client == 0) break index;

        } else return protocol.full;

        const memory = api.attach(handle) catch return protocol.denied;

        pictures[slot.?] = .{

            .client = request.first,
            .handle = handle,
            .memory = memory,

        };

    }

    const picture = &pictures[slot.?];

    if (picture.memory.bytes.len < @as(usize, width) * height * 4) {

        discard(slot.?);
        return protocol.invalid;

    }

    picture.canvas = .{

        .pixels = std.mem.bytesAsSlice(u32, picture.memory.bytes[0 .. @as(usize, width) * height * 4]),
        .width = width,
        .height = height,

    };

    if (renderer) |*device| device.upload(slot.?, picture.canvas.pixels, width, height);

    // Whatever shows the image draws it afresh.
    for (stack[0..depth]) |index| {

        if (surfaces[index].client == request.first and surfaces[index].visible()) compose(surfaces[index].footprint());

    }

    return 0;

}

fn forget(request: api.Request, handle: u64) u64 {

    discard(find(request.first, handle) orelse return protocol.invalid);

    return 0;

}

/// Copies into (`value` 1) or out of (`value` 0) the clipboard shared by every app.
fn paste(request: api.Request, value: u64) u64 {

    if (value == 1) {

        const length = @min(request.fourth, clipboard.len);

        api.fetch(request, 0, clipboard[0..length]) catch return protocol.invalid;
        copied = length;

        return 0;

    }

    const length = @min(copied, request.fourth);

    api.store(request, 0, clipboard[0..length]) catch return protocol.invalid;

    return length;

}

/// Marks `area` of the screen for redrawing once the current request is answered, so a burst of changes draws once.
fn compose(area: gui.Rect) void {

    stale = stale.join(area);

}

/// Redraws what `compose` marked, from the surface stack, bottom to top, on the GPU when there is one.
fn redraw() void {

    const visible = stale.intersect(back.bounds()) orelse return;

    stale = .{};

    if (renderer) |*device| {

        device.begin(visible);

        for (stack[0..depth]) |index| {

            const surface = &surfaces[index];
            if (!surface.drawn()) continue;

            if (surface.transition != null) {

                float(device, index, visible);

            } else if (surface.footprint().intersect(visible)) |limit| {

                layers(device, index, limit);

            }

        }

        // The GPU cannot cut to a curve, so the CPU redraws the few pixels at windows' rounded corners and lays them over; it cannot draw moving surfaces, so none goes near them.
        var count: usize = 0;

        for (stack[0..depth]) |index| {

            const surface = &surfaces[index];
            if (!surface.visible() or !surface.decorated() or surface.transition != null) continue;

            const corners = gui.Corners{

                .area = surface.area,
                .radius = curve,

            };

            for (corners.squares()) |square| {

                patches[count] = square.intersect(visible) orelse continue;
                if (crowded(patches[count])) continue;
                paint(patches[count]);
                count += 1;

            }

        }

        device.patch(&back, patches[0..count]);

        return device.finish(visible);

    }

    switch (screen) {

        .svga => |*device| device.idle(),
        .frame => {

        },

    }

    paint(visible);

    switch (screen) {

        .svga => |*device| device.present(visible),
        .frame => |*frame| frame.present(&back, visible),

    }

}

/// Queues surface `index`'s decorations and content within `limit` on the GPU.
fn layers(device: *gpu.Gpu, index: usize, limit: gui.Rect) void {

    const surface = &surfaces[index];
    const decorations = trim(index);

    drawing = 0;
    device.render(decorations.commands(), corner(surface.footprint()), limit, texture);
    drawing = surface.client;
    if (surface.area.intersect(limit)) |inside_limit| device.render(surface.commands(), corner(surface.area), inside_limit, texture);

}

/// Queues surface `index` mid-transition: drawn whole into the GPU's layer, then laid on the frame in its pose.
fn float(device: *gpu.Gpu, index: usize, visible: gui.Rect) void {

    const surface = &surfaces[index];
    if (surface.painted.intersect(visible) == null) return;

    const footprint = surface.footprint();
    const whole = footprint.intersect(back.bounds()) orelse return;

    device.lift(whole);
    layers(device, index, whole);

    // As `paint` does on the CPU, content is cut to the curve of the frame's bottom corners, and the frame fills in beneath.
    if (surface.decorated()) {

        const corners = gui.Corners{

            .area = surface.area,
            .radius = curve,

        };
        const decorations = trim(index);

        device.cut(surface.area, curve);
        device.blending(.under);
        drawing = 0;

        for (corners.squares()) |square| {

            if (square.intersect(whole)) |limit| device.render(decorations.commands(), corner(footprint), limit, texture);

        }

        device.blending(.over);

    }

    device.lower(whole, surface.pose.box(whole, footprint), surface.pose.opacity, visible);

}

/// Whether `area` meets a surface in transition.
fn crowded(area: gui.Rect) bool {

    for (stack[0..depth]) |index| {

        if (surfaces[index].transition != null and surfaces[index].painted.intersect(area) != null) return true;

    }

    return false;

}

/// Draws `visible` of the screen into the CPU's copy, bottom surface first; surfaces in transition are the GPU's alone.
fn paint(visible: gui.Rect) void {

    back.fill(visible, theme.desktop);

    for (stack[0..depth]) |index| {

        const surface = &surfaces[index];
        if (!surface.visible() or surface.transition != null or surface.footprint().intersect(visible) == null) continue;

        const decorations = trim(index);

        drawing = 0;
        if (surface.footprint().intersect(visible)) |limit| gui.draw.replay(&back, decorations.commands(), corner(surface.footprint()), limit, pixels);
        drawing = surface.client;
        if (surface.area.intersect(visible)) |limit| {

            // A window's content is cut to the curve of its frame's bottom corners.
            back.save(&kept, surface.area, if (surface.decorated()) curve else 0, limit);
            gui.draw.replay(&back, surface.commands(), corner(surface.area), limit, pixels);
            back.trim(&kept);

        }

    }

}

/// Session only: draws the whole screen on the CPU and copies it, 0x00RRGGBB row after row, into the lent window; returns its size.
fn snapshot(request: api.Request) u64 {

    if (request.first != session()) return protocol.denied;

    const bytes = std.mem.sliceAsBytes(back.pixels);
    var offset: usize = 0;

    if (request.fourth < bytes.len) return protocol.invalid;

    // A GPU-drawn screen leaves the CPU's copy stale, so it is drawn afresh.
    if (renderer != null) paint(back.bounds());

    while (offset < bytes.len) : (offset += 0x10000) {

        api.store(request, offset, bytes[offset..][0..@min(0x10000, bytes.len - offset)]) catch return protocol.invalid;

    }

    return back.width | back.height << 16;

}

/// Takes the events the input service lends in its window and hands them to surfaces.
fn input(request: api.Request) u64 {

    // Only services run as the system, so clients cannot forge another surface's input.
    if (api.sender(request).user != api.abi.system.user) return protocol.denied;

    var events: [64]api.Event = undefined;
    const count = @min(request.fourth / @sizeOf(api.Event), events.len);

    api.fetch(request, 0, std.mem.sliceAsBytes(events[0..count])) catch return protocol.invalid;
    for (events[0..count]) |event| route(event);

    for (&clients) |*owner| {

        if (owner.id != 0) deliver(owner);

    }

    return 0;

}

fn route(event: api.Event) void {

    switch (event.kind) {

        .key => {

            modifiers = event.modifiers;

            // Super chords are the desktop's, whichever window has the keyboard.
            const target = keyboard();
            const owner = session();

            if (event.modifiers.super and owner != 0 and (target == null or surfaces[target.?].client != owner)) {

                for (stack[0..depth]) |index| {

                    if (surfaces[index].client == owner and !surfaces[index].leaving) return queue(index, event);

                }

            }

            if (target) |index| queue(index, event);

        },
        .motion, .pointer => {

            const width: i32 = @intCast(back.width);
            const height: i32 = @intCast(back.height);

            // Relative motion comes from a mouse; absolute positions span 0..32767 across the screen.
            if (event.kind == .motion) {

                if (event.x != 0 or event.y != 0) move(pointer.x + event.x, pointer.y + event.y);

            } else {

                move(@divTrunc(@as(i32, event.x) * width, 32768), @divTrunc(@as(i32, event.y) * height, 32768));

            }

            track();
            press(event.code);

        },
        .button => if (event.code >= 3) {

            const index = under(pointer) orelse return;
            if (!surfaces[index].area.contains(pointer)) return;

            queue(index, local(index, .{

                .kind = .button,
                .pressed = true,
                .code = event.code,
                .modifiers = modifiers,

            }));

        },
        else => {

        },

    }

}

/// Follows the pointer: drags or resizes a grabbed window, else tells the surfaces under it where it is.
fn track() void {

    if (grabbed) |held| return follow(held);

    const target = capture orelse under(pointer);

    // The surface the pointer left hears a position outside itself, so it drops its hover.
    if (hovered != target) if (hovered) |old| if (surfaces[old].client != 0) queue(old, local(old, .{

        .kind = .pointer,
        .code = buttons,

    }));

    hovered = target;

    const next: ?Hot = if (target) |index| if (capture == null) .{

        .index = index,
        .part = part(index, pointer),

    } else null else null;

    if (!std.meta.eql(next, hot)) {

        const previous = hot;

        hot = next;
        for ([_]?Hot{ previous, next }) |entry| if (entry) |spot| if (spot.part != .content) compose(surfaces[spot.index].frame());

    }

    const index = target orelse return;

    queue(index, local(index, .{

        .kind = .pointer,
        .code = buttons,

    }));

}

/// Acts on buttons that went down or up since the last event.
fn press(code: u8) void {

    const change = buttons ^ code;

    buttons = code;

    for (0..3) |button| {

        if (change >> @intCast(button) & 1 == 0) continue;

        const pressed = code >> @intCast(button) & 1 != 0;
        const event = api.Event{

            .kind = .button,
            .pressed = pressed,
            .code = @intCast(button),
            .modifiers = modifiers,

        };

        if (!pressed) {

            if (button == 0) release();
            if (capture) |index| {

                queue(index, local(index, event));
                if (button == 0) capture = null;

            }

            continue;

        }

        const index = under(pointer) orelse continue;
        const surface = &surfaces[index];

        if (button == 0) {

            if (surface.layer == .window or surface.layer == .overlay) {

                raise(index);
                focus(index);

            }

            switch (part(index, pointer)) {

                .content => capture = index,
                .title => {

                    const now = api.ticks();

                    if (titled == index and now - titled_at < 40) {

                        titled = null;
                        if (!surface.options.fixed) toggle(index);

                        continue;

                    }

                    titled = index;
                    titled_at = now;
                    grab(index, .{});

                    continue;

                },
                .edge => {

                    grab(index, edges(index, pointer));
                    continue;

                },
                else => |control_part| {

                    armed = .{

                        .index = index,
                        .part = control_part,

                    };

                    continue;

                },

            }

        } else if (!surface.area.contains(pointer)) {

            continue;

        }

        queue(index, local(index, event));

    }

}

/// Ends a drag, or runs the title bar control the press began on if the pointer is still over it.
fn release() void {

    grabbed = null;

    const pending = armed orelse return;

    armed = null;
    if (under(pointer) != pending.index or part(pending.index, pointer) != pending.part) return;

    switch (pending.part) {

        .minimize => minimize(pending.index),
        .maximize => toggle(pending.index),
        .close => queue(pending.index, .{

            .kind = .close,

        }),
        else => {

        },

    }

}

/// Starts moving window `index`, or resizing it by `sides` when any are set.
fn grab(index: usize, sides: Edges) void {

    grabbed = .{

        .index = index,
        .start = pointer,
        .origin = surfaces[index].area,
        .edges = sides,

    };

}

fn follow(grab_state: Grab) void {

    const surface = &surfaces[grab_state.index];
    const dx = pointer.x - grab_state.start.x;
    const dy = pointer.y - grab_state.start.y;
    const origin = grab_state.origin;
    const sides = grab_state.edges;
    var area = origin;

    // Dragging a maximised window by its title puts it back to its own size under the pointer, once it really moves.
    if (surface.maximized and @as(u4, @bitCast(sides)) == 0) {

        if (@abs(dx) + @abs(dy) < 6) return;

        const ratio = @as(f32, @floatFromInt(pointer.x - surface.area.x)) / @as(f32, @floatFromInt(@max(surface.area.width, 1)));

        area = surface.restore;
        area.x = pointer.x - @as(i32, @intFromFloat(ratio * @as(f32, @floatFromInt(area.width))));
        area.y = surface.area.y;
        surface.maximized = false;
        reshape(grab_state.index, area);
        changed = true;
        grab(grab_state.index, .{});

        return;

    }

    if (@as(u4, @bitCast(sides)) == 0) {

        const before = surface.footprint();

        area.x += dx;
        area.y = std.math.clamp(origin.y + dy, work().y + theme.title, @as(i32, @intCast(back.height)) - border);
        surface.area = area;
        compose(before.join(surface.footprint()));

        return;

    }

    if (sides.left) {

        area.width = @max(origin.width - dx, least.width);
        area.x = origin.x + origin.width - area.width;

    }

    if (sides.right) area.width = @max(origin.width + dx, least.width);

    if (sides.top) {

        area.height = @max(origin.height - dy, least.height);
        area.y = @max(origin.y + origin.height - area.height, work().y + theme.title);
        area.height = origin.y + origin.height - area.y;

    }

    if (sides.bottom) area.height = @max(origin.height + dy, least.height);

    reshape(grab_state.index, area);

}

/// Gives surface `index` a new area, redraws, and tells its client the new size.
fn reshape(index: usize, area: gui.Rect) void {

    const surface = &surfaces[index];
    const before = surface.footprint();
    const sized = area.width != surface.area.width or area.height != surface.area.height;

    surface.area = area;
    if (sized) tell(index);
    compose(before.join(surface.footprint()));

}

/// Maximises window `index` into the work area, or puts it back.
fn toggle(index: usize) void {

    const surface = &surfaces[index];

    if (surface.maximized) {

        surface.maximized = false;
        reshape(index, surface.restore);

    } else {

        surface.restore = surface.area;
        surface.maximized = true;
        reshape(index, inside(work()));

    }

    changed = true;

}

fn minimize(index: usize) void {

    const surface = &surfaces[index];
    if (surface.minimized) return;

    surface.minimized = true;
    if (hot != null and hot.?.index == index) hot = null;
    if (!begin(index, .minimize, null, motion.shrink(surface.footprint(), dock()), motion.tuck)) compose(surface.footprint());
    if (focused == index) refocus();
    changed = true;

}

/// Where keys go: an overlay above everything, else the focused window.
fn keyboard() ?usize {

    if (depth == 0) return null;

    const top = stack[depth - 1];
    if (surfaces[top].layer == .overlay and !surfaces[top].leaving) return top;

    const index = focused orelse return null;

    return if (surfaces[index].minimized) null else index;

}

/// Queues `event` for the client of surface `index`.
fn queue(index: usize, event: api.Event) void {

    const owner = client(surfaces[index].client) orelse return;
    const capacity = owner.events.len;
    const item = Item{

        .surface = @intCast(index),
        .event = event,

    };

    // Only the latest position or size matters, so consecutive ones collapse.
    if (owner.queued != 0) {

        const last = &owner.events[(owner.head + owner.queued - 1) % capacity];

        if (last.surface == item.surface and last.event.kind == event.kind and (event.kind == .pointer or event.kind == .resize or event.kind == .notice)) {

            last.* = item;
            return;

        }

    }

    // A client this far behind has stopped reading; its oldest input goes first.
    if (owner.queued == capacity) {

        if (!owner.behind) api.log("display: a window stopped reading input; dropping its oldest\n");
        owner.behind = true;
        owner.head = (owner.head + 1) % capacity;
        owner.queued -= 1;

    }

    owner.events[(owner.head + owner.queued) % capacity] = item;
    owner.queued += 1;

}

fn deliver(owner: *Client) void {

    const request = owner.waiting orelse return;
    if (owner.queued == 0) return;

    const item = owner.events[owner.head];
    const which: u64 = item.surface;

    owner.waiting = null;
    api.store(request, 0, std.mem.asBytes(&which)) catch {

    };

    // A timed-out wait keeps its event for the next one.
    api.reply(request, @bitCast(item.event)) catch |err| {

        if (err == error.Missing) drop(owner.id);
        return;

    };

    owner.head = (owner.head + 1) % owner.events.len;
    owner.queued -= 1;

}

/// Tells the session the window list changed, once per batch of changes.
fn announce() void {

    if (!changed) return;

    changed = false;

    const owner = session();
    if (owner == 0) return;

    for (stack[0..depth]) |index| {

        if (surfaces[index].client != owner or surfaces[index].leaving) continue;

        queue(index, .{

            .kind = .notice,
            .code = @intFromEnum(api.Event.Notice.windows),

        });
        deliver(client(owner).?);

        return;

    }

}

/// Tells surface `index`'s client its new size.
fn tell(index: usize) void {

    const area = surfaces[index].area;

    queue(index, .{

        .kind = .resize,
        .x = @intCast(area.width),
        .y = @intCast(area.height),

    });
    deliver(client(surfaces[index].client).?);

}

/// The client record for process `id`, made on first use; null when the table is full.
fn client(id: u64) ?*Client {

    for (&clients) |*owner| {

        if (owner.id == id) return owner;

    }

    for (&clients) |*owner| {

        if (owner.id != 0) continue;

        reset(owner, id);

        return owner;

    }

    return null;

}

/// Empties a client record field by field; a whole new record would cost a 2 KiB temporary on our 16 KiB stack.
fn reset(owner: *Client, id: u64) void {

    owner.id = id;
    owner.head = 0;
    owner.queued = 0;
    owner.waiting = null;
    owner.behind = false;

}

/// Puts surface `index` on top of the others in its layer.
fn insert(index: usize) void {

    const layer = @intFromEnum(surfaces[index].layer);
    var position = depth;

    while (position > 0 and @intFromEnum(surfaces[stack[position - 1]].layer) > layer) position -= 1;

    std.mem.copyBackwards(usize, stack[position + 1 .. depth + 1], stack[position..depth]);
    stack[position] = index;
    depth += 1;

}

fn remove(index: usize) void {

    const position = std.mem.indexOfScalar(usize, stack[0..depth], index) orelse return;

    std.mem.copyForwards(usize, stack[position .. depth - 1], stack[position + 1 .. depth]);
    depth -= 1;

}

fn raise(index: usize) void {

    if (stack[depth - 1] == index) return;

    remove(index);
    insert(index);
    compose(surfaces[index].footprint());
    changed = true;

}

/// Sends keys to surface `index` and repaints the title bars that changed.
fn focus(index: ?usize) void {

    const previous = focused;
    if (previous == index) return;

    focused = index;
    changed = true;

    for ([_]?usize{ previous, index }) |entry| {

        const target = entry orelse continue;

        if (surfaces[target].decorated()) compose(surfaces[target].frame());

    }

}

/// Focuses the topmost window still showing, if any.
fn refocus() void {

    var position = depth;

    while (position > 0) {

        position -= 1;

        const surface = &surfaces[stack[position]];
        if (surface.layer == .window and !surface.minimized and !surface.leaving) return focus(stack[position]);

    }

    focus(null);

}

/// Takes surface `index` out of input and focus at once, and off the screen once it has played out, if it moves.
fn close(index: usize) void {

    const surface = &surfaces[index];
    if (surface.leaving) return;

    if (grabbed != null and grabbed.?.index == index) grabbed = null;
    if (hot != null and hot.?.index == index) hot = null;
    if (armed != null and armed.?.index == index) armed = null;
    if (capture == index) capture = null;
    if (hovered == index) hovered = null;

    // Its client may already be gone, but the display's own hold keeps the commands it last presented.
    const shown = surface.visible();

    surface.leaving = true;
    changed = true;

    if (focused == index) {

        focused = null;
        refocus();

    }

    if (shown) if (motion.away(surface.movement())) |away| if (begin(index, .leave, null, away.pose, away.length)) return;

    free(index);

}

/// Frees the slot of surface `index`, closed and done showing.
fn free(index: usize) void {

    const surface = &surfaces[index];

    compose(surface.footprint().join(surface.painted));
    remove(index);
    api.detach(surface.memory.handle);
    surface.* = .{};

}

/// Starts surface `index` moving from `from`, or the pose it shows in, to `to`; false, leaving it be, without a GPU to animate it.
fn begin(index: usize, purpose: motion.Purpose, from: ?motion.Pose, to: motion.Pose, length: u64) bool {

    if (renderer == null) return false;

    const surface = &surfaces[index];

    if (from) |pose| surface.pose = pose;
    surface.transition = motion.Transition.begin(purpose, surface.pose, to, length);
    surface.painted = surface.pose.bounds(surface.footprint());
    compose(surface.painted);

    return true;

}

/// Moves every surface in transition on to its pose for this tick, and ends those done; true while any still moves.
fn animate() bool {

    const now = api.ticks();
    var moving = false;

    // By slot rather than by stack, since freeing a surface done leaving restacks.
    for (&surfaces, 0..) |*surface, index| {

        const current = surface.transition orelse continue;

        if (current.done(now)) {

            conclude(index);
            continue;

        }

        const pose = current.pose(now);
        const area = pose.bounds(surface.footprint());

        moving = true;
        if (std.meta.eql(pose, surface.pose) and std.meta.eql(area, surface.painted)) continue;

        compose(surface.painted.join(area));
        surface.pose = pose;
        surface.painted = area;

    }

    return moving;

}

/// Ends surface `index`'s transition where it was headed; one leaving is freed.
fn conclude(index: usize) void {

    const surface = &surfaces[index];
    const current = surface.transition orelse return;

    surface.transition = null;
    surface.pose = current.to;
    compose(surface.painted.join(surface.footprint()));

    if (current.purpose == .leave) free(index);

}

/// Where minimised windows fly to: the middle of the row the session keeps at the bottom for its dock.
fn dock() gui.Point {

    return .{

        .x = @divTrunc(@as(i32, @intCast(back.width)), 2),
        .y = @as(i32, @intCast(back.height)) - @divTrunc(reserved[1], 2),

    };

}

/// Forgets everything of client `id`; its surfaces still leaving play out.
fn drop(id: u64) void {

    for (&surfaces, 0..) |*surface, index| {

        if (surface.client == id) close(index);

    }

    for (&pictures, 0..) |*picture, slot| {

        if (picture.client == id) discard(slot);

    }

    for (&clients) |*owner| {

        if (owner.id == id) reset(owner, 0);

    }

}

/// Drops the surfaces and images of clients that exited.
fn prune() void {

    sweep = api.ticks() + 25;

    for (&clients) |*owner| {

        if (owner.id != 0 and !api.alive(owner.id)) drop(owner.id);

    }

    for (&pictures) |*picture| {

        if (picture.client != 0 and !api.alive(picture.client)) drop(picture.client);

    }

}

fn discard(slot: usize) void {

    if (renderer) |*device| device.discard(slot);
    api.detach(pictures[slot].memory.handle);
    pictures[slot] = .{};

}

fn find(owner: u64, handle: u64) ?usize {

    for (&pictures, 0..) |*picture, slot| {

        if (picture.client == owner and picture.handle == handle and owner != 0) return slot;

    }

    return null;

}

/// The texture slot of image `handle` of the client being drawn.
fn texture(handle: u64) ?usize {

    return find(drawing, handle);

}

/// The pixels of image `handle` of the client being drawn.
fn pixels(handle: u64) ?*const gui.Canvas {

    return &pictures[find(drawing, handle) orelse return null].canvas;

}

/// Records the shadow, title bar, and border of window `index` in footprint coordinates; empty for other layers.
fn trim(index: usize) gui.draw.List {

    const surface = &surfaces[index];
    const footprint = surface.footprint();
    var list = gui.draw.List{

        .bytes = &chrome,
        .width = footprint.width,
        .height = footprint.height,

    };

    if (!surface.decorated()) return list;

    const active = focused == index;
    const frame = gui.draw.move(surface.frame(), .{

        .x = -footprint.x,
        .y = -footprint.y,

    });

    // A soft shadow from a few widening, faint layers, a little below the frame; they add up near its edge.
    for ([_]i32{ 1, 4, 8, 13 }, [_]u8{ 14, 10, 7, 4 }) |grow, amount| {

        var layer = frame.inset(-grow);

        layer.y += 3;
        list.round(layer, grow + theme.corner, gui.shade(0x000000, if (active) amount + amount / 2 else amount));

    }

    const bar = gui.Rect{

        .x = frame.x,
        .y = frame.y,
        .width = frame.width,
        .height = theme.title,

    };

    // The title bar and its controls are the frame's rounded inside, cut to their own rectangles.
    const within = frame.inset(border);

    list.round(frame, theme.corner, if (active) theme.selected else theme.line);
    list.limit = bar.inset(border);
    list.round(within, curve, theme.raised);

    // Controls sit right to left: close, then maximise unless fixed, then minimise.
    var right = bar.right() - border;

    for ([_]Part{ .close, .maximize, .minimize }) |which| {

        if (which == .maximize and surface.options.fixed) continue;

        const spot = gui.Rect{

            .x = right - control,
            .y = bar.y + border,
            .width = control,
            .height = theme.title - border,

        };
        const lit = hot != null and hot.?.index == index and hot.?.part == which;

        if (lit) {

            list.limit = spot;
            list.round(within, curve, if (which == .close) theme.danger else theme.hover);
            list.limit = bar.inset(border);

        }
        list.icon(switch (which) {

            .close => .close,
            .maximize => .maximize,
            else => .minimize,

        }, if (which == .maximize) 12 else 15, spot, if (lit and which == .close) 0xffffff else if (active) theme.text else theme.muted);
        right -= control;

    }

    list.limit = .{

        .x = bar.x,
        .y = bar.y,
        .width = right - bar.x,
        .height = bar.height,

    };
    list.label(surface.name(), .sans, theme.small, .{

        .x = bar.x + theme.spacing,
        .y = bar.y,
        .width = right - bar.x - theme.spacing,
        .height = theme.title,

    }, if (active) theme.text else theme.muted, .left);
    list.limit = null;

    return list;

}

/// Which part of surface `index` is at `at`.
fn part(index: usize, at: gui.Point) Part {

    const surface = &surfaces[index];
    if (!surface.decorated() or surface.area.contains(at)) return .content;

    const frame = surface.frame();
    if (!frame.contains(at) or at.y >= frame.y + theme.title or at.x < frame.x + border) return if (surface.resizable()) .edge else .title;
    if (at.y < frame.y + border and surface.resizable()) return .edge;

    const slot = @divTrunc(frame.right() - border - 1 - at.x, control);
    const fixed = surface.options.fixed;

    return switch (slot) {

        0 => .close,
        1 => if (fixed) .minimize else .maximize,
        2 => if (fixed) .title else .minimize,
        else => .title,

    };

}

/// Which edges of window `index` the pointer at `at` holds; near a corner, both of its edges.
fn edges(index: usize, at: gui.Point) Edges {

    const frame = surfaces[index].frame();
    const reach = 16;

    var sides = Edges{

        .left = at.x < frame.x + border,
        .right = at.x >= frame.right() - border,
        .top = at.y < frame.y + border,
        .bottom = at.y >= frame.bottom() - border,

    };

    if (sides.left or sides.right) {

        sides.top = sides.top or at.y < frame.y + reach;
        sides.bottom = sides.bottom or at.y >= frame.bottom() - reach;

    }

    if (sides.top or sides.bottom) {

        sides.left = sides.left or at.x < frame.x + reach;
        sides.right = sides.right or at.x >= frame.right() - reach;

    }

    return sides;

}

/// The screen minus the rows the session keeps.
fn work() gui.Rect {

    return .{

        .y = reserved[0],
        .width = @intCast(back.width),
        .height = @as(i32, @intCast(back.height)) - reserved[0] - reserved[1],

    };

}

/// The content area of a window whose frame fills `area`.
fn inside(area: gui.Rect) gui.Rect {

    return .{

        .x = area.x + border,
        .y = area.y + theme.title,
        .width = area.width - 2 * border,
        .height = area.height - theme.title - border,

    };

}

/// Where a new window of `area`'s size goes: centred in the work area, stepped down from others, and shrunk to fit.
fn arrival(area: gui.Rect) gui.Rect {

    const room = inside(work());
    var count: i32 = 0;

    for (surfaces) |surface| {

        if (surface.client != 0 and surface.decorated() and !surface.leaving) count += 1;

    }

    const width = std.math.clamp(area.width, least.width, room.width);
    const height = std.math.clamp(area.height, least.height, room.height);
    const step = @mod(count, 6) * 24 - 60;
    var placed = room.centered(width, height);

    placed.x = std.math.clamp(placed.x + step, room.x, room.right() - width);
    placed.y = std.math.clamp(placed.y + step, room.y, room.bottom() - height);

    return placed;

}

fn name(surface: *Surface, spec: api.display.Spec) void {

    const title = spec.name();

    surface.length = title.len;
    @memcpy(surface.title[0..title.len], title);

}

fn outline(area: gui.Rect) gui.Rect {

    return .{

        .x = area.x - border,
        .y = area.y - theme.title,
        .width = area.width + 2 * border,
        .height = area.height + theme.title + border,

    };

}

/// The client holding the background, panels, or overlay: the signed-in session; 0 when there is none.
fn session() u64 {

    for (surfaces) |surface| {

        if (surface.client != 0 and !surface.decorated()) return surface.client;

    }

    return 0;

}

/// Background, panel, and overlay surfaces cover other windows, so only one client, the session, may hold them.
fn allowed(owner: u64, layer: Layer) bool {

    switch (layer) {

        .window => return true,
        .background, .panel, .overlay => {

        },
        _ => return false,

    }

    const holder = session();

    return holder == 0 or holder == owner;

}

fn fits(area: gui.Rect) bool {

    return area.width > 0 and area.height > 0 and area.width <= 8192 and area.height <= 8192;

}

fn under(at: gui.Point) ?usize {

    var position = depth;

    while (position > 0) {

        position -= 1;

        const surface = &surfaces[stack[position]];
        if (surface.visible() and surface.reach().contains(at)) return stack[position];

    }

    return null;

}

fn move(x: i32, y: i32) void {

    const previous = pointer;

    pointer = .{

        .x = std.math.clamp(x, 0, @as(i32, @intCast(back.width)) - 1),
        .y = std.math.clamp(y, 0, @as(i32, @intCast(back.height)) - 1),

    };

    switch (screen) {

        .svga => |*device| device.point(pointer),
        .frame => |*frame| {

            frame.present(&back, sprite(previous));
            frame.present(&back, sprite(pointer));

        },

    }

}

fn owned(request: api.Request, id: u64) ?*Surface {

    if (id >= surfaces.len) return null;

    const surface = &surfaces[id];

    return if (surface.client != 0 and surface.client == request.first and !surface.leaving) surface else null;

}

fn local(index: usize, event: api.Event) api.Event {

    var result = event;
    const area = surfaces[index].area;

    result.x = @intCast(std.math.clamp(pointer.x - area.x, -32768, 32767));
    result.y = @intCast(std.math.clamp(pointer.y - area.y, -32768, 32767));

    return result;

}

fn fetch(request: api.Request, comptime T: type) ?T {

    var value = std.mem.zeroes(T);

    api.fetch(request, 0, std.mem.asBytes(&value)) catch return null;

    return value;

}

fn rect(area: api.display.Area) gui.Rect {

    return .{

        .x = area.x,
        .y = area.y,
        .width = area.width,
        .height = area.height,

    };

}

fn corner(area: gui.Rect) gui.Point {

    return .{

        .x = area.x,
        .y = area.y,

    };

}

fn sprite(at: gui.Point) gui.Rect {

    return .{

        .x = at.x,
        .y = at.y,
        .width = arrow[0].len,
        .height = arrow.len,

    };

}

fn fault() noreturn {

    asm volatile ("ud2");
    api.exit(1);

}
