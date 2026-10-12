//! The flat monochrome look shared by every surface: graphite surfaces, white text, and light grey for focus and selection.

const style = @import("style.zig");

const Style = style.Style;
const Edges = style.Edges;

/// Behind every window.
pub const desktop = 0x0c0c0c;

pub const background = 0x141414;
pub const raised = 0x1b1b1b;
pub const field = 0x232323;
pub const hover = 0x2a2a2a;
pub const selected = 0x333333;
pub const line = 0x2c2c2c;

pub const text = 0xe8e8e8;
pub const muted = 0x8c8c8c;
pub const faint = 0x5a5a5a;

/// Focus rings, primary actions, and active indicators.
pub const accent = 0xeeeeee;
pub const danger = 0xe5534b;

/// Dark translucent chrome over the desktop, such as the bar, dock, and tags; the top byte is transparency, as `canvas.shade` makes it.
pub const glass = 0x17101010;

/// An area swept out with the pointer, as when selecting: a faint white fill inside a lighter, softly rounded edge.
pub const sweep_fill = 0xe6ffffff;
pub const sweep_edge = 0x73ffffff;
pub const sweep_radius = 4;

pub const radius = 6;
pub const corner = 10;
pub const border = 1;
pub const spacing = 12;
pub const gap = 8;

pub const body: f32 = 15;
pub const small: f32 = 13;
pub const heading: f32 = 20;
pub const large: f32 = 30;

/// Height of single-line controls such as fields and buttons.
pub const control = 32;

/// Height of a window's title bar, drawn by the window manager.
pub const title = 34;

/// Base styles for the stock widgets; tweak them per node with `Style.with`.
pub const panel = Style{

    .padding = .all(spacing),
    .gap = spacing,

    .background = raised,
    .radius = corner,

};

pub const button = Style{

    .height = control,
    .padding = .axes(0, 14),

    .background = field,
    .border = line,
    .border_width = border,
    .radius = radius,
    .text_align = .center,

    .hover = .{

        .background = hover,

    },
    .focus = .{

        .border = accent,

    },
    .pressed = .{

        .background = selected,

    },
    .selected = .{

        .background = selected,
        .border = faint,

    },

};

/// The one action a view most expects, drawn light on dark.
pub const primary = button.with(.{

    .background = accent,
    .border = accent,
    .color = background,

    .hover = .{

        .background = 0xffffff,
        .border = 0xffffff,

    },
    .focus = .{

        .border = 0xffffff,

    },
    .pressed = .{

        .background = 0xcccccc,
        .border = 0xcccccc,

    },

});

/// The action a confirmation asks for when it cannot be undone, such as deleting.
pub const destructive = button.with(.{

    .background = danger,
    .border = danger,
    .color = 0xffffff,

    .hover = .{

        .background = 0xf06a62,
        .border = 0xf06a62,

    },
    .focus = .{

        .border = 0xffffff,

    },
    .pressed = .{

        .background = 0xc9463f,
        .border = 0xc9463f,

    },

});

/// The raised, bordered card of a pop-up list or launcher.
pub const popup = Style{

    .padding = .all(6),
    .gap = 2,

    .background = raised,
    .border = line,
    .border_width = border,
    .radius = corner,

};

/// A dialog's card, centred over the window it asks for.
pub const card = popup.with(.{

    .width = 400,
    .padding = Edges.all(20),
    .gap = spacing,

});

/// Laid over a window's content while a dialog asks something of it.
pub const dim = 0x80000000;

/// A borderless square button showing an icon, as in toolbars.
pub const tool = Style{

    .width = control,
    .height = control,

    .radius = radius,
    .face = .icons,
    .size = 16,
    .text_align = .center,

    .hover = .{

        .background = hover,

    },
    .focus = .{

        .background = hover,

    },
    .pressed = .{

        .background = selected,

    },
    .selected = .{

        .background = selected,

    },

};

pub const input = Style{

    .height = control,
    .padding = .axes(0, 10),

    .background = field,
    .border = line,
    .border_width = border,
    .radius = radius,

    .focus = .{

        .border = accent,

    },
    .invalid = .{

        .border = danger,

    },

};

pub const area = input.with(.{

    .height = 5 * control,
    .padding = Edges.all(10),

});

/// A selectable line in a list, such as a file or an account.
pub const item = Style{

    .height = 34,
    .padding = .axes(0, 10),
    .direction = .row,
    .gap = 10,
    .items = .center,

    .radius = radius,

    .hover = .{

        .background = hover,

    },
    .selected = .{

        .background = selected,

    },
    .focus = .{

        .background = hover,

    },

};

/// A row of controls along the top of a view.
pub const bar = Style{

    .height = 44,
    .padding = .axes(6, gap),
    .direction = .row,
    .gap = gap / 2,
    .items = .center,

    .background = raised,

};

/// An icon beside text, such as in list rows.
pub const icon = Style{

    .width = 18,
    .face = .icons,
    .size = 16,
    .text_align = .center,

};

pub const caption = Style{

    .size = small,
    .color = muted,

};

pub const title_text = Style{

    .size = heading,

};

/// A short upright line between groups of tools.
pub const divider = Style{

    .width = border,
    .height = 20,
    .background = line,

};

/// A one-pixel rule between sections.
pub const rule = Style{

    .height = border,
    .background = line,

};

/// Fills the space it is given, pushing its siblings apart.
pub const spring = Style{

    .grow = 1,

};
