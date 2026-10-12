const api = @import("api");
const gui = @import("gui");

// Registers, reached through the index and value ports.
const id = 0;
const enable = 1;
const max_width = 4;
const max_height = 5;
const vram_size = 15;
const capabilities = 17;
const fifo_size = 19;
const config_done = 20;
const sync_start = 21;
const busy = 22;
const cursor_id = 24;
const cursor_x = 25;
const cursor_y = 26;
const cursor_on = 27;
const fifo_registers = 30;
const gmr_ids = 43;
const traces = 45;
const gmr_pages = 46;
const max_primary = 50;
const device_capability = 52;
const target_width = 55;
const target_height = 56;
const object_size = 57;

// FIFO registers, as word offsets into the command FIFO.
const fifo_min = 0;
const fifo_max = 1;
const fifo_next = 2;
const fifo_stop = 3;
const fifo_capabilities = 4;
const fifo_cursor_on = 9;
const fifo_cursor_x = 10;
const fifo_cursor_y = 11;
const fifo_cursor_count = 12;
const fifo_busy = 290;

const version = 0x90000002;
const three_d = 0x4000;
const extended_fifo = 0x8000;
const alpha_cursor = 0x200;
const has_traces = 0x200000;
const gmr2 = 0x400000;
const screen_object = 0x800000;
const guest_backed = 0x8000000;
const fifo_bypass = 1 << 4;
const fifo_screen_object = 1 << 9;

const define_alpha_cursor = 22;
const define_screen = 34;
const destroy_screen = 35;
const define_gmrfb = 36;
const blit_to_screen = 37;
const define_gmr2 = 41;
const remap_gmr2 = 42;

const framebuffer_gmr = 0xfffffffe;
const surface_gmr = 1;

