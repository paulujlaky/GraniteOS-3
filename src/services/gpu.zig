const std = @import("std");

const svga = @import("svga.zig");

const api = @import("api");
const gui = @import("gui");

// SVGA3D commands, numbered as in VMware's svga3d_cmd.h; "memory objects" are its MOBs.
const surface_copy = 1042;
const set_z_range = 1048;
const set_render_state = 1049;
const set_render_target = 1050;
const set_texture_state = 1051;
const set_viewport = 1055;
const clear = 1057;
const set_shader = 1061;
const draw = 1063;
const destroy_object = 1094;
const define_surface = 1097;
const destroy_surface = 1098;
const bind_surface = 1099;
const update_image = 1101;
const readback_image = 1103;
const define_context = 1107;
const bind_context = 1109;
const define_shader = 1112;
const bind_shader = 1114;
const set_table = 1115;
const define_target = 1124;
const bind_target = 1126;
const update_target = 1127;
const define_object = 1135;

// Surface formats and flags.
const x8r8g8b8 = 1;
const a8r8g8b8 = 2;
const buffer = 37;
const vertex_hint = 1 << 4;
const texture_hint = 1 << 5;
const target_hint = 1 << 6;
const scanout = 1 << 16;

// Page table depths for 64-bit page numbers: the data page itself, one level of tables, or two.
const flat = 4;
const one_level = 5;
const two_levels = 6;

const color0 = 2;
const clear_color = 1;
const vertex_shader = 1;
const pixel_shader = 2;
const triangle_list = 1;
const no_id = 0xffffffff;
const primary = 1;

// Vertex element types and usages.
const float2 = 1;
const packed_color = 4;
const position = 0;
const texcoord = 5;
const vertex_color = 10;

// Render states and their values.
const z_enable = 1;
const z_write = 2;
const alpha_test = 3;
const blend = 5;
const fog = 6;
const stencil = 8;
const lighting = 9;
const shade_mode = 30;
const source_blend = 32;
const target_blend = 33;
const blend_equation = 34;
const cull_mode = 35;
const smooth = 2;
const cull_none = 1;
const zero = 1;
const one = 2;
const source_alpha = 5;
const inverse_source_alpha = 6;
const inverse_target_alpha = 8;
const add = 1;

// Texture states and their values.
const bind_texture = 1;
const address_u = 8;
const address_v = 9;
const mip_filter = 10;
const mag_filter = 11;
const min_filter = 12;
const clamp = 3;
const nearest = 1;
const linear = 2;

// vs_2_0: dcl_position v0; dcl_texcoord v1; dcl_color v2; mov oPos, v0; mov oT0.xy, v1; mov oD0, v2
const passthrough = [_]u32{

    0xfffe0200,
    0x0200001f, 0x80000000, 0x900f0000,
    0x0200001f, 0x80000005, 0x900f0001,
    0x0200001f, 0x8000000a, 0x900f0002,
    0x02000001, 0xc00f0000, 0x90e40000,
    0x02000001, 0xe0030000, 0x90e40001,
    0x02000001, 0xd00f0000, 0x90e40002,
    0x0000ffff,

};

// ps_2_0: dcl t0.xy; dcl v0; dcl_2d s0; texld r0, t0, s0; mul r0, r0, v0; mov oC0, r0
const tint = [_]u32{

    0xffff0200,
    0x0200001f, 0x80000000, 0xb0030000,
    0x0200001f, 0x80000000, 0x900f0000,
    0x0200001f, 0x90000000, 0xa00f0800,
    0x03000042, 0x800f0000, 0xb0e40000, 0xa0e40800,
    0x03000005, 0x800f0000, 0x80e40000, 0x90e40000,
    0x02000001, 0x800f0800, 0x80e40000,
    0x0000ffff,

};

// Object ids; every surface keeps its pixels in the memory object of the same id.
const frame = 0;
const vertices = 1;
const atlas = 2;
const result = 3;
const code = 4;
const state = 5;

/// Where quads land; finished areas are copied to `frame`, so the host never shows one half drawn.
const canvas = 6;

/// Where a moving surface is drawn whole, with transparency, before landing on `canvas` scaled and faded.
const layer = 7;

/// Clients' images, each a texture of its own, follow the fixed objects.
const pictures = 8;
pub const textures = 48;
const objects = pictures + textures;

// One page holds each object table: memory objects, surfaces, contexts, shaders, and screen targets; 64 surfaces fit.
const tables = 5;

const context = 0;

// A legacy context saves 16 KiB of state.
const state_pages = 4;

/// Side of the square texture caching glyphs and corner masks; one row fills one page.
const atlas_size = 1024;

// The top-left texels: a solid block that plain fills sample, then one half-covered texel for the self-test.
const solid = 4;
const half = solid;

const vertex_pages = 512;
const triangle_bytes = 3 * @sizeOf(Vertex);
const triangles = vertex_pages * 4096 / triangle_bytes;

// Larger corners than this draw square; no window rounds them that much.
const largest_corner = 64;

const Vertex = extern struct {

    x: f32,
    y: f32,
    u: f32,
    v: f32,

    /// 0xAARRGGBB, which the device hands the shader as red, green, blue, alpha.
    color: u32,

};

/// Where a glyph or corner mask sits in the atlas; an empty slot draws nothing.
const Slot = struct {

    key: u64 = 0,
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    left: i32 = 0,
    top: i32 = 0,

};

const Kind = enum(u2) {

    corner,
    glyph,
    shadow,

};

// The shape cache and page tables, kept outside `Gpu` so passing one around copies little on a small stack.
var slots = [_]Slot{.{}} ** 2048;
var maps = [_]Paging{.{}} ** objects;

/// A shape's outline, or a curve moved onto the target, while it becomes triangles.
var outline: [gui.sketch.most + 1][2]f32 = undefined;

/// A corner of a triangle on the target, in pixels, and its premultiplied colour, which the GPU blends smoothly between corners.
const Corner = struct {

    x: f32,
    y: f32,
    color: u32,

};

/// Room to soften a shadow corner in before it goes into the atlas.
var softening: [gui.canvas.penumbra * gui.canvas.penumbra]f32 = undefined;
var softening_scratch: [gui.canvas.penumbra * (gui.canvas.penumbra + gui.canvas.widest)]f32 = undefined;


/// The size each image texture was defined at, zero while undefined, and our copy of its pixels.
var defined = [_][2]u32{.{ 0, 0 }} ** textures;
var copies = [_]?api.Shared{null} ** textures;

/// Finds the texture slot of an image handle the commands being drawn name.
pub const Textures = *const fn (handle: u64) ?usize;

