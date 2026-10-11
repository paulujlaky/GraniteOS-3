pub const canvas = @import("canvas.zig");
pub const Canvas = canvas.Canvas;
pub const Corners = canvas.Corners;
pub const Rect = canvas.Rect;
pub const Point = canvas.Point;
pub const shade = canvas.shade;

pub const draw = @import("draw.zig");
pub const List = draw.List;

pub const font = @import("font.zig");
pub const Font = font.Font;
pub const Face = font.Face;
pub const Icon = font.Icon;
pub const sans = font.sans;
pub const theme = @import("theme.zig");
pub const png = @import("png.zig");

pub const style = @import("style.zig");
pub const Style = style.Style;
pub const Paint = style.Paint;
pub const Edges = style.Edges;

pub const Node = @import("node.zig").Node;
pub const Text = @import("text.zig").Text;
pub const leading = @import("text.zig").leading;
pub const Image = @import("image.zig").Image;
pub const Prompt = @import("prompt.zig").Prompt;

pub const Surface = @import("surface.zig").Surface;
pub const screen = @import("surface.zig").screen;
pub const display = &@import("image.zig").display;
pub const Window = @import("window.zig").Window;
pub const Layer = @import("window.zig").Layer;
pub const Input = @import("window.zig").Input;
pub const wait = @import("window.zig").wait;

/// A container laying out `children` as `look` says.
pub fn box(look: Style, children: []const *Node) Node {

    return .{

        .style = look,
        .content = .{

            .box = children,

        },

    };

}

pub fn label(string: []const u8, look: Style) Node {

    return .{

        .style = look,
        .content = .{

            .label = string,

        },

    };

}

pub fn button(string: []const u8, action: *const fn (*Node) void) Node {

    var result = label(string, theme.button);

    result.action = action;

    return result;

}

/// A label showing `which` in the icon face, styled by `look`, such as `theme.icon`.
pub fn icon(which: Icon, look: Style) Node {

    return label(which.text(), look.with(.{

        .face = .icons,

    }));

}

/// A square toolbar button showing `which`.
pub fn tool(which: Icon, action: *const fn (*Node) void) Node {

    var result = label(which.text(), theme.tool);

    result.action = action;

    return result;

}

pub fn input(edit: *Text) Node {

    return .{

        .style = theme.input,
        .content = .{

            .input = edit,

        },

    };

}

/// A multi-line text field that wraps and scrolls.
pub fn area(edit: *Text) Node {

    return .{

        .style = theme.area,
        .content = .{

            .area = edit,

        },

    };

}

pub fn picture(shown: *Image, look: Style) Node {

    return .{

        .style = look,
        .content = .{

            .image = shown,

        },

    };

}

/// A node the app draws itself, sized by `look`.
pub fn custom(record: *const fn (*Node, *List) void, look: Style) Node {

    return .{

        .style = look,
        .content = .{

            .custom = record,

        },

    };

}
