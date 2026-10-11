const canvas = @import("canvas.zig");
const draw = @import("draw.zig");
const image = @import("image.zig");
const node = @import("node.zig");
const surface = @import("surface.zig");
const text = @import("text.zig");
const theme = @import("theme.zig");

const api = @import("api");

const Node = node.Node;
const Rect = canvas.Rect;
const Point = canvas.Point;

pub const Layer = api.display.Layer;

/// Most ticks between the clicks of a double-click.
const double = 40;

/// Pixels one wheel step scrolls.
const step = 48;

const control = api.Event.Modifiers{

    .control = true,

};

pub const Options = struct {

    title: []const u8 = "",
    layer: Layer = .window,

    /// The app the window belongs to, so the dock can group its windows.
    application: ?api.abi.Image = null,

    /// Content size; null fills the screen and follows it.
    width: ?i32 = null,
    height: ?i32 = null,

    /// Where undecorated surfaces sit; the window manager places decorated ones.
    x: i32 = 0,
    y: i32 = 0,

    /// No resizing or maximising.
    fixed: bool = false,

    /// Starts off the screen until `show`.
    hidden: bool = false,

    /// How it animates as it shows and hides.
    motion: api.display.Motion = .auto,

    /// Bytes for each half of the command buffer.
    capacity: usize = draw.capacity,

};

/// An event no node handled, and the window it came to.
pub const Input = struct {

    window: *Window,
    event: api.Event,

};

