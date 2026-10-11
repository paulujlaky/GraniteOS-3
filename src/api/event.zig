/// One input event, small enough to travel as a single IPC word.
pub const Event = packed struct(u64) {

    kind: Kind = .none,

    /// Key events: pressed or released. Button events: went down or up.
    pressed: bool = false,
    modifiers: Modifiers = .{},

    /// Key events: a `Key`. Button events: the button index, 0 left, 1 right, 2 middle, then 3 and 4 for one wheel step up (away from the user) and down, which only press.
    /// Motion and pointer events: held buttons, one bit per index.
    code: u8 = 0,

    /// The typed character of a key event as a Unicode code point, or zero.
    char: u16 = 0,

    /// Motion events carry a relative delta; pointer and button events a position in surface coordinates; resize events the surface's new size.
    /// From the input service to the display, pointer events instead carry an absolute position scaled so 0..32767 spans the screen from its top-left corner, and button events none.
    x: i16 = 0,
    y: i16 = 0,

    pub const Kind = enum(u3) {

        none,
        key,
        motion,
        pointer,
        button,

        /// The window manager's close control was clicked.
        close,

        /// The surface changed size; `x` and `y` carry its new width and height.
        resize,

        /// The window manager reports a change; `code` holds a `Notice`.
        notice,

    };

    pub const Notice = enum(u8) {

        /// Windows opened, closed, or changed title, focus, or state; only the session hears it.
        windows,
        _,

    };

    pub const Modifiers = packed struct(u4) {

        shift: bool = false,
        control: bool = false,
        alt: bool = false,
        super: bool = false,

    };

    pub fn key(self: Event) Key {

        return @enumFromInt(self.code);

    }

    /// Whether this is a key press of `which` regardless of modifiers.
    pub fn pressing(self: Event, which: Key) bool {

        return self.kind == .key and self.pressed and self.key() == which;

    }

    /// Whether this is a press of `which` with exactly `held` modifiers.
    pub fn chord(self: Event, held: Modifiers, which: u8) bool {

        return self.kind == .key and self.pressed and @as(u4, @bitCast(self.modifiers)) == @as(u4, @bitCast(held)) and self.char | 0x20 == which;

    }

};

/// Physical keys; printable keys report `.character` with the typed character in `Event.char`.
pub const Key = enum(u8) {

    none,
    character,
    escape,
    enter,
    backspace,
    tab,
    left,
    right,
    up,
    down,
    home,
    end,
    insert,
    delete,
    page_up,
    page_down,
    shift,
    control,
    alt,
    super,
    caps_lock,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    _,

};
