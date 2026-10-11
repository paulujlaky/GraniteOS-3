//! Pop-up lists of choices on the desktop, such as the session menu and the wallpaper's right-click menu.

const api = @import("api");
const gui = @import("gui");

const desktop = @import("desktop.zig");

const theme = gui.theme;

/// The raised, bordered look of every pop-up surface the desktop shows.
pub const popup = gui.Style{

    .padding = .all(6),
    .gap = 2,

    .background = theme.raised,
    .border = theme.line,
    .border_width = theme.border,
    .radius = theme.corner,

};

const width = 210;
const row = 34;

pub const Choice = struct {

    icon: gui.Icon,
    title: []const u8,
    run: *const fn () void,

};

/// A menu of `choices`, hidden until shown somewhere; choosing one closes every pop-up, then runs it.
pub fn Menu(comptime choices: []const Choice) type {

    return struct {

        const Self = @This();

        icons: [choices.len]gui.Node = undefined,
        labels: [choices.len]gui.Node = undefined,
        parts: [choices.len][2]*gui.Node = undefined,
        rows: [choices.len]gui.Node = undefined,
        list: [choices.len]*gui.Node = undefined,
        root: gui.Node = undefined,
        window: gui.Window = undefined,

        /// Builds the menu where it will stay.
        pub fn init(self: *Self) void {

            for (choices, 0..) |*choice, index| {

                self.icons[index] = gui.icon(choice.icon, theme.icon);
                self.labels[index] = gui.label(choice.title, .{});
                self.parts[index] = .{ &self.icons[index], &self.labels[index] };
                self.rows[index] = gui.box(theme.item, &self.parts[index]);
                self.rows[index].action = &choose;
                self.rows[index].data = @intFromPtr(choice);
                self.list[index] = &self.rows[index];

            }

            self.root = gui.box(popup, &self.list);
            self.window = gui.Window.open(&self.root, .{

                .layer = .panel,
                .width = width,
                .height = @intCast(choices.len * row + 12 + (choices.len - 1) * popup.gap),
                .hidden = true,
                .motion = .drop,

            }) catch api.exit(3);

        }

        /// Shows the menu with its top-left corner at `at`, kept on a `screen`-sized display.
        pub fn show(self: *Self, at: gui.Point, screen: gui.Rect) void {

            self.put(at, screen);
            self.window.show();

        }

        /// Moves the menu as `show` would, without showing it.
        pub fn put(self: *Self, at: gui.Point, screen: gui.Rect) void {

            var area = self.window.surface.list.bounds();

            area.x = @max(@min(at.x, screen.width - area.width - 8), 8);
            area.y = @max(@min(at.y, screen.height - area.height - 8), 8);
            self.window.move(area);

        }

        pub fn hide(self: *Self) void {

            if (!self.window.surface.hidden) self.window.hide();

        }

        pub fn shown(self: *const Self) bool {

            return !self.window.surface.hidden;

        }

        fn choose(node: *gui.Node) void {

            const choice: *const Choice = @ptrFromInt(node.data);

            desktop.dismiss();
            choice.run();

        }

    };

}