/// VMware SVGA II in screen-object mode: the device copies frames from guest RAM and draws the cursor itself.
pub const Device = struct {

    ports: u64,
    fifo: [*]volatile u32 = undefined,
    position: u32 = 0,

    pending: bool = false,
    bypass: bool = false,

    /// Whether the host renders guest-backed 3D objects and can show a frame our size through a screen target.
    accelerated: bool = false,

    /// Takes over the adapter at `width` by `height`; null when it lacks screen objects or guest memory regions.
    pub fn init(bars: []const api.abi.Bar, width: u32, height: u32) ?Device {

        if (!bars[0].ports or bars[2].size == 0) return null;

        var device = Device{

            .ports = bars[0].base,

        };

        device.write(id, version);
        if (device.read(id) != version) return null;

        const needed = extended_fifo | alpha_cursor | gmr2 | screen_object;
        const features = device.read(capabilities);
        const size = device.read(fifo_size);

        if (features & needed != needed or size > bars[2].size) return null;
        if (width > device.read(max_width) or height > device.read(max_height) or device.read(vram_size) < width * height * 4) return null;

        device.fifo = @ptrCast(@alignCast(api.map(bars[2].base, size) catch return null));

        // A restarted display reconfigures from scratch; the device ignores commands while disabled or hidden.
        device.write(config_done, 0);
        device.write(enable, 1);
        if (features & has_traces != 0) device.write(traces, 0);

        const start = @max(device.read(fifo_registers) * 4, 4096);

        device.fifo[fifo_min] = start;
        device.fifo[fifo_max] = size;
        device.fifo[fifo_next] = start;
        device.fifo[fifo_stop] = start;
        device.fifo[fifo_busy] = 0;
        device.write(config_done, 1);

        if (device.fifo[fifo_capabilities] & fifo_screen_object == 0) {

            device.write(config_done, 0);
            device.write(enable, 0);

            return null;

        }

        device.bypass = device.fifo[fifo_capabilities] & fifo_bypass != 0;

        // Current hosts offer 3D only through guest-backed objects; device capability 0 says whether it is switched on.
        const frame = width * height * 4;

        device.accelerated = features & three_d != 0 and features & guest_backed != 0 and device.capability(0) != 0 and
            device.read(target_width) >= width and device.read(target_height) >= height and
            device.read(object_size) >= frame and device.read(max_primary) >= frame;

        // Screen 0: primary, rooted at the origin, its backing store at the start of VRAM.
        device.command(&.{

            define_screen, 44, 0, 3, width, height, 0, 0, framebuffer_gmr, 0, width * 4, 0,

        });

        return device;

    }

    /// Whether the adapter can show a `width` by `height` mode.
    pub fn fits(self: *Device, width: u32, height: u32) bool {

        return width <= self.read(max_width) and height <= self.read(max_height) and self.read(vram_size) / 4 / width >= height;

    }

    /// Registers `frame` as the memory the device copies from; its pages may lie anywhere in RAM.
    pub fn bind(self: *Device, frame: []align(4096) const u8, pitch: u32) bool {

        const pages: u32 = @intCast(frame.len / 4096);

        if (pages > self.read(gmr_pages) or self.read(gmr_ids) <= surface_gmr) return false;

        self.command(&.{

            define_gmr2, surface_gmr, pages,

        });

        var offset: u32 = 0;

        while (offset < pages) {

            const count = @min(pages - offset, 4096);

            self.reserve(5 + count);
            for ([_]u32{ remap_gmr2, surface_gmr, 0, offset, count }) |word| self.put(word);

            for (0..count) |page| {

                const physical = api.physical(@intFromPtr(frame.ptr) + (offset + page) * 4096) catch return false;

                self.put(@intCast(physical >> 12));

            }

            self.commit();
            offset += count;

        }

        // 32 bits per pixel, 24 of them colour.
        self.command(&.{

            define_gmrfb, surface_gmr, 0, pitch, 32 | 24 << 8,

        });

        return true;

    }

    /// Drops screen object 0, so a screen target can show frames in its place.
    pub fn retire(self: *Device) void {

        self.command(&.{

            destroy_screen, 0,

        });

    }

    /// Queues SVGA3D command `command_id` with `body`, whose size the header carries.
    pub fn submit(self: *Device, command_id: u32, body: []const u32) void {

        self.reserve(2 + body.len);
        self.put(command_id);
        self.put(@intCast(body.len * 4));
        for (body) |word| self.put(word);
        self.commit();

    }

    /// Copies `area` of the bound frame to the screen.
    pub fn present(self: *Device, area: gui.Rect) void {

        const left: u32 = @intCast(area.x);
        const top: u32 = @intCast(area.y);

        self.command(&.{

            blit_to_screen, left, top, left, top, left + @as(u32, @intCast(area.width)), top + @as(u32, @intCast(area.height)), 0,

        });

    }

    /// Defines the pointer image from premultiplied ARGB pixels.
    pub fn shape(self: *Device, pixels: []const u32, width: u32, height: u32, hotspot: gui.Point) void {

        self.reserve(6 + pixels.len);
        for ([_]u32{ define_alpha_cursor, 0, @intCast(hotspot.x), @intCast(hotspot.y), width, height }) |word| self.put(word);
        for (pixels) |pixel| self.put(pixel);
        self.commit();

    }

    pub fn point(self: *Device, at: gui.Point) void {

        if (self.bypass) {

            self.fifo[fifo_cursor_on] = 1;
            self.fifo[fifo_cursor_x] = @intCast(at.x);
            self.fifo[fifo_cursor_y] = @intCast(at.y);
            self.fifo[fifo_cursor_count] +%= 1;

            return;

        }

        self.write(cursor_id, 0);
        self.write(cursor_x, @intCast(at.x));
        self.write(cursor_y, @intCast(at.y));
        self.write(cursor_on, 1);

    }

    /// Waits until the device has run every queued command, so the bound frame may change.
    pub fn idle(self: *Device) void {

        if (!self.pending) return;

        self.write(sync_start, 1);

        while (self.read(busy) != 0) {

        }

        self.pending = false;

    }

    fn command(self: *Device, words: []const u32) void {

        self.reserve(words.len);
        for (words) |word| self.put(word);
        self.commit();

    }

    fn reserve(self: *Device, words: usize) void {

        while (self.free() <= words * 4) {

            self.pending = true;
            self.idle();

        }

        self.position = self.fifo[fifo_next];

    }

    fn put(self: *Device, word: u32) void {

        self.fifo[self.position / 4] = word;
        self.position += 4;
        if (self.position == self.fifo[fifo_max]) self.position = self.fifo[fifo_min];

    }

    fn commit(self: *Device) void {

        self.fifo[fifo_next] = self.position;
        self.pending = true;

        // Wakes the device unless it is already working through the FIFO.
        if (self.fifo[fifo_busy] == 0) {

            self.fifo[fifo_busy] = 1;
            self.write(sync_start, 1);

        }

    }

    fn free(self: *Device) usize {

        const next = self.fifo[fifo_next];
        const stop = self.fifo[fifo_stop];

        return if (next >= stop) self.fifo[fifo_max] - next + stop - self.fifo[fifo_min] else stop - next;

    }

    fn capability(self: *Device, index: u32) u32 {

        self.write(device_capability, index);

        return self.read(device_capability);

    }

    fn read(self: *Device, register: u32) u32 {

        api.out32(self.ports, register) catch api.exit(1);

        return api.in32(self.ports + 1) catch api.exit(1);

    }

    fn write(self: *Device, register: u32, value: u32) void {

        api.out32(self.ports, register) catch api.exit(1);
        api.out32(self.ports + 1, value) catch api.exit(1);

    }

};
