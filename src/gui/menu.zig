//! Pop-up lists of choices, such as an app's right-click menus and the desktop's session menu.

const api = @import("api");

const canvas = @import("canvas.zig");
const font = @import("font.zig");
const node = @import("node.zig");
const root = @import("root.zig");
const theme = @import("theme.zig");
const window = @import("window.zig");

const Node = node.Node;
const Window = window.Window;

/// Narrowest a menu gets, however short its choices.
const narrowest = 200;

pub const Choice = struct {

    icon: ?font.Icon = null,

    /// Empty for a rule between groups of choices; see `separator`.
    title: []const u8 = "",

    /// A key that does the same, shown at the right, such as `Del`.
    hint: []const u8 = "",

    run: *const fn () void = nothing,

    /// Asked each time the menu shows; a choice it refuses is greyed out.
    enabled: ?*const fn () bool = null,

};

/// A rule between groups of choices.
pub const separator = Choice{};

/// A menu of `choices`, hidden until shown; choosing one closes it, then runs it.
/// It opens over everything, takes the keys while it shows, and closes on Escape or a press anywhere else.
pub fn Menu(comptime choices: []const Choice) type {

    return struct {

        const Self = @This();

        icons: [choices.len]Node = undefined,
        labels: [choices.len]Node = undefined,
        hints: [choices.len]Node = undefined,
        parts: [choices.len][3]*Node = undefined,
        rows: [choices.len]Node = undefined,
        list: [choices.len]*Node = undefined,
        root: Node = undefined,
        window: Window = undefined,

        /// The window whose content `show` places it in, which waits on it; null places it on the screen.
        owner: ?*Window = null,

        /// Builds the menu where it will stay; an `owner` takes its events along with its own.
        pub fn init(self: *Self, owner: ?*Window) void {

            for (choices, 0..) |*choice, index| {

                if (choice.title.len == 0) {

                    self.icons[index] = root.box(theme.rule, &.{});
                    self.parts[index][0] = &self.icons[index];

                    self.rows[index] = root.box(.{

                        .padding = .axes(theme.gap / 2 - 1, 4),

                    }, self.parts[index][0..1]);

                    self.list[index] = &self.rows[index];
                    continue;

                }

                self.icons[index] = if (choice.icon) |which| root.icon(which, theme.icon) else root.box(theme.icon, &.{});

                self.labels[index] = root.label(choice.title, .{

                    .grow = 1,

                });

                self.hints[index] = root.label(choice.hint, theme.caption);
                self.parts[index] = .{ &self.icons[index], &self.labels[index], &self.hints[index] };
                self.rows[index] = root.box(theme.item, &self.parts[index]);
                self.rows[index].action = &choose;
                self.rows[index].data = index;
                self.list[index] = &self.rows[index];

            }

            self.owner = owner;
            self.root = root.box(theme.popup, &self.list);

            const size = self.root.measure();

            self.window = Window.open(&self.root, .{

                .layer = .popup,

                .width = @max(size.width + theme.spacing, narrowest),
                .height = size.height,

                .hidden = true,
                .shadow = true,
                .motion = .drop,

            }) catch api.exit(3);

            self.window.react = &react;
            if (owner) |parent| parent.adopt(&self.window);

        }

        /// Shows the menu with its top-left corner at `at`, in the owner's content or on the screen; the display keeps it on the screen.
        pub fn show(self: *Self, at: canvas.Point) void {

            for (choices, 0..) |*choice, index| {

                const check = choice.enabled orelse continue;
                const on = check();

                self.rows[index].action = if (on) &choose else null;
                self.labels[index].style.color = if (on) theme.text else theme.faint;
                self.icons[index].style.color = self.labels[index].style.color;

            }

            var area = self.window.surface.list.bounds();

            area.x = at.x;
            area.y = at.y;
            self.window.surface.spec.anchor = if (self.owner) |parent| @intCast(parent.surface.id) else api.display.Spec.none;
            self.window.focus(null);
            self.window.move(area);
            self.window.show();

        }

        pub fn hide(self: *Self) void {

            if (!self.window.surface.hidden) self.window.hide();

        }

        pub fn shown(self: *const Self) bool {

            return !self.window.surface.hidden;

        }

        fn choose(row: *Node) void {

            const first: [*]Node = @ptrCast(row);
            const rows: *[choices.len]Node = @ptrCast(first - row.data);
            const self: *Self = @fieldParentPtr("rows", rows);

            self.hide();
            choices[row.data].run();

        }

        /// Steps through the choices with the arrows, and closes on Escape or when the display closes it.
        fn react(menu: *Window, event: api.Event) bool {

            const self: *Self = @fieldParentPtr("window", menu);

            if (event.kind == .close or event.pressing(.escape)) {

                self.hide();
                return true;

            }

            if (event.kind != .key or !event.pressed) return false;

            const step: isize = switch (event.key()) {

                .down, .home => 1,
                .up, .end => -1,
                else => return false,

            };

            const start: isize = if (event.key() == .home) -1 else if (event.key() == .end) choices.len else if (menu.focused) |row| @intCast(row.data) else if (step > 0) -1 else choices.len;
            var index = start;

            // Separators and greyed-out choices are passed over, wrapping at either end.
            for (0..choices.len) |_| {

                index = @mod(index + step, @as(isize, choices.len));

                const row = &self.rows[@intCast(index)];

                if (row.action != null) {

                    menu.focus(row);
                    break;

                }

            }

            return true;

        }

    };

}

fn nothing() void {

}
