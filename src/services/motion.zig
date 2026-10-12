//! Surface transitions: where a surface sits between its resting pose and another, over a few timer ticks.

const std = @import("std");

const api = @import("api");
const gui = @import("gui");

const Motion = api.display.Motion;

/// How a surface is shown: scaled about its centre, then moved, then faded.
pub const Pose = struct {

    scale: f32 = 1,
    x: f32 = 0,
    y: f32 = 0,
    opacity: f32 = 1,

    pub const rest = Pose{};

    /// Where `area`, part of a surface covering `around`, lands as left, top, right, and bottom pixel edges.
    pub fn box(self: Pose, area: gui.Rect, around: gui.Rect) [4]f32 {

        const x = @as(f32, @floatFromInt(around.x)) + @as(f32, @floatFromInt(around.width)) / 2;
        const y = @as(f32, @floatFromInt(around.y)) + @as(f32, @floatFromInt(around.height)) / 2;

        return .{

            x + (@as(f32, @floatFromInt(area.x)) - x) * self.scale + self.x,
            y + (@as(f32, @floatFromInt(area.y)) - y) * self.scale + self.y,
            x + (@as(f32, @floatFromInt(area.right())) - x) * self.scale + self.x,
            y + (@as(f32, @floatFromInt(area.bottom())) - y) * self.scale + self.y,

        };

    }

    /// The whole pixels a surface covering `area` touches in this pose.
    pub fn bounds(self: Pose, area: gui.Rect) gui.Rect {

        const edges = self.box(area, area);
        const left: i32 = @intFromFloat(@floor(edges[0]));
        const top: i32 = @intFromFloat(@floor(edges[1]));

        return .{

            .x = left,
            .y = top,
            .width = @as(i32, @intFromFloat(@ceil(edges[2]))) - left,
            .height = @as(i32, @intFromFloat(@ceil(edges[3]))) - top,

        };

    }

    fn mix(from: Pose, to: Pose, t: f32) Pose {

        return .{

            .scale = from.scale + (to.scale - from.scale) * t,
            .x = from.x + (to.x - from.x) * t,
            .y = from.y + (to.y - from.y) * t,
            .opacity = from.opacity + (to.opacity - from.opacity) * t,

        };

    }

};

/// What a transition is for, so the display knows what to do once it ends.
pub const Purpose = enum {

    enter,
    leave,
    minimize,
    restore,

};

/// A move from one pose to another, starting at tick `start`.
pub const Transition = struct {

    from: Pose,
    to: Pose,
    start: u64,
    length: u64,
    purpose: Purpose,

    /// Begins `purpose` from `from`, the pose now showing, to `to`.
    pub fn begin(purpose: Purpose, from: Pose, to: Pose, length: u64) Transition {

        return .{

            .from = from,
            .to = to,
            .start = api.ticks(),
            .length = @max(length, 1),
            .purpose = purpose,

        };

    }

    pub fn pose(self: *const Transition, now: u64) Pose {

        return Pose.mix(self.from, self.to, ease(self.progress(now)));

    }

    pub fn done(self: *const Transition, now: u64) bool {

        return self.progress(now) >= 1;

    }

    fn progress(self: *const Transition, now: u64) f32 {

        return @min(@as(f32, @floatFromInt(now -| self.start)) / @as(f32, @floatFromInt(self.length)), 1);

    }

};

/// The pose `motion` comes in from and goes out to, and how many ticks it takes; null when it shows at once.
pub fn away(motion: Motion) ?struct { pose: Pose, length: u64 } {

    return switch (motion) {

        .zoom => .{ .pose = .{ .scale = 0.94, .opacity = 0 }, .length = 16 },
        .drop => .{ .pose = .{ .scale = 0.98, .y = -8, .opacity = 0 }, .length = 13 },
        .rise => .{ .pose = .{ .scale = 0.98, .y = 8, .opacity = 0 }, .length = 13 },
        .fade => .{ .pose = .{ .opacity = 0 }, .length = 12 },
        else => null,

    };

}

/// Ticks a window takes to fly to or from the dock.
pub const tuck = 22;

/// The pose that shrinks `area` into `target` and fades it out, for minimising.
pub fn shrink(area: gui.Rect, target: gui.Point) Pose {

    return .{

        .scale = 0.2,
        .x = @as(f32, @floatFromInt(target.x - area.x)) - @as(f32, @floatFromInt(area.width)) / 2,
        .y = @as(f32, @floatFromInt(target.y - area.y)) - @as(f32, @floatFromInt(area.height)) / 2,
        .opacity = 0,

    };

}

/// Ticks a panel takes to tuck away beneath a tiled window or come back.
pub const slide = 14;

/// The pose that slides `area` down past `floor`, the bottom of the screen, for tucking a panel away.
pub fn sink(area: gui.Rect, floor: i32) Pose {

    return .{

        .y = @floatFromInt(floor - area.y),

    };

}

/// Eases out: quick to start, settling gently.
fn ease(t: f32) f32 {

    const left = 1 - t;

    return 1 - left * left * left;

}