/// Draws everything on the SVGA3D device: each command becomes textured quads, tinted and blended in one shader.
pub const Gpu = struct {

    device: *svga.Device,
    width: u32,
    height: u32,

    /// Contiguous views of what the device reads, and the page it writes the self-test back to.
    vertices: api.Shared,
    atlas: api.Shared,
    readback: api.Page,

    /// How far pixel centres sit from each pixel's top-left corner; the self-test settles it.
    shift: f32 = 0.5,

    /// The target quads land on, in pixels.
    columns: u32 = 0,
    rows: u32 = 0,

    /// Triangles staged since the last draw, and whether the device may still be reading staged ones.
    count: usize = 0,
    busy: bool = false,

    filled: usize = 0,

    /// The atlas shelf being filled, and atlas texels written but not yet uploaded.
    cursor: gui.Point = .{},
    shelf: u32 = 0,
    dirty: gui.Rect = .{},

    /// Draws into a `width` by `height` frame and shows it; null, leaving the screen alone, unless a test pattern draws exactly.
    pub fn init(device: *svga.Device, width: u32, height: u32) ?Gpu {

        if (!device.accelerated) return null;

        return setup(device, width, height) catch null;

    }

    fn setup(device: *svga.Device, width: u32, height: u32) !?Gpu {

        // A new atlas starts blank, so shapes cached for the last one, such as before a mode switch, are gone.
        @memset(&slots, .{});
        @memset(&defined, .{ 0, 0 });

        for (&copies) |*copy| if (copy.*) |memory| {

            api.detach(memory.handle);
            copy.* = null;

        };

        // Tables from an earlier display are dropped along with every object they held.
        for (0..tables) |kind| {

            const page = try api.dma();

            device.submit(set_table, &.{ @intCast(kind), @truncate(page.physical >> 12), @intCast(page.physical >> 44), 4096, 0, flat });

        }

        var gpu = Gpu{

            .device = device,
            .width = width,
            .height = height,

            .vertices = try api.share(vertex_pages),
            .atlas = try api.share(atlas_size * atlas_size * 4 / 4096),
            .readback = undefined,

        };

        // The device may write context state and rendered frames back at any time, so those pages outlive us.
        _ = try gpu.reserve(state, state_pages);
        _ = try gpu.reserve(frame, (width * height * 4 + 4095) / 4096);
        _ = try gpu.reserve(canvas, (width * height * 4 + 4095) / 4096);
        _ = try gpu.reserve(layer, (width * height * 4 + 4095) / 4096);
        gpu.readback = try gpu.reserve(result, 1);

        const program = try gpu.reserve(code, 1);

        try gpu.lend(vertices, gpu.vertices);
        try gpu.lend(atlas, gpu.atlas);

        @memcpy(program.bytes[0..@sizeOf(@TypeOf(passthrough))], std.mem.asBytes(&passthrough));
        @memcpy(program.bytes[256..][0..@sizeOf(@TypeOf(tint))], std.mem.asBytes(&tint));

        gpu.surface(frame, texture_hint | target_hint | scanout, x8r8g8b8, width, height);
        gpu.surface(canvas, texture_hint | target_hint, x8r8g8b8, width, height);
        gpu.surface(layer, texture_hint | target_hint, a8r8g8b8, width, height);
        gpu.surface(vertices, vertex_hint, buffer, vertex_pages * 4096, 1);
        gpu.surface(atlas, texture_hint, a8r8g8b8, atlas_size, atlas_size);
        gpu.surface(result, target_hint, x8r8g8b8, 4, 4);

        device.submit(define_context, &.{context});
        device.submit(bind_context, &.{ context, state, 0 });
        device.submit(define_shader, &.{ 0, vertex_shader, @sizeOf(@TypeOf(passthrough)) });
        device.submit(bind_shader, &.{ 0, code, 0 });
        device.submit(define_shader, &.{ 1, pixel_shader, @sizeOf(@TypeOf(tint)) });
        device.submit(bind_shader, &.{ 1, code, 256 });
        device.submit(set_z_range, &.{ context, @bitCast(@as(f32, 0)), @bitCast(@as(f32, 1)) });

        // Flat shading takes a slow path on some hosts; colours arrive premultiplied, so blending adds what lies beneath.
        device.submit(set_render_state, &.{

            context,
            shade_mode, smooth,
            z_enable, 0,
            z_write, 0,
            alpha_test, 0,
            fog, 0,
            stencil, 0,
            lighting, 0,
            cull_mode, cull_none,
            blend, 1,
            source_blend, one,
            target_blend, inverse_source_alpha,
            blend_equation, add,

        });

        // Point sampling at texel centres copies atlas texels exactly.
        device.submit(set_texture_state, &.{

            context,
            0, min_filter, nearest,
            0, mag_filter, nearest,
            0, mip_filter, 0,
            0, address_u, clamp,
            0, address_v, clamp,
            0, bind_texture, atlas,

        });

        device.submit(set_shader, &.{ context, vertex_shader, 0 });
        device.submit(set_shader, &.{ context, pixel_shader, 1 });

        const texels = std.mem.bytesAsSlice(u32, gpu.atlas.bytes);

        for (0..solid) |y| @memset(texels[y * atlas_size ..][0..solid], 0xffffffff);
        texels[half] = 0x80808080;
        gpu.cursor.x = solid + 1;
        gpu.shelf = solid;
        gpu.dirty = .{

            .width = solid + 1,
            .height = solid,

        };

        // Hosts disagree on where pixel centres fall, so take whichever convention draws the pattern exactly.
        const settled = for ([_]f32{ 0.5, 0 }) |shift| {

            gpu.shift = shift;
            if (gpu.check()) break true;

        } else false;

        if (!settled) return null;

        device.submit(set_render_target, &.{ context, color0, canvas, 0, 0 });
        device.submit(set_viewport, &.{ context, 0, 0, width, height });

        device.retire();
        device.submit(define_target, &.{ 0, width, height, 0, 0, primary, 0 });
        device.submit(bind_target, &.{ 0, frame, 0, 0 });

        gpu.columns = width;
        gpu.rows = height;

        return gpu;

    }

    // ponytail: each mode switch leaks the old frame's DMA pages; reuse them if switching becomes frequent.
    /// Gives back the memory the device reads; the pages it writes stay reserved.
    pub fn release(self: *Gpu) void {

        api.detach(self.vertices.handle);
        api.detach(self.atlas.handle);

    }

    /// Starts redrawing `area` of the frame from the background up.
    pub fn begin(self: *Gpu, area: gui.Rect) void {

        self.device.submit(clear, &.{ context, clear_color, gui.theme.background, @bitCast(@as(f32, 1)), 0, @intCast(area.x), @intCast(area.y), @intCast(area.width), @intCast(area.height) });

    }

    /// Queues `bytes` of drawing commands, shifted by `origin` and kept inside `limit`; `images` finds their textures.
    pub fn render(self: *Gpu, bytes: []const u8, origin: gui.Point, limit: gui.Rect, images: Textures) void {

        var commands = gui.draw.iterate(bytes);

        while (commands.next()) |command| {

            switch (command) {

                .shape => |shape| self.rounded(gui.draw.move(shape.area, origin), shape.radius, shape.color, limit.intersect(gui.draw.move(shape.clip, origin)) orelse continue),
                .text => |line| self.write(line.string, line.face, line.size, line.x + origin.x, line.baseline + origin.y, line.color, limit.intersect(gui.draw.move(line.clip, origin)) orelse continue),
                .image => |shown| self.picture(images(shown.handle) orelse continue, gui.draw.move(shown.area, origin), limit.intersect(gui.draw.move(shown.clip, origin)) orelse continue),
                .shadow => |soft| self.shadow(gui.draw.move(soft.area, origin), soft.radius, soft.blur, soft.color, limit.intersect(gui.draw.move(soft.clip, origin)) orelse continue),
                .form => |mark| self.form(mark.form.moved(@floatFromInt(origin.x), @floatFromInt(origin.y)), mark.color, limit.intersect(gui.draw.move(mark.clip, origin)) orelse continue),
                .curve => |line| self.curve(line.points, origin, line.width, line.color, line.under, limit.intersect(gui.draw.move(line.clip, origin)) orelse continue),

            }

        }

    }

    /// Makes `pixels`, `width` by `height` premultiplied, the texture of image `slot`, or refreshes the `changed` part of it.
    pub fn upload(self: *Gpu, slot: usize, pixels: []const u32, width: u32, height: u32, changed: gui.Rect) void {

        const id: u32 = @intCast(pictures + slot);
        const fresh = defined[slot][0] != width or defined[slot][1] != height;
        const whole = gui.Rect{

            .width = @intCast(width),
            .height = @intCast(height),

        };
        const area = if (fresh) whole else changed.intersect(whole) orelse return;

        // The device reads our own copy, so a client can neither change nor free what it is drawing.
        if (fresh) {

            self.discard(slot);

            const copy = api.share(std.math.divCeil(usize, pixels.len * 4, 4096) catch unreachable) catch return;

            self.lend(id, copy) catch {

                api.detach(copy.handle);
                return;

            };
            copies[slot] = copy;
            self.surface(id, texture_hint, a8r8g8b8, width, height);
            defined[slot] = .{ width, height };

        } else {

            // Quads already staged may still want the old pixels.
            self.flush();

        }

        const copy = std.mem.bytesAsSlice(u32, copies[slot].?.bytes[0 .. pixels.len * 4]);
        const left: usize = @intCast(area.x);
        const span: usize = @intCast(area.width);

        for (@intCast(area.y)..@intCast(area.bottom())) |y| @memcpy(copy[y * width + left ..][0..span], pixels[y * width + left ..][0..span]);

        self.update(id, @intCast(area.x), @intCast(area.y), @intCast(area.width), @intCast(area.height));

    }

    /// Drops image `slot`'s texture, once the device has drawn everything that used it.
    pub fn discard(self: *Gpu, slot: usize) void {

        if (defined[slot][0] == 0) return;

        const id: u32 = @intCast(pictures + slot);

        self.flush();
        self.device.idle();
        self.busy = false;
        self.device.submit(destroy_surface, &.{id});
        self.device.submit(destroy_object, &.{id});
        self.device.idle();
        api.detach(copies[slot].?.handle);
        copies[slot] = null;
        defined[slot] = .{ 0, 0 };

    }

    /// Draws what was queued, then copies `area` to the frame and shows it.
    pub fn finish(self: *Gpu, area: gui.Rect) void {

        const x: u32 = @intCast(area.x);
        const y: u32 = @intCast(area.y);

        self.flush();

        // Source then destination as surface, face, and mipmap, then one box: x, y, z, width, height, depth, and where it starts in the source.
        self.device.submit(surface_copy, &.{ canvas, 0, 0, frame, 0, 0, x, y, 0, @intCast(area.width), @intCast(area.height), 1, x, y, 0 });
        self.device.submit(update_target, &.{ 0, x, y, @intCast(area.width), @intCast(area.height) });

    }

    /// How quads mix with what lies under them.
    pub const Blend = enum {

        /// Over it: the usual.
        over,

        /// Under it, showing only where it is still transparent.
        under,

        /// Keeping it only as far as the quad covers it.
        mask,

    };

    pub fn blending(self: *Gpu, mode: Blend) void {

        const factors: [2]u32 = switch (mode) {

            .over => .{ one, inverse_source_alpha },
            .under => .{ inverse_target_alpha, one },
            .mask => .{ zero, source_alpha },

        };

        self.flush();
        self.device.submit(set_render_state, &.{ context, source_blend, factors[0], target_blend, factors[1] });

    }

    /// Sends what follows to the layer, cleared to transparent over `area`, until `lower` lays it on the frame.
    pub fn lift(self: *Gpu, area: gui.Rect) void {

        self.flush();
        self.device.submit(set_render_target, &.{ context, color0, layer, 0, 0 });
        self.device.submit(clear, &.{ context, clear_color, 0, @bitCast(@as(f32, 1)), 0, @intCast(area.x), @intCast(area.y), @intCast(area.width), @intCast(area.height) });

    }

    /// Rounds off the bottom corners of `area`, drawn in the layer, to `radius`, clearing what lies outside the curve.
    pub fn cut(self: *Gpu, area: gui.Rect, radius: i32) void {

        const corners = gui.Corners{

            .area = area,
            .radius = radius,

        };
        const squares = corners.squares();
        if (squares[0].width <= 0 or squares[0].width > largest_corner) return;

        const slot = self.corner(@intCast(squares[0].width)) orelse return;

        self.blending(.mask);
        for (squares, [_]bool{ false, true }) |square, right| self.quad(square, slot, right, true, 0xffffff, square);
        self.blending(.over);

    }

    /// Goes back to drawing on the frame, and lays `area` of the layer over `box` (left, top, right, bottom), faded to `opacity`, within `clip`.
    pub fn lower(self: *Gpu, area: gui.Rect, box: [4]f32, opacity: f32, clip: gui.Rect) void {

        self.flush();
        self.device.submit(set_render_target, &.{ context, color0, canvas, 0, 0 });

        const left = @max(box[0], @as(f32, @floatFromInt(clip.x)));
        const top = @max(box[1], @as(f32, @floatFromInt(clip.y)));
        const right = @min(box[2], @as(f32, @floatFromInt(clip.right())));
        const bottom = @min(box[3], @as(f32, @floatFromInt(clip.bottom())));

        if (right <= left or bottom <= top) return;

        const across = (box[2] - box[0]) / @as(f32, @floatFromInt(area.width));
        const down = (box[3] - box[1]) / @as(f32, @floatFromInt(area.height));
        const columns: f32 = @floatFromInt(self.width);
        const rows: f32 = @floatFromInt(self.height);
        const x: f32 = @floatFromInt(area.x);
        const y: f32 = @floatFromInt(area.y);
        const level: u32 = @intFromFloat(std.math.clamp(opacity, 0, 1) * 255 + 0.5);

        // The layer holds premultiplied colour, so fading scales every channel alike.
        self.sample(layer, linear);
        self.stretch(.{ left, top, right, bottom }, .{

            (x + (left - box[0]) / across) / columns,
            (x + (right - box[0]) / across) / columns,

        }, .{

            (y + (top - box[1]) / down) / rows,
            (y + (bottom - box[1]) / down) / rows,

        }, level * 0x01010101);
        self.flush();
        self.sample(atlas, nearest);

    }

    /// Fills `area` with anti-aliased corners, as a solid cross and four corner masks.
    fn rounded(self: *Gpu, area: gui.Rect, radius: i32, color: u32, clip: gui.Rect) void {

        const limit = @min(radius, @divTrunc(@min(area.width, area.height), 2));
        const mask = if (limit > 0 and limit <= largest_corner) self.corner(@intCast(limit)) else null;
        const slot = mask orelse return self.quad(area, null, false, false, color, clip);
        const r = limit;

        self.quad(.{

            .x = area.x,
            .y = area.y + r,
            .width = area.width,
            .height = area.height - 2 * r,

        }, null, false, false, color, clip);

        for ([_]i32{ area.y, area.bottom() - r }) |y| {

            self.quad(.{

                .x = area.x + r,
                .y = y,
                .width = area.width - 2 * r,
                .height = r,

            }, null, false, false, color, clip);

        }

        for ([_]bool{ false, true }) |bottom| {

            for ([_]bool{ false, true }) |right| {

                self.quad(.{

                    .x = if (right) area.right() - r else area.x,
                    .y = if (bottom) area.bottom() - r else area.y,
                    .width = r,
                    .height = r,

                }, slot, right, bottom, color, clip);

            }

        }

    }

    /// Lays a soft shadow as `Canvas.shadow` does: four corners from one softened tile, and edges stretched from its innermost row and column.
    fn shadow(self: *Gpu, area: gui.Rect, radius: i32, blur: i32, color: u32, clip: gui.Rect) void {

        const fit = gui.canvas.Shadow.fit(area, radius, blur) orelse return;
        const slot = self.blurred(fit) orelse return;
        const side: i32 = @intCast(fit.side());
        const outer = area.inset(-@as(i32, @intCast(fit.blur)));
        const across = outer.width - 2 * side;
        const down = outer.height - 2 * side;

        for ([_]bool{ false, true }) |far| {

            for ([_]bool{ false, true }) |right| {

                self.quad(.{

                    .x = if (right) outer.right() - side else outer.x,
                    .y = if (far) outer.bottom() - side else outer.y,
                    .width = side,
                    .height = side,

                }, slot, right, far, color, clip);

            }

            // The top and bottom edges repeat the tile's innermost column, the sides its innermost row.
            if (across > 0) self.band(.{

                .x = outer.x + side,
                .y = if (far) outer.bottom() - side else outer.y,
                .width = across,
                .height = side,

            }, .{

                .x = slot.x + slot.width - 1,
                .y = slot.y,
                .width = 1,
                .height = slot.height,

            }, far, color, clip);

            if (down > 0) self.band(.{

                .x = if (far) outer.right() - side else outer.x,
                .y = outer.y + side,
                .width = side,
                .height = down,

            }, .{

                .x = slot.x,
                .y = slot.y + slot.height - 1,
                .width = slot.width,
                .height = 1,

            }, far, color, clip);

        }

    }

    /// Stages `area` sampling `strip`, one texel thick, along its length, and repeating it across; `mirror` reads it from the far end.
    fn band(self: *Gpu, area: gui.Rect, strip: Slot, mirror: bool, color: u32, clip: gui.Rect) void {

        const visible = area.intersect(clip) orelse return;
        const across = strip.width == 1;
        const middle = (@as(f32, @floatFromInt(if (across) strip.x else strip.y)) + 0.5) / atlas_size;
        const fixed = [2]f32{ middle, middle };
        const u = if (across) fixed else [2]f32{ texel(strip.x, strip.width, visible.x - area.x, mirror), texel(strip.x, strip.width, visible.right() - area.x, mirror) };
        const v = if (!across) fixed else [2]f32{ texel(strip.y, strip.height, visible.y - area.y, mirror), texel(strip.y, strip.height, visible.bottom() - area.y, mirror) };

        self.stage(visible, u, v, premultiplied(color));

    }

    /// The atlas tile for a shadow corner shaped as `fit`, softened on first use.
    fn blurred(self: *Gpu, fit: gui.canvas.Shadow) ?Slot {

        const key = pack(.shadow, fit.radius << 8 | fit.blur, 0, 0);
        if (cached(key)) |slot| return slot;

        const n = fit.side();
        const slot = self.insert(key, n, n) orelse return null;
        const texels = std.mem.bytesAsSlice(u32, self.atlas.bytes);

        fit.soften(&softening, &softening_scratch);

        for (0..n) |y| {

            for (0..n) |x| texels[(slot.y + y) * atlas_size + slot.x + x] = coverage(softening[y * n + x]);

        }

        return slot;

    }

    /// Draws image `slot` stretched over `area`, filtered smoothly.
    fn picture(self: *Gpu, slot: usize, area: gui.Rect, clip: gui.Rect) void {

        const visible = area.intersect(clip) orelse return;
        if (defined[slot][0] == 0) return;

        const width: f32 = @floatFromInt(area.width);
        const height: f32 = @floatFromInt(area.height);

        // Quads already staged sample the atlas, so they go first.
        self.flush();
        self.sample(@intCast(pictures + slot), linear);
        self.stage(visible, .{

            @as(f32, @floatFromInt(visible.x - area.x)) / width,
            @as(f32, @floatFromInt(visible.right() - area.x)) / width,

        }, .{

            @as(f32, @floatFromInt(visible.y - area.y)) / height,
            @as(f32, @floatFromInt(visible.bottom() - area.y)) / height,

        }, 0xffffffff);
        self.flush();
        self.sample(atlas, nearest);

    }

    /// Binds texture `id` to the one sampler, read with `filter`.
    fn sample(self: *Gpu, id: u32, filter: u32) void {

        self.device.submit(set_texture_state, &.{

            context,
            0, min_filter, filter,
            0, mag_filter, filter,
            0, bind_texture, id,

        });

    }

    /// Lays out UTF-8 `string` like `Canvas.text`, one glyph quad per character.
    fn write(self: *Gpu, string: []const u8, which: gui.Face, size: f32, x: i32, baseline: i32, color: u32, clip: gui.Rect) void {

        const face = gui.font.face(which);
        const scale = size / face.units;
        var pen: f32 = @floatFromInt(x);
        var previous: u16 = 0;
        var characters = gui.font.decode(string);

        while (characters.next()) |char| {

            const glyph = face.lookup(char);

            pen += face.kerning(previous, glyph) * scale;
            previous = glyph;

            const whole = @floor(pen);
            const left: i32 = @intFromFloat(whole);

            if (left > clip.right()) return;

            // Quarter-pixel positions keep spacing even while letting each shape be cached.
            if (self.letter(which, glyph, size, @intFromFloat((pen - whole) * 4))) |slot| self.quad(.{

                .x = left + slot.left,
                .y = baseline + slot.top,
                .width = @intCast(slot.width),
                .height = @intCast(slot.height),

            }, slot, false, false, color, clip);

            pen += face.advance(glyph) * scale;

        }

    }

    /// Stages one quad of `area` within `clip`, sampling `slot` one texel per pixel, or the solid block when null.
    fn quad(self: *Gpu, area: gui.Rect, slot: ?Slot, mirror_x: bool, mirror_y: bool, color: u32, clip: gui.Rect) void {

        const visible = area.intersect(clip) orelse return;
        const centre: f32 = @as(f32, solid / 2) / atlas_size;
        var u = [2]f32{ centre, centre };
        var v = [2]f32{ centre, centre };

        if (slot) |source| {

            u = .{ texel(source.x, source.width, visible.x - area.x, mirror_x), texel(source.x, source.width, visible.right() - area.x, mirror_x) };
            v = .{ texel(source.y, source.height, visible.y - area.y, mirror_y), texel(source.y, source.height, visible.bottom() - area.y, mirror_y) };

        }

        self.stage(visible, u, v, premultiplied(color));

    }

    /// Stages one quad covering `visible`, sampling from `u` and `v`, tinted by premultiplied `tinted`.
    fn stage(self: *Gpu, visible: gui.Rect, u: [2]f32, v: [2]f32, tinted: u32) void {

        self.stretch(.{ @floatFromInt(visible.x), @floatFromInt(visible.y), @floatFromInt(visible.right()), @floatFromInt(visible.bottom()) }, u, v, tinted);

    }

    /// Stages one quad between pixel edges `box`, as left, top, right, and bottom, which may fall between pixels.
    fn stretch(self: *Gpu, box: [4]f32, u: [2]f32, v: [2]f32, tinted: u32) void {

        const left = edge(box[0], self.columns, self.shift);
        const right = edge(box[2], self.columns, self.shift);
        const top = -edge(box[1], self.rows, self.shift);
        const bottom = -edge(box[3], self.rows, self.shift);

        self.emit(.{

            .{ .x = left, .y = top, .u = u[0], .v = v[0], .color = tinted },
            .{ .x = right, .y = top, .u = u[1], .v = v[0], .color = tinted },
            .{ .x = right, .y = bottom, .u = u[1], .v = v[1], .color = tinted },

        });
        self.emit(.{

            .{ .x = left, .y = top, .u = u[0], .v = v[0], .color = tinted },
            .{ .x = right, .y = bottom, .u = u[1], .v = v[1], .color = tinted },
            .{ .x = left, .y = bottom, .u = u[0], .v = v[1], .color = tinted },

        });

    }

    /// Stages one triangle, in clip space.
    fn emit(self: *Gpu, corners: [3]Vertex) void {

        if (self.count == triangles) self.flush();

        // The device may still be copying the last batch out of the staging memory.
        if (self.busy) {

            self.device.idle();
            self.busy = false;

        }

        const staged: *[3]Vertex = @ptrCast(@alignCast(self.vertices.bytes[self.count * triangle_bytes ..][0..triangle_bytes]));

        staged.* = corners;
        self.count += 1;

    }

    /// Draws `shape` as triangles whose corners fade to clear across its edges, so they come out anti-aliased.
    fn form(self: *Gpu, shape: gui.sketch.Form, color: u32, clip: gui.Rect) void {

        const drawn = shape.path(&outline);

        self.trace(drawn.points, drawn.closed, drawn.half, premultiplied(color), clip);

    }

    /// Draws a line through `points`, moved by `origin`, over the shaded area `under` it, as `sketch.Sketch.curve` paints them.
    fn curve(self: *Gpu, points: gui.sketch.Points, origin: gui.Point, width: f32, color: u32, under: ?gui.sketch.Under, clip: gui.Rect) void {

        const dx: f32 = @floatFromInt(origin.x);
        const dy: f32 = @floatFromInt(origin.y);
        const moved = outline[0..points.len];

        for (moved, points) |*to, from| to.* = .{ from[0] + dx, from[1] + dy };

        if (under) |area| {

            var shading = area;

            shading.floor += dy;
            shading.ceiling += dy;

            const left = moved[0][0];
            const right = moved[moved.len - 1][0];

            // A strip down from each piece of the line to the floor, shaded by height, which corners blend smoothly.
            for (moved[0 .. moved.len - 1], moved[1..]) |a, b| {

                const floors = [2]f32{ shading.bottom(a[0], left, right), shading.bottom(b[0], left, right) };

                self.four(.{

                    .{ .x = a[0], .y = a[1], .color = premultiplied(shading.color(a[1])) },
                    .{ .x = b[0], .y = b[1], .color = premultiplied(shading.color(b[1])) },
                    .{ .x = b[0], .y = floors[1], .color = premultiplied(shading.color(floors[1])) },
                    .{ .x = a[0], .y = floors[0], .color = premultiplied(shading.color(floors[0])) },

                }, clip);

            }

        }

        self.trace(moved, false, width / 2, premultiplied(color), clip);

    }

    /// Fills the polygon `points` when `half` is zero, else draws a band `half` either side of them, closing them into a loop or capping both ends round.
    fn trace(self: *Gpu, points: []const [2]f32, closed: bool, breadth: f32, ink: u32, clip: gui.Rect) void {

        if (points.len < 2) return;

        const count = points.len;

        if (breadth == 0) {

            if (count < 3) return;

            var area: f32 = 0;
            var centre = [2]f32{ 0, 0 };

            for (points, 0..) |point, index| {

                const next = points[(index + 1) % count];

                area += point[0] * next[1] - next[0] * point[1];
                centre = .{ centre[0] + point[0], centre[1] + point[1] };

            }

            const middle = Corner{

                .x = centre[0] / @as(f32, @floatFromInt(count)),
                .y = centre[1] / @as(f32, @floatFromInt(count)),
                .color = ink,

            };
            const outward: f32 = if (area > 0) 1 else -1;

            // A fan inside the edge, and a pixel-wide band across it fading out.
            for (0..count) |index| {

                const next = (index + 1) % count;
                const here = miter(points, index, true, outward);
                const there = miter(points, next, true, outward);
                const a = shifted(points[index], here, -0.5, ink);
                const b = shifted(points[next], there, -0.5, ink);

                self.triangle(.{ middle, a, b }, clip);
                self.four(.{ a, b, shifted(points[next], there, 0.5, 0), shifted(points[index], here, 0.5, 0) }, clip);

            }

            return;

        }

        // A line thinner than a pixel draws a pixel wide, as faint as it is thin.
        const thin = breadth < 0.5;
        const reach = if (thin) 0.5 else breadth;
        const color = if (thin) faded(ink, breadth * 2) else ink;
        const rails = [4]f32{ reach + 0.5, reach - 0.5, 0.5 - reach, -reach - 0.5 };
        const shades = [4]u32{ 0, color, color, 0 };
        const segments = if (closed) count else count - 1;

        for (0..segments) |index| {

            const next = (index + 1) % count;
            const here = miter(points, index, closed, 1);
            const there = miter(points, next, closed, 1);

            for (0..3) |rail| {

                self.four(.{

                    shifted(points[index], here, rails[rail], shades[rail]),
                    shifted(points[next], there, rails[rail], shades[rail]),
                    shifted(points[next], there, rails[rail + 1], shades[rail + 1]),
                    shifted(points[index], here, rails[rail + 1], shades[rail + 1]),

                }, clip);

            }

        }

        if (closed) return;

        // Round ends: breadth discs pointing away from the line.
        for ([_][2]usize{ .{ 0, 1 }, .{ count - 1, count - 2 } }) |ends| {

            const end = points[ends[0]];
            const length = @max(std.math.hypot(end[0] - points[ends[1]][0], end[1] - points[ends[1]][1]), 1e-6);
            const away = [2]f32{ (end[0] - points[ends[1]][0]) / length, (end[1] - points[ends[1]][1]) / length };
            const side = [2]f32{ away[1], -away[0] };
            const steps: usize = @intFromFloat(std.math.clamp(@ceil(std.math.pi * @sqrt(10 * reach) / 2), 3, 64));
            const middle = Corner{

                .x = end[0],
                .y = end[1],
                .color = color,

            };

            for (0..steps) |step| {

                var turn: [2][2]f32 = undefined;

                for (&turn, 0..) |*direction, which| {

                    const angle = (@as(f32, @floatFromInt(step + which)) / @as(f32, @floatFromInt(steps)) - 0.5) * std.math.pi;

                    direction.* = .{ @cos(angle) * away[0] + @sin(angle) * side[0], @cos(angle) * away[1] + @sin(angle) * side[1] };

                }

                const a = shifted(end, turn[0], reach - 0.5, color);
                const b = shifted(end, turn[1], reach - 0.5, color);

                self.triangle(.{ middle, a, b }, clip);
                self.four(.{ a, b, shifted(end, turn[1], reach + 0.5, 0), shifted(end, turn[0], reach + 0.5, 0) }, clip);

            }

        }

    }

    /// Stages the quadrilateral `corners` within `clip`, as two triangles.
    fn four(self: *Gpu, corners: [4]Corner, clip: gui.Rect) void {

        self.triangle(.{ corners[0], corners[1], corners[2] }, clip);
        self.triangle(.{ corners[0], corners[2], corners[3] }, clip);

    }

    /// Stages a triangle cut to `clip`, its corners' colours blending across it; cutting may leave up to six more corners, drawn as a fan.
    fn triangle(self: *Gpu, corners: [3]Corner, clip: gui.Rect) void {

        const bounds = [4]f32{ @floatFromInt(clip.x), @floatFromInt(clip.y), @floatFromInt(clip.right()), @floatFromInt(clip.bottom()) };
        var polygon: [9]Corner = undefined;
        var count: usize = 3;

        @memcpy(polygon[0..3], &corners);

        // Each side of the clip in turn keeps what lies inside it, adding a corner where an edge crosses it.
        for (0..4) |side| {

            var kept: [9]Corner = undefined;
            var total: usize = 0;

            for (0..count) |index| {

                const a = polygon[index];
                const b = polygon[(index + 1) % count];
                const da = inset(a, side, bounds);
                const db = inset(b, side, bounds);

                if (da >= 0) {

                    kept[total] = a;
                    total += 1;

                }

                if ((da >= 0) != (db >= 0) and total < kept.len) {

                    kept[total] = between(a, b, da / (da - db));
                    total += 1;

                }

            }

            if (total < 3) return;

            polygon = kept;
            count = total;

        }

        for (1..count - 1) |index| self.emit(.{ self.vertex(polygon[0]), self.vertex(polygon[index]), self.vertex(polygon[index + 1]) });

    }

    /// A corner placed on the target, sampling the solid block.
    fn vertex(self: *const Gpu, point: Corner) Vertex {

        const centre: f32 = @as(f32, solid / 2) / atlas_size;

        return .{

            .x = edge(point.x, self.columns, self.shift),
            .y = -edge(point.y, self.rows, self.shift),
            .u = centre,
            .v = centre,
            .color = point.color,

        };

    }

    /// Uploads new atlas texels and the staged quads, then draws them in one call.
    fn flush(self: *Gpu) void {

        if (self.dirty.width > 0) {

            self.update(atlas, @intCast(self.dirty.x), @intCast(self.dirty.y), @intCast(self.dirty.width), @intCast(self.dirty.height));
            self.dirty = .{};

        }

        if (self.count == 0) return;

        const stride = @sizeOf(Vertex);

        self.update(vertices, 0, 0, @intCast(self.count * triangle_bytes), 1);

        // Three arrays read the interleaved position, texture coordinate, and colour, then one unindexed range of triangles.
        self.device.submit(draw, &.{

            context, 3, 1,
            float2, 0, position, 0, vertices, 0, stride, 0, 0,
            float2, 0, texcoord, 0, vertices, 8, stride, 0, 0,
            packed_color, 0, vertex_color, 0, vertices, 16, stride, 0, 0,
            triangle_list, @intCast(self.count), no_id, 0, 0, 0, 0,

        });

        self.count = 0;
        self.busy = true;

    }

    fn corner(self: *Gpu, radius: u32) ?Slot {

        const key = pack(.corner, radius, 0, 0);
        if (cached(key)) |slot| return slot;

        const slot = self.insert(key, radius, radius) orelse return null;
        const r: f32 = @floatFromInt(radius);
        const texels = std.mem.bytesAsSlice(u32, self.atlas.bytes);

        // The top-left quarter of a circle centred on the mask's far corner, covered as `Canvas.round` covers it.
        for (0..radius) |y| {

            for (0..radius) |x| {

                const dx = @as(f32, @floatFromInt(x)) + 0.5 - r;
                const dy = @as(f32, @floatFromInt(y)) + 0.5 - r;

                texels[(slot.y + y) * atlas_size + slot.x + x] = coverage(r - @sqrt(dx * dx + dy * dy) + 0.5);

            }

        }

        return slot;

    }

    fn letter(self: *Gpu, which: gui.Face, index: u16, size: f32, quarter: u2) ?Slot {

        const key = pack(.glyph, @as(u32, @intFromEnum(which)) << 16 | index, size, quarter);
        if (cached(key)) |slot| return if (slot.width == 0) null else slot;

        const face = gui.font.face(which);
        const bitmap = face.render(index, size / face.units, @as(f32, @floatFromInt(quarter)) / 4) orelse {

            _ = self.insert(key, 0, 0);
            return null;

        };

        var slot = self.insert(key, @intCast(bitmap.width), @intCast(bitmap.height)) orelse return null;
        const texels = std.mem.bytesAsSlice(u32, self.atlas.bytes);

        for (0..bitmap.height) |y| {

            for (0..bitmap.width) |x| texels[(slot.y + y) * atlas_size + slot.x + x] = coverage(bitmap.coverage[y * bitmap.width + x]);

        }

        slot.left = bitmap.left;
        slot.top = bitmap.top;
        find(key).?.* = slot;

        return slot;

    }

    fn cached(key: u64) ?Slot {

        const slot = find(key) orelse return null;

        return if (slot.key == key) slot.* else null;

    }

    /// The slot holding `key`, or the empty one it would take.
    fn find(key: u64) ?*Slot {

        var index: usize = @intCast(std.hash.int(key) % slots.len);

        for (0..slots.len) |_| {

            const slot = &slots[index];
            if (slot.key == key or slot.key == 0) return slot;

            index = (index + 1) % slots.len;

        }

        return null;

    }

    /// Reserves a `width` by `height` atlas area for `key`, starting over once the atlas or table fills.
    fn insert(self: *Gpu, key: u64, width: u32, height: u32) ?Slot {

        if (self.filled * 4 >= slots.len * 3) self.reset();

        const place = self.allocate(width, height) orelse blk: {

            self.reset();
            break :blk self.allocate(width, height) orelse return null;

        };

        const slot = find(key) orelse return null;

        slot.* = .{

            .key = key,
            .x = place.x,
            .y = place.y,
            .width = width,
            .height = height,

        };
        self.filled += 1;
        self.dirty = self.dirty.join(.{

            .x = @intCast(place.x),
            .y = @intCast(place.y),
            .width = @intCast(width),
            .height = @intCast(height),

        });

        return slot.*;

    }

    fn allocate(self: *Gpu, width: u32, height: u32) ?struct { x: u32, y: u32 } {

        if (width == 0 or height == 0) return .{

            .x = 0,
            .y = 0,

        };

        var x: u32 = @intCast(self.cursor.x);
        var y: u32 = @intCast(self.cursor.y);

        if (x + width > atlas_size) {

            y += self.shelf;
            x = 0;
            self.shelf = 0;

        }

        if (y + height > atlas_size) return null;

        self.cursor = .{

            .x = @intCast(x + width),
            .y = @intCast(y),

        };
        self.shelf = @max(self.shelf, height);

        return .{

            .x = x,
            .y = y,

        };

    }

    /// Forgets every cached shape; queued quads are drawn first, since new shapes will overwrite theirs.
    fn reset(self: *Gpu) void {

        self.flush();
        self.device.idle();
        self.busy = false;

        @memset(&slots, .{});
        self.filled = 0;
        self.cursor = .{

            .x = solid + 1,

        };
        self.shelf = solid;

    }

    /// Draws a solid red block and a half-covered blue texel on grey in a four-by-four target; true when every pixel reads back right.
    fn check(self: *Gpu) bool {

        const grey = 0x808080;

        self.columns = 4;
        self.rows = 4;
        self.device.submit(set_render_target, &.{ context, color0, result, 0, 0 });
        self.device.submit(set_viewport, &.{ context, 0, 0, 4, 4 });
        self.device.submit(clear, &.{ context, clear_color, grey, @bitCast(@as(f32, 1)), 0, 0, 0, 4, 4 });

        const all = gui.Rect{

            .width = 4,
            .height = 4,

        };

        self.quad(.{

            .x = 1,
            .y = 1,
            .width = 2,
            .height = 2,

        }, null, false, false, 0xff0000, all);
        self.quad(.{

            .width = 1,
            .height = 1,

        }, .{

            .x = half,
            .width = 1,
            .height = 1,

        }, false, false, 0x0000ff, all);
        self.flush();
        self.device.submit(readback_image, &.{ result, 0, 0 });
        self.device.idle();
        self.busy = false;

        const pixels: *const volatile [16]u32 = @ptrCast(self.readback.bytes);

        for (0..4) |y| {

            for (0..4) |x| {

                const inside = (x == 1 or x == 2) and (y == 1 or y == 2);
                const expected: u32 = if (inside) 0xff0000 else if (x == 0 and y == 0) 0x4040c0 else grey;
                const actual = pixels[y * 4 + x] & 0xffffff;

                if (near(actual, expected)) continue;

                var line: [80]u8 = undefined;

                api.log(std.fmt.bufPrint(&line, "display: 3D self-test read {x} at ({d}, {d}), shift {d}\n", .{ actual, x, y, self.shift }) catch unreachable);

                return false;

            }

        }

        return true;

    }

    /// Copies a box of surface `sid` from its memory object to the device's copy.
    fn update(self: *Gpu, sid: u32, x: u32, y: u32, width: u32, height: u32) void {

        self.device.submit(update_image, &.{ sid, 0, 0, x, y, 0, width, height, 1 });

    }

    /// Defines surface `id` and binds it to the memory object of the same id.
    fn surface(self: *Gpu, id: u32, flags: u32, format: u32, width: u32, height: u32) void {

        // One mipmap level, no multisampling, no automatic mipmap filter.
        self.device.submit(define_surface, &.{ id, flags, format, 1, 0, 0, width, height, 1 });
        self.device.submit(bind_surface, &.{ id, id });

    }

    /// Makes memory object `id` from `count` fresh pages, which stay ours even after we exit; returns the first.
    fn reserve(self: *Gpu, id: u32, count: usize) !api.Page {

        var first: api.Page = undefined;

        for (0..count) |index| {

            const page = try api.dma();

            if (index == 0) first = page;
            try maps[id].set(index, page.physical);

        }

        try self.describe(id, count);

        return first;

    }

    /// Makes memory object `id` from `memory`, which the device only ever reads.
    fn lend(self: *Gpu, id: u32, memory: api.Shared) !void {

        const count = memory.bytes.len / 4096;

        for (0..count) |page| try maps[id].set(page, try api.physical(@intFromPtr(memory.bytes.ptr) + page * 4096));

        try self.describe(id, count);

    }

    /// Defines memory object `id` over the `count` pages its page tables list.
    fn describe(self: *Gpu, id: u32, count: usize) !void {

        const map = &maps[id];
        var depth: u32 = one_level;
        var root = map.pages[1].?.physical;

        if (count > 512) {

            if (map.pages[0] == null) map.pages[0] = try api.dma();

            const directory: *[512]u64 = @ptrCast(map.pages[0].?.bytes);

            for (0..(count + 511) / 512) |leaf| directory[leaf] = map.pages[1 + leaf].?.physical >> 12;

            depth = two_levels;
            root = map.pages[0].?.physical;

        }

        self.device.submit(define_object, &.{ id, depth, @truncate(root >> 12), @intCast(root >> 44), @intCast(count * 4096) });

    }

};

