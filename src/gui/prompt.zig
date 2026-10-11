const node = @import("node.zig");
const root = @import("root.zig");
const text = @import("text.zig");
const theme = @import("theme.zig");
const window = @import("window.zig");

const Node = node.Node;

/// A bar asking for one line of text, or just a yes, before running an action; apps put `bar` in their tree.
pub const Prompt = struct {

    bytes: [256]u8 = undefined,
    edit: text.Text = undefined,

    message: Node = root.label("", .{}),
    field: Node = undefined,
    confirm: Node = root.button("OK", &accept),
    cancel: Node = root.button("Cancel", &dismiss),
    parts: [4]*Node = undefined,
    bar: Node = undefined,

    host: ?*window.Window = null,
    done: ?*const fn ([]const u8) void = null,

    /// Links the prompt's nodes to each other; call once, where it will stay.
    pub fn init(self: *Prompt) void {

        self.edit = .{

            .buffer = &self.bytes,

        };
        self.field = root.input(&self.edit);
        self.field.style = self.field.style.with(.{

            .grow = 1,

        });
        self.field.action = &accept;
        self.confirm.style = theme.primary;
        self.parts = .{ &self.message, &self.field, &self.confirm, &self.cancel };
        self.bar = root.box(theme.bar.with(.{

            .gap = theme.gap,
            .background = theme.field,

        }), &self.parts);
        self.bar.hidden = true;

    }

    /// Asks for text, starting from `initial`, and passes it to `done` on confirming.
    pub fn ask(self: *Prompt, host: *window.Window, message: []const u8, initial: []const u8, confirm: []const u8, done: *const fn ([]const u8) void) void {

        self.edit.set(initial);
        self.edit.all();
        self.field.hidden = false;
        self.field.invalid = false;
        self.show(host, message, confirm, done);
        host.focus(&self.field);

    }

    /// Asks only for a yes, passing `done` an empty string.
    pub fn check(self: *Prompt, host: *window.Window, message: []const u8, confirm: []const u8, done: *const fn ([]const u8) void) void {

        self.field.hidden = true;
        self.show(host, message, confirm, done);
        host.focus(&self.confirm);

    }

    /// Marks the field wrong and keeps the prompt open, such as after a name was taken.
    pub fn refuse(self: *Prompt) void {

        self.field.invalid = true;
        self.bar.hidden = false;
        if (self.host) |host| host.refresh();

    }

    pub fn close(self: *Prompt) void {

        self.bar.hidden = true;
        self.done = null;
        if (self.host) |host| host.refresh();

    }

    pub fn open(self: *const Prompt) bool {

        return !self.bar.hidden;

    }

    fn show(self: *Prompt, host: *window.Window, message: []const u8, confirm: []const u8, done: *const fn ([]const u8) void) void {

        self.host = host;
        self.done = done;
        self.message.content.label = message;
        self.confirm.content.label = confirm;
        self.bar.hidden = false;
        host.refresh();

    }

    fn accept(item: *Node) void {

        const self: *Prompt = if (item.content == .input) @fieldParentPtr("field", item) else @fieldParentPtr("confirm", item);
        const done = self.done orelse return;

        // The action may reopen the prompt, such as to refuse a name, so it closes first.
        self.bar.hidden = true;
        done(self.edit.text());
        if (self.host) |host| host.refresh();

    }

    fn dismiss(item: *Node) void {

        const self: *Prompt = @fieldParentPtr("cancel", item);

        self.close();

    }

};
