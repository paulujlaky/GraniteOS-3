const canvas = @import("canvas.zig");
const font = @import("font.zig");
const theme = @import("theme.zig");

pub const Alignment = canvas.Alignment;

/// The interface scale in percent, as the display reports it: styles give lengths at 100%, and layout multiplies them by this.
pub var scale: i32 = 100;

/// `length`, given at 100%, in pixels at the interface scale.
pub fn px(length: i32) i32 {

    return @divTrunc(length * scale + if (length < 0) @as(i32, -50) else 50, 100);

}

/// The interface scale as a factor, for font sizes.
pub fn factor() f32 {

    return @as(f32, @floatFromInt(scale)) / 100;

}

pub const Direction = enum {

    column,
    row,

    /// Every child fills the container, each drawn over the last.
    stack,

};

/// Placement along an axis; `stretch` fills the cross axis and acts as `start` on the main one.
pub const Align = enum {

    start,
    center,
    end,
    stretch,

};

pub const Edges = struct {

    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
    left: i32 = 0,

    pub fn all(amount: i32) Edges {

        return .{

            .top = amount,
            .right = amount,
            .bottom = amount,
            .left = amount,

        };

    }

    pub fn axes(vertical: i32, horizontal: i32) Edges {

        return .{

            .top = vertical,
            .right = horizontal,
            .bottom = vertical,
            .left = horizontal,

        };

    }

    pub fn scaled(self: Edges) Edges {

        return .{

            .top = px(self.top),
            .right = px(self.right),
            .bottom = px(self.bottom),
            .left = px(self.left),

        };

    }

    pub fn shrink(self: Edges, area: canvas.Rect) canvas.Rect {

        return .{

            .x = area.x + self.left,
            .y = area.y + self.top,
            .width = area.width - self.left - self.right,
            .height = area.height - self.top - self.bottom,

        };

    }

};

/// Colours a state overrides; null keeps the base style's.
pub const Paint = struct {

    background: ?u32 = null,
    color: ?u32 = null,
    border: ?u32 = null,

    fn over(self: Paint, top: Paint) Paint {

        return .{

            .background = top.background orelse self.background,
            .color = top.color orelse self.color,
            .border = top.border orelse self.border,

        };

    }

};

/// A node's box, flex layout, and look, with per-state colour overrides like CSS pseudo-classes.
pub const Style = struct {

    /// Fixed size; null sizes to content.
    width: ?i32 = null,
    height: ?i32 = null,

    /// Share of a container's spare main-axis space, like `flex-grow`.
    grow: u8 = 0,

    padding: Edges = .{},

    /// How a container lays out its children.
    direction: Direction = .column,
    gap: i32 = 0,
    justify: Align = .start,
    items: Align = .stretch,

    /// Lets children run past the container along its main axis, scrolled into view by the wheel and focus.
    scroll: bool = false,

    background: ?u32 = null,

    /// Draws the background as a tint over Quartz, showing what lies behind the node softened.
    quartz: bool = false,

    color: u32 = theme.text,
    border: ?u32 = null,
    border_width: i32 = 0,
    radius: i32 = 0,

    face: font.Face = .sans,
    size: f32 = theme.body,
    text_align: Alignment = .left,

    /// Placeholder text and secondary content.
    muted: u32 = theme.muted,

    hover: Paint = .{},
    selected: Paint = .{},
    focus: Paint = .{},
    pressed: Paint = .{},
    invalid: Paint = .{},

    /// This style with the fields of struct `changes` replaced, like an inline style over a class.
    pub fn with(self: Style, changes: anytype) Style {

        return merge(Style, self, changes);

    }

    /// This style's lengths and text size at the interface scale; borders scale down, so hairlines stay one pixel.
    pub fn scaled(self: Style) Style {

        if (scale == 100) return self;

        var result = self;

        if (self.width) |width| result.width = px(width);
        if (self.height) |height| result.height = px(height);

        result.padding = self.padding.scaled();
        result.gap = px(self.gap);
        result.radius = px(self.radius);
        result.border_width = if (self.border_width > 0) @max(@divTrunc(self.border_width * scale, 100), 1) else 0;
        result.size = self.size * factor();

        return result;

    }

    /// The colours for a node in the given states; later states win.
    pub fn paint(self: *const Style, state: State) Paint {

        var result = Paint{

            .background = self.background,
            .color = self.color,
            .border = self.border,

        };

        if (state.hover) result = result.over(self.hover);
        if (state.selected) result = result.over(self.selected);
        if (state.focus) result = result.over(self.focus);
        if (state.pressed) result = result.over(self.pressed);
        if (state.invalid) result = result.over(self.invalid);

        return result;

    }

};

/// `base` with the fields `changes` names replaced, reaching into nested structs such as `Paint` and `Edges`.
fn merge(comptime T: type, base: T, changes: anytype) T {

    const Changes = @TypeOf(changes);

    if (Changes == T or @typeInfo(T) != .@"struct" or @typeInfo(Changes) != .@"struct") return changes;

    var result = base;

    inline for (@typeInfo(Changes).@"struct".fields) |field| {

        const Field = @TypeOf(@field(result, field.name));

        @field(result, field.name) = merge(Field, @field(result, field.name), @field(changes, field.name));

    }

    return result;

}

pub const State = struct {

    hover: bool = false,
    selected: bool = false,
    focus: bool = false,
    pressed: bool = false,
    invalid: bool = false,

};