/// Page tables listing up to 16384 pages (64 MiB, a 4K frame twice over): a directory, then leaves of 512 page numbers each.
const Paging = struct {

    pages: [33]?api.Page = [_]?api.Page{null} ** 33,

    fn set(self: *Paging, index: usize, physical: u64) !void {

        if (index >= 32 * 512) return error.TooLarge;

        const leaf = &self.pages[1 + index / 512];

        if (leaf.* == null) leaf.* = try api.dma();

        const entries: *[512]u64 = @ptrCast(leaf.*.?.bytes);

        entries[index % 512] = physical >> 12;

    }

};

/// The clip-space position of pixel edge `edge` along a `span`-pixel axis.
pub fn edge(at: f32, span: u32, shift: f32) f32 {

    return (at - shift) * 2 / @as(f32, @floatFromInt(span)) - 1;

}

/// The texture coordinate `offset` texels into a slot, counted from its far side when mirrored.
pub fn texel(start: u32, span: u32, offset: i32, mirror: bool) f32 {

    const along: i32 = if (mirror) @as(i32, @intCast(span)) - offset else offset;

    return @as(f32, @floatFromInt(@as(i32, @intCast(start)) + along)) / atlas_size;

}

/// How far to move point `index` of `points` to put it `1` pixel off the line through it, along the bisector of its two edges so offset lines meet;
/// `outward` is 1 or -1, picking the side; the ends of an open line use their one edge.
fn miter(points: []const [2]f32, index: usize, closed: bool, outward: f32) [2]f32 {

    const count = points.len;
    const before: ?usize = if (index > 0) index - 1 else if (closed) count - 1 else null;
    const after: ?usize = if (index + 1 < count) index + 1 else if (closed) 0 else null;
    const first = normal(points, before orelse index, if (before) |_| index else after.?, outward);
    const second = normal(points, if (after) |_| index else before.?, after orelse index, outward);
    const sum = [2]f32{ first[0] + second[0], first[1] + second[1] };
    const scale = 1 + first[0] * second[0] + first[1] * second[1];

    // A hairpin would shoot the corner far away, so the miter stops at four pixels.
    if (scale < 0.125) return first;

    return .{ sum[0] / scale, sum[1] / scale };

}

