const node = @import("node.zig");
const root = @import("root.zig");
const text = @import("text.zig");
const theme = @import("theme.zig");
const window = @import("window.zig");

const Node = node.Node;

/// A card over a window's dimmed content asking for one line of text, or just a yes, before running an action.
/// Enter confirms, Escape or Cancel closes it, and only that window waits while it shows.
pub const Dialog = struct {

    bytes: [256]u8 = undefined,
    edit: text.Text = undefined,

    /// Copies of what the dialog says, since callers often build it in buffers of their own that do not last.
    words: [3][160]u8 = undefined,

    heading: Node = root.label("", theme.title_text),
    detail: Node = root.label("", theme.caption),
    field: Node = undefined,
    cancel: Node = root.button("Cancel", &dismiss),
    confirm: Node = root.button("OK", &accept),
    actions: [2]*Node = undefined,
    row: Node = undefined,
    parts: [4]*Node = undefined,
    card: Node = undefined,

    host: ?*window.Window = null,
    done: ?*const fn ([]const u8) void = null,

    /// What had the keys before the dialog took them, given back when it closes.
    before: ?*Node = null,

    /// Links the dialog's nodes to each other; call once, where it will stay.
    pub fn init(self: *Dialog) void {

        self.edit = .{

            .buffer = &self.bytes,

        };

        self.field = root.input(&self.edit);
        self.field.action = &accept;
        self.actions = .{ &self.cancel, &self.confirm };

        self.row = root.box(.{

            .direction = .row,
            .gap = theme.gap,
            .justify = .end,

            .padding = .{

                .top = theme.gap / 2,

            },

        }, &self.actions);

        self.parts = .{ &self.heading, &self.detail, &self.field, &self.row };
        self.card = root.box(theme.card, &self.parts);
        self.card.data = @intFromPtr(self);

    }

    /// Asks for text under `title`, starting from `initial`, and passes it to `done` on confirming with `confirm`.
    pub fn ask(self: *Dialog, host: *window.Window, title: []const u8, initial: []const u8, confirm: []const u8, done: *const fn ([]const u8) void) void {

        self.edit.set(initial);
        self.edit.all();
        self.field.hidden = false;
        self.field.invalid = false;
        self.confirm.style = theme.primary;
        self.show(host, title, "", confirm, done);
        host.focus(&self.field);

    }

    /// Asks only for a yes to something that cannot be undone, explained by `detail`, passing `done` an empty string.
    pub fn check(self: *Dialog, host: *window.Window, title: []const u8, detail: []const u8, confirm: []const u8, done: *const fn ([]const u8) void) void {

        self.field.hidden = true;
        self.confirm.style = theme.destructive;
        self.show(host, title, detail, confirm, done);
        host.focus(&self.cancel);

    }

    /// Marks the field wrong, says why in `reason` when there is one, and keeps the dialog open, such as after a name was taken.
    pub fn refuse(self: *Dialog, reason: []const u8) void {

        const host = self.host orelse return;

        self.field.invalid = true;
        self.detail.content.label = self.keep(1, reason);
        self.detail.style.color = theme.danger;
        self.detail.hidden = reason.len == 0;
        host.modal = &self.card;
        host.dismiss = &escape;
        host.focus(&self.field);
        host.refresh();

    }

    pub fn close(self: *Dialog) void {

        self.done = null;
        self.hide();

    }

    /// Takes the card away, keeping `done` for a `refuse` that brings it back.
    fn hide(self: *Dialog) void {

        const host = self.host orelse return;
        if (host.modal != &self.card) return;

        host.modal = null;
        host.dismiss = null;
        host.focus(self.before);
        host.refresh();

    }

    pub fn open(self: *const Dialog) bool {

        const host = self.host orelse return false;

        return host.modal == &self.card;

    }

    fn show(self: *Dialog, host: *window.Window, title: []const u8, detail: []const u8, confirm: []const u8, done: *const fn ([]const u8) void) void {

        if (!self.open()) self.before = host.focused;

        self.host = host;
        self.done = done;
        self.heading.content.label = self.keep(0, title);
        self.detail.content.label = self.keep(1, detail);
        self.detail.style.color = theme.muted;
        self.detail.hidden = detail.len == 0;
        self.confirm.content.label = self.keep(2, confirm);
        host.modal = &self.card;
        host.dismiss = &escape;
        host.refresh();

    }

    /// Copies `string` into slot `index` of `words`, cut short if it must be.
    fn keep(self: *Dialog, index: usize, string: []const u8) []const u8 {

        const length = @min(string.len, self.words[index].len);

        @memcpy(self.words[index][0..length], string[0..length]);

        return self.words[index][0..length];

    }

    fn accept(item: *Node) void {

        const self: *Dialog = if (item.content == .input) @fieldParentPtr("field", item) else @fieldParentPtr("confirm", item);
        const done = self.done orelse return;

        // The action may bring the dialog back, such as to refuse a name, so it goes first.
        self.hide();
        done(self.edit.text());

    }

    fn dismiss(item: *Node) void {

        const self: *Dialog = @fieldParentPtr("cancel", item);

        self.close();

    }

    fn escape(host: *window.Window) void {

        const self: *Dialog = @ptrFromInt(host.modal.?.data);

        self.close();

    }

};
