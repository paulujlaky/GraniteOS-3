//! A slider: a thin track filled up to a round knob, pressed or dragged anywhere along it to set a value from zero to one,
//! such as a volume or a place in a song.

const std = @import("std");

const canvas = @import("canvas.zig");
const draw = @import("draw.zig");
const style = @import("style.zig");
const theme = @import("theme.zig");

const Node = @import("node.zig").Node;
const Track = @import("node.zig").Track;

/// The knob's diameter and the track's thickness, in pixels before scaling.
const knob = 14;
const thickness = 4;

pub const Slider = struct {

    value: f32 = 0,

    /// Runs as a press or drag moves the value, with `done` set once the button comes up.
    changed: *const fn (self: *Slider, done: bool) void,

    /// Moves the value by `step`, as arrow keys might, and tells `changed`.
    pub fn nudge(self: *Slider, step: f32) void {

        self.value = std.math.clamp(self.value + step, 0, 1);
        self.changed(self, true);

    }

    /// A node drawing the slider and following the pointer over it, sized by `look`.
    pub fn node(self: *Slider, look: style.Style) Node {

        var result = Node{

            .style = look,
            .content = .{

                .custom = &record,

            },
            .track = &follow,
            .cursor = .hand,
            .data = @intFromPtr(self),

        };

        if (result.style.height == null) result.style.height = knob + 6;

        return result;

    }

    fn record(owner: *Node, target: *draw.List) void {

        const self: *Slider = @ptrFromInt(owner.data);
        const area = owner.inner();
        const size = style.px(knob);
        const bar = style.px(thickness);
        const span = @max(area.width - size, 1);
        const middle = area.y + @divTrunc(area.height, 2);
        const x = area.x + @as(i32, @intFromFloat(@round(std.math.clamp(self.value, 0, 1) * @as(f32, @floatFromInt(span)))));

        const track = canvas.Rect{

            .x = area.x + @divTrunc(size, 2),
            .y = middle - @divTrunc(bar, 2),
            .width = span,
            .height = bar,

        };

        target.round(track, @divTrunc(bar, 2), theme.selected);

        target.round(.{

            .x = track.x,
            .y = track.y,
            .width = x - area.x,
            .height = bar,

        }, @divTrunc(bar, 2), theme.accent);

        target.round(.{

            .x = x,
            .y = middle - @divTrunc(size, 2),
            .width = size,
            .height = size,

        }, @divTrunc(size, 2), theme.accent);

    }

    fn follow(owner: *Node, motion: Track) void {

        const self: *Slider = @ptrFromInt(owner.data);
        const area = owner.inner();
        const size = style.px(knob);
        const span: f32 = @floatFromInt(@max(area.width - size, 1));

        self.value = std.math.clamp(@as(f32, @floatFromInt(motion.at.x - area.x - @divTrunc(size, 2))) / span, 0, 1);
        self.changed(self, motion.phase == .up);

    }

};
