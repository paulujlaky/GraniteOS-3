const canvas = @import("canvas.zig");
const draw = @import("draw.zig");
const image = @import("image.zig");

const api = @import("api");

/// A window's drawing commands, rendered by the display; re-attached automatically if the display restarts.
pub const Surface = struct {

    /// Records into the half of the buffer the display is not showing.
    list: draw.List,
    spec: api.display.Spec,
    memory: api.Shared,
    half: u1 = 0,

    id: u64 = 0,
    attached: bool = false,

    /// Taken off the screen until the next `present` after `hidden` clears.
    hidden: bool = false,

    /// Allocates `capacity` bytes for each half of the command buffer; nothing shows until the first `present`.
    pub fn open(spec: api.display.Spec, capacity: usize) !Surface {

        const memory = try api.share(2 * capacity / 4096);

        return .{

            .list = .{

                .bytes = memory.bytes[0..capacity],
                .width = spec.area.width,
                .height = spec.area.height,

            },
            .spec = spec,
            .memory = memory,

        };

    }

    /// Shows what the list recorded, then starts a fresh list in the other half.
    pub fn present(self: *Surface) !void {

        if (self.hidden) return;

        const half = self.memory.bytes.len / 2;

        for (0..2) |_| {

            if (!self.attached) {

                self.id = try image.display.surface(self.memory.handle, self.spec);
                self.attached = true;

                // A restarted display forgot our images along with our surfaces.
                image.republish();

            }

            image.display.present(self.id, self.half, self.list.length) catch |err| {

                if (err != error.Missing and err != error.Denied and err != error.Invalid) return err;
                self.attached = false;
                continue;

            };

            self.half +%= 1;
            self.list.bytes = self.memory.bytes[@as(usize, self.half) * half ..][0..half];
            self.list.reset();

            return;

        }

        return error.Missing;

    }

    /// Moves, resizes, restacks, or retitles the surface.
    pub fn place(self: *Surface, spec: api.display.Spec) !void {

        self.resized(spec);
        if (!self.attached) return;

        image.display.place(self.id, spec) catch |err| {

            if (err != error.Missing and err != error.Denied) return err;
            self.attached = false;

        };

    }

    /// Takes in a placement the display already made.
    pub fn resized(self: *Surface, spec: api.display.Spec) void {

        self.spec = spec;
        self.list.width = spec.area.width;
        self.list.height = spec.area.height;

    }

    /// Takes the surface off the screen; the next `present` after clearing `hidden` brings it back.
    pub fn hide(self: *Surface) void {

        self.hidden = true;
        if (!self.attached) return;

        image.display.place(self.id, removal) catch {

        };
        self.attached = false;

    }

};

/// A placement the display reads as a request to drop the surface.
const removal = api.display.Spec{};

/// The screen's size, from the display service.
pub fn screen() !canvas.Rect {

    const size = try image.display.size();

    return .{

        .width = size.width,
        .height = size.height,

    };

}