/// The unit normal of the edge from point `from` to point `to`, turned to the `outward` side.
fn normal(points: []const [2]f32, from: usize, to: usize, outward: f32) [2]f32 {

    const dx = points[to][0] - points[from][0];
    const dy = points[to][1] - points[from][1];
    const length = @max(std.math.hypot(dx, dy), 1e-6);

    return .{ outward * dy / length, -outward * dx / length };

}

fn shifted(point: [2]f32, direction: [2]f32, distance: f32, color: u32) Corner {

    return .{

        .x = point[0] + direction[0] * distance,
        .y = point[1] + direction[1] * distance,
        .color = color,

    };

}

/// How far `corner` sits inside side `side` (left, top, right, bottom) of `bounds`; negative outside.
fn inset(corner: Corner, side: usize, bounds: [4]f32) f32 {

    return switch (side) {

        0 => corner.x - bounds[0],
        1 => corner.y - bounds[1],
        2 => bounds[2] - corner.x,
        else => bounds[3] - corner.y,

    };

}

/// The corner `t` of the way from `a` to `b`, its colour blended as the GPU would.
fn between(a: Corner, b: Corner, t: f32) Corner {

    var color: u32 = 0;

    for ([_]u5{ 0, 8, 16, 24 }) |shift| {

        const from: f32 = @floatFromInt(a.color >> shift & 0xff);
        const to: f32 = @floatFromInt(b.color >> shift & 0xff);

        color |= @as(u32, @intFromFloat(std.math.clamp(from + (to - from) * t + 0.5, 0, 255))) << shift;

    }

    return .{

        .x = a.x + (b.x - a.x) * t,
        .y = a.y + (b.y - a.y) * t,
        .color = color,

    };

}