/// A surface showing a node tree: lays it out, repaints what changed, and routes input to its nodes.
pub const Window = struct {

    surface: surface.Surface,
    root: *Node,

    focused: ?*Node = null,
    hovered: ?*Node = null,
    pressed: ?*Node = null,

    damage: Rect = .{},

    /// Where the pointer last was, in surface coordinates.
    pointer: Point = .{},

    /// The last click, to spot a double-click.
    clicked: ?*Node = null,
    time: u64 = 0,

    /// The button went down in a text field and is still held, so moving selects.
    selecting: bool = false,

    /// Waits for the display, then opens a window showing `root`.
    pub fn open(root: *Node, options: Options) !Window {

        const screen = while (true) {

            break surface.screen() catch {

                api.sleep(100);
                continue;

            };

        };

        var spec = api.display.Spec.init(.{

            .x = options.x,
            .y = options.y,
            .width = options.width orelse screen.width,
            .height = options.height orelse screen.height,

        }, options.layer, options.title);

        spec.options = .{

            .fill = options.width == null and options.height == null,
            .fixed = options.fixed,

        };

        if (options.application) |application| spec.application = @intCast(@intFromEnum(application));
        spec.motion = options.motion;

        var window = Window{

            .surface = try surface.Surface.open(spec, options.capacity),
            .root = root,

        };

        window.surface.hidden = options.hidden;
        window.refresh();

        return window;

    }

    /// Repaints what changed, then waits up to `timeout` ticks for input; returns events no node handled.
    pub fn next(self: *Window, timeout: u64) ?api.Event {

        const input = wait(&.{self}, timeout) orelse return null;

        return input.event;

    }

    /// Schedules a full repaint, after changes too broad to invalidate node by node.
    pub fn refresh(self: *Window) void {

        self.damage = self.surface.list.bounds();

    }

    /// Schedules `target` to repaint, after changing it in a way that keeps its size.
    pub fn invalidate(self: *Window, target: *const Node) void {

        self.damage = self.damage.join(target.rect);

    }

    /// Swaps in a new tree.
    pub fn view(self: *Window, root: *Node) void {

        self.root = root;
        self.focused = null;
        self.hovered = null;
        self.pressed = null;
        self.refresh();

    }

    pub fn focus(self: *Window, target: ?*Node) void {

        if (self.focused == target) return;
        if (self.focused) |old| self.invalidate(old);
        if (target) |new| {

            self.invalidate(new);
            if (self.root.reveal(new)) self.refresh();

        }

        self.focused = target;

    }

    /// Restacks the window, such as a lock screen dropping below other windows once unlocked.
    pub fn stack(self: *Window, layer: Layer) void {

        var spec = self.surface.spec;
        if (spec.layer == layer) return;

        spec.layer = layer;
        self.surface.place(spec) catch {

        };

    }

    pub fn retitle(self: *Window, title: []const u8) void {

        var spec = self.surface.spec;

        spec.rename(title);
        self.surface.place(spec) catch {

        };

    }

    /// Moves and resizes an undecorated surface, such as a menu.
    pub fn move(self: *Window, area: Rect) void {

        var spec = self.surface.spec;

        spec.area = .{

            .x = area.x,
            .y = area.y,
            .width = area.width,
            .height = area.height,

        };
        self.surface.place(spec) catch {

        };
        self.refresh();

    }

    pub fn hide(self: *Window) void {

        self.surface.hide();
        self.hovered = null;
        self.pressed = null;

    }

    /// Takes the window off the screen at once, rather than when the display next notices the exit, and exits.
    pub fn quit(self: *Window) noreturn {

        self.surface.hide();
        api.exit(0);

    }

    pub fn show(self: *Window) void {

        if (!self.surface.hidden) return;

        self.surface.hidden = false;
        self.refresh();

    }

    fn update(self: *Window) void {

        if (self.surface.hidden) return;

        const bounds = self.surface.list.bounds();
        const target = &self.surface.list;

        self.root.arrange(bounds, &self.damage);

        for ([_]*?*Node{ &self.focused, &self.hovered, &self.pressed }) |mark| {

            if (mark.*) |marked| if (!marked.shown()) {

                mark.* = null;

            };

        }

        if (self.damage.intersect(bounds) == null and self.surface.attached) return;

        // The GPU redraws a whole window cheaply, so every change re-records the tree; a root draws its own background, rounded, and only windows get one when it has none.
        const background = self.root.style.background orelse theme.background;

        self.damage = .{};
        target.reset();
        if (self.root.style.background == null and self.surface.spec.layer == .window) target.fill(bounds, background);
        self.root.paint(target, .{

            .hover = self.hovered,
            .focus = self.focused,
            .pressed = self.pressed,

        }, background);
        self.surface.present() catch self.refresh();

    }

    fn dispatch(self: *Window, event: api.Event) bool {

        const at = Point{

            .x = event.x,
            .y = event.y,

        };

        switch (event.kind) {

            .pointer => {

                self.pointer = at;

                if (self.selecting) if (self.focused) |field| {

                    edited(field).select(field.locate(at), true);
                    self.invalidate(field);

                };

                const target = self.root.hit(at);

                if (target != self.hovered) {

                    if (self.hovered) |old| self.invalidate(old);
                    if (target) |new| self.invalidate(new);
                    self.hovered = target;

                }

                return true;

            },
            .button => return self.button(event, at),
            .key => return self.key(event),
            .resize => {

                var spec = self.surface.spec;

                spec.area.width = event.x;
                spec.area.height = event.y;
                self.surface.resized(spec);
                self.refresh();

                return false;

            },
            else => return false,

        }

    }

    fn button(self: *Window, event: api.Event, at: Point) bool {

        if (event.code == 3 or event.code == 4) {

            const moved = self.root.wheel(at, if (event.code == 3) -step else step) orelse return false;

            self.invalidate(moved);

            return true;

        }

        if (event.code != 0) return false;

        const target = self.root.hit(at);

        if (event.pressed) {

            self.pressed = target;

            const new = target orelse return false;
            const now = api.ticks();
            const repeated = self.clicked == new and now - self.time < double;

            // A third click starts a new pair.
            self.clicked = if (repeated) null else new;
            self.time = now;
            self.invalidate(new);

            // Like most desktops, clicking a button does not steal focus from the field being typed in.
            if (new.editable()) {

                const edit = edited(new);

                self.focus(new);
                if (repeated) edit.word() else edit.select(new.locate(at), event.modifiers.shift);
                self.selecting = !repeated;

            } else if (repeated) {

                if (new.open) |handler| handler(new);

            }

            return true;

        }

        self.selecting = false;

        const was = self.pressed orelse return false;

        self.pressed = null;
        self.invalidate(was);
        if (was == target and !was.editable()) activate(was);

        return true;

    }

    fn key(self: *Window, event: api.Event) bool {

        if (!event.pressed) return false;

        const target = self.focused;
        const typing = target != null and target.?.content == .area;

        if (event.key() == .tab and !event.modifiers.control and !event.modifiers.alt and !typing) {

            self.cycle(event.modifiers.shift);
            return true;

        }

        const focused = target orelse return false;

        switch (focused.content) {

            .input, .area => |edit| {

                const multiline = focused.content == .area;

                if (event.key() == .enter and !multiline) {

                    if (focused.action == null) return false;
                    activate(focused);

                    return true;

                }

                const face = focused.typeface();
                const width = focused.inner().width;
                const shift = event.modifiers.shift;
                const changed = clipboard(edit, event, multiline) or switch (event.key()) {

                    .up, .down => multiline and edit.vertical(face, focused.style.size, width, if (event.key() == .up) -1 else 1, shift),
                    .page_up, .page_down => multiline and edit.vertical(face, focused.style.size, width, (focused.rows() - 1) * @as(i32, if (event.key() == .page_up) -1 else 1), shift),
                    else => edit.key(event, multiline),

                };

                if (!changed) return false;

                focused.invalid = false;
                self.invalidate(focused);

                return true;

            },
            else => {

                const enter = event.key() == .enter;
                if (!enter and !(event.key() == .character and event.char == ' ')) return false;

                if (enter and focused.open != null) {

                    focused.open.?(focused);

                } else {

                    if (focused.action == null) return false;
                    activate(focused);

                }

                return true;

            },

        }

    }

    /// Moves focus to the next focusable node, or the previous one when `backwards`.
    fn cycle(self: *Window, backwards: bool) void {

        var list: [128]*Node = undefined;
        const count = self.root.collect(&list, 0);
        if (count == 0) return;

        const current = for (list[0..count], 0..) |entry, index| {

            if (entry == self.focused) break index;

        } else if (backwards) 0 else count - 1;

        self.focus(list[if (backwards) (current + count - 1) % count else (current + 1) % count]);

    }

};

