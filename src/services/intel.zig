//! Intel integrated graphics, such as the UHD Graphics 630 of Coffee Lake desktops: found and read while the firmware's framebuffer shows the desktop.
//! ponytail: no modesetting, GTT, or blitter yet; each needs validating on the physical desktop before the display trusts it.

const std = @import("std");

const api = @import("api");
const gui = @import("gui");

/// Display engine registers sit in the first two MiB of BAR 0; the GTT follows.
const window = 2 << 20;

// Pipe A's timings, and the first universal plane on it, as Skylake and later number them.
const horizontal_total = 0x60000;
const vertical_total = 0x6000c;
const plane_control = 0x70180;
const plane_stride = 0x70188;
const plane_surface = 0x7019c;

pub const Intel = struct {

    registers: usize,
    device: u16,

    /// Maps the registers of the device in `bars`, or null when BAR 0 cannot hold them.
    pub fn init(bars: []const api.abi.Bar, device: u32) ?Intel {

        if (device & 0xffff != 0x8086 or bars[0].ports or bars[0].size < window) return null;

        const mapped = api.map(bars[0].base, window) catch return null;

        return .{

            .registers = @intFromPtr(mapped),
            .device = @intCast(device >> 16),

        };

    }

    /// The size pipe A scans out, from its timings; empty while its power well is off.
    pub fn mode(self: *const Intel) gui.Rect {

        return .{

            .width = @intCast((self.read(horizontal_total) & 0x1fff) + 1),
            .height = @intCast((self.read(vertical_total) & 0x1fff) + 1),

        };

    }

    /// Says what the firmware left showing, so a log from the physical desktop shows what the next step has to work with.
    pub fn describe(self: *const Intel) void {

        const size = self.mode();
        const control = self.read(plane_control);
        var line: [160]u8 = undefined;

        api.log(std.fmt.bufPrint(&line, "display: Intel {x:0>4}, pipe A {d} x {d}, plane 1 {s} at GTT {x}, stride {d} blocks\n", .{

            self.device,
            size.width,
            size.height,
            if (control >> 31 != 0) "on" else "off",
            self.read(plane_surface) & 0xfffff000,
            self.read(plane_stride) & 0x7ff,

        }) catch unreachable);

    }

    fn read(self: *const Intel, offset: usize) u32 {

        return @as(*volatile u32, @ptrFromInt(self.registers + offset)).*;

    }

};