/// Premultiplied `tint` made `amount` as opaque.
fn faded(color: u32, amount: f32) u32 {

    var scaled: u32 = 0;

    for ([_]u5{ 0, 8, 16, 24 }) |shift| scaled |= @as(u32, @intFromFloat(@as(f32, @floatFromInt(color >> shift & 0xff)) * std.math.clamp(amount, 0, 1) + 0.5)) << shift;

    return scaled;

}

/// Colours carry transparency in their top byte; the blend wants them premultiplied, with opacity as alpha.
fn premultiplied(color: u32) u32 {

    const alpha = 255 - (color >> 24);
    var tinted = alpha << 24;

    for ([_]u5{ 0, 8, 16 }) |shift| tinted |= (color >> shift & 0xff) * alpha / 255 << shift;

    return tinted;

}

/// Premultiplied white at `amount` coverage.
fn coverage(amount: f32) u32 {

    const level: u32 = @intFromFloat(std.math.clamp(amount, 0, 1) * 255 + 0.5);

    return level * 0x01010101;

}

fn pack(kind: Kind, code_point: u32, size: f32, quarter: u2) u64 {

    return 1 << 63 | @as(u64, @intFromEnum(kind)) << 61 | @as(u64, quarter) << 59 | @as(u64, code_point) << 32 | @as(u32, @bitCast(size));

}

fn near(actual: u32, expected: u32) bool {

    for ([_]u5{ 0, 8, 16 }) |shift| {

        const a: i32 = @intCast(actual >> shift & 0xff);
        const b: i32 = @intCast(expected >> shift & 0xff);

        if (@abs(a - b) > 3) return false;

    }

    return true;

}