var pasted: [64 * 1024]u8 = undefined;

/// Repaints every window that changed, then waits up to `timeout` ticks for input to any of them; returns what no node handled.
pub fn wait(windows: []const *Window, timeout: u64) ?Input {

    for (windows) |window| window.update();

    const waited = image.display.wait(timeout) catch {

        // A restarted display lost our surfaces, so the next update shows them afresh.
        for (windows) |window| {

            window.surface.attached = false;
            window.refresh();

        }

        api.sleep(50);

        return null;

    };

    const input = waited orelse return null;

    for (windows) |window| {

        if (!window.surface.attached or window.surface.id != input.surface) continue;

        if (window.dispatch(input.event)) {

            window.update();
            return null;

        }

        return .{

            .window = window,
            .event = input.event,

        };

    }

    return null;

}

/// Copies, cuts, or pastes for a text field; copying with nothing selected passes through, so apps can take the keys.
fn clipboard(edit: *text.Text, event: api.Event, multiline: bool) bool {

    if (event.chord(control, 'c') or event.chord(control, 'x')) {

        const bytes = edit.selected();
        if (bytes.len == 0) return false;

        image.display.copy(bytes) catch {

        };

        if (event.chord(control, 'x')) _ = edit.erase();

        return true;

    }

    if (!event.chord(control, 'v')) return false;

    const bytes = image.display.paste(&pasted) catch return true;
    const usable = if (multiline) bytes else bytes[0 .. @import("std").mem.indexOfAny(u8, bytes, "\r\n") orelse bytes.len];

    _ = edit.paste(usable);

    return true;

}

fn edited(target: *Node) *text.Text {

    return switch (target.content) {

        .input, .area => |edit| edit,
        else => unreachable,

    };

}

fn activate(target: *Node) void {

    if (target.action) |action| action(target);

}
