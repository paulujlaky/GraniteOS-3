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
pub const quartz = @import("quartz.zig");
pub const png = @import("png.zig");
pub const cursor = @import("cursor.zig");
pub const Cursor = cursor.Cursor;

pub const style = @import("style.zig");
pub const Style = style.Style;
pub const Paint = style.Paint;
pub const Edges = style.Edges;

pub const Node = @import("node.zig").Node;
pub const Track = @import("node.zig").Track;
pub const Drag = @import("node.zig").Drag;
pub const Text = @import("text.zig").Text;
pub const leading = @import("text.zig").leading;
pub const ascent = @import("text.zig").ascent;
pub const Image = @import("image.zig").Image;
pub const Graph = @import("graph.zig").Graph;
pub const sketch = @import("sketch.zig");
pub const Sketch = sketch.Sketch;
pub const Figure = sketch.Figure;
pub const Dialog = @import("dialog.zig").Dialog;
pub const menu = @import("menu.zig");
pub const Menu = menu.Menu;
pub const Choice = menu.Choice;

pub const Surface = @import("surface.zig").Surface;
pub const screen = @import("surface.zig").screen;
pub const display = &@import("image.zig").display;
pub const Window = @import("window.zig").Window;
pub const Layer = @import("window.zig").Layer;
pub const Input = @import("window.zig").Input;
pub const wait = @import("window.zig").wait;
pub const lost = &@import("window.zig").restarts;

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

/// A node showing `shown`, a graph the app keeps; invalidate it and the node after changing its values.
pub fn chart(shown: *Graph, look: Style) Node {

    return figure(&shown.figure, look);

}

/// A node showing `shown`, a figure the app keeps and paints with a `Sketch`.
pub fn figure(shown: *Figure, look: Style) Node {

    var result = custom(&Figure.recorder, look);

    result.data = @intFromPtr(shown);

    return result;

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
