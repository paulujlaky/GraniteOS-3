//! Requests: sends HTTP requests with a method, headers, and a body, and shows the reply's status, headers, and body, with
//! JSON laid out; the requests sent are kept in `/cfgs/USER/requests.history` to send again.

const std = @import("std");

const catalog = @import("catalog.zig");

const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;
const Method = api.http.Method;
pub const panic = api.panic;

const methods = [_]Method{ .GET, .POST, .PUT, .PATCH, .DELETE };

/// Most requests the history keeps, and most headers one sends.
const most = 30;
const headers_most = 32;

/// Most of a reply's body shown, and room for laying it out as JSON.
const kept_most = 64 * 1024;
const shown_most = kept_most + 32 * 1024;

/// Between a history entry's fields, and after each entry.
const field = 0x1f;
const record = 0x1e;

/// A request as the history keeps it, its text inside `history`.
const Entry = struct {

    method: Method = .GET,
    url: []const u8 = "",
    headers: []const u8 = "",
    body: []const u8 = "",

    fn same(self: Entry, other: Entry) bool {

        return self.method == other.method and std.mem.eql(u8, self.url, other.url) and std.mem.eql(u8, self.headers, other.headers) and std.mem.eql(u8, self.body, other.body);

    }

};

/// The first `kept_most` bytes written to it, and how many came in all.
const Keep = struct {

    kept: []u8,
    length: usize = 0,
    total: usize = 0,
    writer: std.Io.Writer,

    fn init(kept: []u8, buffer: []u8) Keep {

        return .{

            .kept = kept,
            .writer = .{

                .vtable = &.{

                    .drain = drain,

                },
                .buffer = buffer,

            },

        };

    }

    fn take(self: *Keep, bytes: []const u8) void {

        const room = @min(bytes.len, self.kept.len - self.length);

        @memcpy(self.kept[self.length..][0..room], bytes[0..room]);
        self.length += room;
        self.total += bytes.len;

    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {

        const self: *Keep = @alignCast(@fieldParentPtr("writer", writer));
        const last = data[data.len - 1];
        var total: usize = 0;

        self.take(writer.buffered());
        writer.end = 0;

        for (data[0 .. data.len - 1]) |bytes| {

            self.take(bytes);
            total += bytes.len;

        }

        for (0..splat) |_| self.take(last);

        return total + last.len * splat;

    }

};

var window: gui.Window = undefined;
var files = api.Files{};
var user: []const u8 = "";
var home: []const u8 = "/";
var home_bytes: [64]u8 = undefined;
var path_bytes: [128]u8 = undefined;

var history: std.ArrayList(u8) = .empty;
var entries: [most]Entry = undefined;
var entry_count: usize = 0;

/// The history entry a menu was opened on.
var offered: usize = 0;

var method = Method.GET;

// Sending runs the event loop while it waits, so Send only asks, and the main loop sends.
var wanted = false;
var busy = false;
var cancelled = false;

// Where a reply comes in, apart from the fields showing it, which clear themselves before taking new text.
var kept_bytes: [kept_most]u8 = undefined;
var laid_bytes: [shown_most]u8 = undefined;
var head_scratch: [16 * 1024]u8 = undefined;
var head_bytes: [16 * 1024]u8 = undefined;

const method_choices = blk: {

    var choices: [methods.len]gui.Choice = undefined;

    for (methods, 0..) |each, index| choices[index] = .{

        .title = @tagName(each),
        .run = using(each),

    };

    break :blk choices;

};

var method_menu: gui.Menu(&method_choices) = .{};

var entry_menu: gui.Menu(&.{

    .{ .icon = .trash, .title = "Remove", .run = remove },
    .{ .icon = .delete, .title = "Clear history", .run = forget },

}) = .{};

// History.
var history_note = gui.label("History", theme.caption.with(.{

    .padding = gui.Edges.axes(4, 6),

}));

var empty_note = gui.label("Requests you send show here.", theme.caption.with(.{

    .padding = gui.Edges.axes(0, 6),

}));

var verbs: [most]gui.Node = undefined;
var addresses: [most]gui.Node = undefined;
var address_bytes: [most][96]u8 = undefined;
var row_parts: [most][2]*gui.Node = undefined;
var rows: [most]gui.Node = undefined;
var side_list: [2 + most]*gui.Node = undefined;

var sidebar = gui.box(.{

    .width = 260,
    .padding = .all(theme.gap),
    .gap = 2,
    .scroll = true,

    .background = theme.pane,

}, &side_list);

// The request.
var verb = gui.label("GET", .{

    .grow = 1,

    .face = .mono,
    .size = theme.small,

});

var verb_icon = gui.icon(.down, theme.icon);
var verb_parts = [_]*gui.Node{ &verb, &verb_icon };

var verb_button = gui.box(theme.button.with(.{

    .width = 104,
    .padding = gui.Edges.axes(0, 10),
    .direction = .row,
    .items = .center,

}), &verb_parts);

var url_bytes: [1024]u8 = undefined;

var url_text = gui.Text{

    .buffer = &url_bytes,
    .placeholder = "https://jsonplaceholder.typicode.com/posts/1",

};

var url = gui.input(&url_text);
var send_button = gui.button("Send", &ask);
var line_parts = [_]*gui.Node{ &verb_button, &url, &send_button };

var line = gui.box(.{

    .direction = .row,
    .gap = theme.gap,

}, &line_parts);

var headers_tab = gui.button("Headers", &showHeaders);
var body_tab = gui.button("Body", &showBody);
var asking_spring = gui.box(theme.spring, &.{});
var hint = gui.label("One per line, as Name: value", theme.caption);
var asking_parts = [_]*gui.Node{ &headers_tab, &body_tab, &asking_spring, &hint };

var asking_tabs = gui.box(.{

    .direction = .row,
    .gap = 4,
    .items = .center,

}, &asking_parts);

var headers_bytes: [2048]u8 = undefined;

var headers_text = gui.Text{

    .buffer = &headers_bytes,
    .placeholder = "Accept: application/json",

};

var body_bytes: [16 * 1024]u8 = undefined;

var body_text = gui.Text{

    .buffer = &body_bytes,
    .placeholder = "{ \"title\": \"hello\" }",

};

const field_style = theme.area.with(.{

    .height = 160,

    .face = .mono,
    .size = theme.small,

});

var headers_field = gui.area(&headers_text);
var body_field = gui.area(&body_text);
var rule = gui.box(theme.rule, &.{});

// The reply.
var reply_tab = gui.button("Body", &showReply);
var head_tab = gui.button("Headers", &showHead);
var reply_spring = gui.box(theme.spring, &.{});
var status_bytes: [128]u8 = undefined;
var status = gui.label("", theme.caption);
var reply_parts = [_]*gui.Node{ &reply_tab, &head_tab, &reply_spring, &status };

var reply_tabs = gui.box(.{

    .direction = .row,
    .gap = 4,
    .items = .center,

}, &reply_parts);

var shown_bytes: [shown_most]u8 = undefined;

var shown_text = gui.Text{

    .buffer = &shown_bytes,
    .placeholder = "The reply shows here.",
    .fixed = true,

};

var head_text = gui.Text{

    .buffer = &head_bytes,
    .placeholder = "The reply's headers show here.",
    .fixed = true,

};

const reply_style = theme.area.with(.{

    .grow = 1,
    .height = null,

    .face = .mono,
    .size = theme.small,

});

var reply_field = gui.area(&shown_text);
var head_field = gui.area(&head_text);
var main_parts = [_]*gui.Node{ &line, &asking_tabs, &headers_field, &body_field, &rule, &reply_tabs, &reply_field, &head_field };

var main = gui.box(.{

    .grow = 1,
    .padding = .all(theme.spacing + 4),
    .gap = theme.spacing,

}, &main_parts);

var root_parts = [_]*gui.Node{ &sidebar, &main };

var root = gui.box(.{

    .direction = .row,

}, &root_parts);

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .application);

    var argument_bytes: [256]u8 = undefined;

    home = std.fmt.bufPrint(&home_bytes, "{s}", .{catalog.home(api.argument(&argument_bytes)) orelse "/"}) catch "/";
    user = std.fs.path.basenamePosix(home);
    build();
    load();

    window = gui.Window.open(&root, .{

        .title = "Requests",
        .application = .requests,

        .width = 1000,
        .height = 700,

    }) catch api.exit(3);

    method_menu.init(&window);
    entry_menu.init(&window);
    api.net.idle = &idle;
    tab(true);
    view(true);
    window.focus(&url);
    show();

    while (true) {

        if (wanted) send();

        const event = window.next(100) orelse continue;

        if (event.kind == .close) window.quit();

    }

}

/// Keeps the window painting and answering while a request waits on the network, and ends it once cancelled.
fn idle() api.net.NetError!void {

    if (window.next(1)) |event| {

        if (event.kind == .close) window.quit();
        if (event.pressing(.escape)) cancelled = true;

    }

    if (cancelled) return error.Cancelled;

}

fn build() void {

    verb_button.action = &pick;
    url.action = &ask;
    url.style.grow = 1;
    headers_field.style = field_style;
    body_field.style = field_style;
    reply_field.style = reply_style;
    head_field.style = reply_style;
    send_button.style = theme.primary.with(.{

        .width = 96,

    });

    side_list[0] = &history_note;
    side_list[1] = &empty_note;

    for (&rows, 0..) |*row, index| {

        verbs[index] = gui.label("", .{

            .width = 56,

            .face = .mono,
            .size = theme.small,
            .color = theme.muted,

        });

        addresses[index] = gui.label("", .{

            .grow = 1,

            .size = theme.small,

        });

        row_parts[index] = .{ &verbs[index], &addresses[index] };

        row.* = gui.box(theme.item.with(.{

            .gap = 6,

        }), &row_parts[index]);

        row.action = &recall;
        row.menu = &offer;
        row.data = index;
        side_list[2 + index] = row;

    }

}

/// Sends the request in the fields, then shows its reply and keeps it in the history.
fn send() void {

    wanted = false;

    var schemed: [1040]u8 = undefined;
    const typed = std.mem.trim(u8, url_text.text(), " \t");

    if (typed.len == 0) return report("Enter an address to send to.");

    // An address without a scheme is taken as HTTPS.
    const address = if (api.http.Url.parse(typed) != null) typed else std.fmt.bufPrint(&schemed, "https://{s}", .{typed}) catch typed;
    if (api.http.Url.parse(address) == null) return report("That address isn't one Requests can send to.");

    var headers: [headers_most + 1]api.http.Header = undefined;
    var count: usize = 0;
    var lines = std.mem.tokenizeAny(u8, headers_text.text(), "\r\n");

    while (lines.next()) |text| {

        const trimmed = std.mem.trim(u8, text, " \t");
        if (trimmed.len == 0) continue;

        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return report("Each header needs a name, a colon, and a value.");
        const name = std.mem.trim(u8, trimmed[0..colon], " \t");

        if (name.len == 0) return report("Each header needs a name, a colon, and a value.");
        if (count == headers_most) return report("That's more headers than Requests sends.");

        headers[count] = .{

            .name = name,
            .value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t"),

        };

        count += 1;

    }

    const body = body_text.text();
    const shape = std.mem.trimLeft(u8, body, " \t\r\n");

    // Most APIs read a body as JSON only when told, so one that looks like JSON says so unless the headers already do.
    if (body.len != 0 and !named(headers[0..count], "content-type")) {

        headers[count] = .{

            .name = "Content-Type",
            .value = if (shape.len != 0 and (shape[0] == '{' or shape[0] == '[')) "application/json" else "text/plain",

        };

        count += 1;

    }

    busy = true;
    cancelled = false;
    report("Sending\u{2026}");

    var buffer: [4096]u8 = undefined;
    var keep = Keep.init(&kept_bytes, &buffer);
    var head = std.Io.Writer.fixed(&head_scratch);
    const started = api.ticks();

    const result = api.http.send(api.pages, address, .{

        .method = method,
        .headers = headers[0..count],
        .body = body,

    }, &keep.writer, &head);

    keep.writer.flush() catch {

    };

    busy = false;
    remember(.{

        .method = method,
        .url = typed,
        .headers = headers_text.text(),
        .body = body,

    });

    const code = result catch |err| {

        shown_text.clear();
        head_text.clear();

        return report(std.fmt.bufPrint(&status_bytes, "Failed: {s}", .{api.http.reason(err)}) catch "");

    };

    head_text.set(plain(head.buffered()));
    head_text.caret = 0;
    present(keep);

    var amount_bytes: [256]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&amount_bytes);
    const phrase = @as(std.http.Status, @enumFromInt(code)).phrase() orelse "";
    const size = catalog.amount(allocator.allocator(), keep.total) catch "";

    report(std.fmt.bufPrint(&status_bytes, "{d} {s}  \u{00b7}  {d} ms  \u{00b7}  {s}", .{ code, phrase, (api.ticks() - started) * 10, size }) catch "");

}

/// Shows the reply's body, laid out when it is JSON, else as it came.
fn present(keep: Keep) void {

    const bytes = keep.kept[0..keep.length];
    var arena = std.heap.ArenaAllocator.init(api.pages);

    defer arena.deinit();

    const whole = keep.length == keep.total;
    const json = whole and std.json.validate(arena.allocator(), bytes) catch false;
    const laid = if (json) layout(bytes, &laid_bytes) else null;

    shown_text.set(laid orelse plain(bytes));
    shown_text.caret = 0;

}

/// `bytes` without carriage returns, which the fields would show as boxes, moved up in place.
fn plain(bytes: []u8) []u8 {

    var length: usize = 0;

    for (bytes) |byte| {

        if (byte == '\r') continue;

        bytes[length] = byte;
        length += 1;

    }

    return bytes[0..length];

}

/// Lays out JSON `bytes` with two-space indents into `out`, keeping every value as written; null when it does not fit.
fn layout(bytes: []const u8, out: []u8) ?[]const u8 {

    var writer = std.Io.Writer.fixed(out);
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    var index: usize = 0;

    while (index < bytes.len) : (index += 1) {

        const byte = bytes[index];

        if (quoted) {

            writer.writeByte(byte) catch return null;

            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == '"') quoted = false;
            continue;

        }

        switch (byte) {

            ' ', '\t', '\r', '\n' => {

            },
            '{', '[' => {

                const closing: u8 = if (byte == '{') '}' else ']';
                var next = index + 1;

                while (next < bytes.len and std.ascii.isWhitespace(bytes[next])) next += 1;

                // An empty object or array stays on one line.
                if (next < bytes.len and bytes[next] == closing) {

                    writer.writeAll(&[_]u8{ byte, closing }) catch return null;
                    index = next;
                    continue;

                }

                depth += 1;
                writer.writeByte(byte) catch return null;
                indent(&writer, depth) catch return null;

            },
            '}', ']' => {

                depth -|= 1;
                indent(&writer, depth) catch return null;
                writer.writeByte(byte) catch return null;

            },
            ',' => {

                writer.writeByte(byte) catch return null;
                indent(&writer, depth) catch return null;

            },
            ':' => writer.writeAll(": ") catch return null,
            '"' => {

                quoted = true;
                writer.writeByte(byte) catch return null;

            },
            else => writer.writeByte(byte) catch return null,

        }

    }

    return writer.buffered();

}

fn indent(writer: *std.Io.Writer, depth: usize) std.Io.Writer.Error!void {

    try writer.writeByte('\n');
    try writer.splatByteAll(' ', depth * 2);

}

fn named(headers: []const api.http.Header, name: []const u8) bool {

    for (headers) |header| {

        if (std.ascii.eqlIgnoreCase(header.name, name)) return true;

    }

    return false;

}

/// Shows `text` beside the reply's tabs.
fn report(text: []const u8) void {

    status.content.label = text;
    show();

}

/// Shows the method, Send or Cancel, and the history.
fn show() void {

    verb.content.label = @tagName(method);
    send_button.content = .{

        .label = if (busy) "Cancel" else "Send",

    };

    empty_note.hidden = entry_count != 0;

    for (&rows, 0..) |*row, index| {

        row.hidden = index >= entry_count;
        if (index >= entry_count) continue;

        const entry = entries[index];

        verbs[index].content.label = @tagName(entry.method);
        addresses[index].content.label = gui.draw.shorten(bare(entry.url), .sans, theme.small, if (addresses[index].rect.width > 0) addresses[index].rect.width else 160, &address_bytes[index]);

    }

    window.refresh();

}

/// An address without its scheme, as the history lists it.
fn bare(address: []const u8) []const u8 {

    for ([_][]const u8{ "https://", "http://" }) |scheme| {

        if (std.ascii.startsWithIgnoreCase(address, scheme)) return address[scheme.len..];

    }

    return address;

}

fn ask(_: *gui.Node) void {

    if (busy) {

        cancelled = true;
        return;

    }

    wanted = true;

}

fn pick(node: *gui.Node) void {

    method_menu.show(.{

        .x = node.rect.x,
        .y = node.rect.bottom() + 4,

    });

}

fn using(comptime chosen: Method) *const fn () void {

    return &struct {

        fn run() void {

            method = chosen;
            show();

        }

    }.run;

}

fn showHeaders(_: *gui.Node) void {

    tab(true);

}

fn showBody(_: *gui.Node) void {

    tab(false);

}

/// Shows the request's headers, or its body.
fn tab(headers: bool) void {

    headers_tab.selected = headers;
    body_tab.selected = !headers;
    headers_field.hidden = !headers;
    body_field.hidden = headers;
    hint.hidden = !headers;
    window.focus(if (headers) &headers_field else &body_field);
    window.refresh();

}

fn showReply(_: *gui.Node) void {

    view(true);

}

fn showHead(_: *gui.Node) void {

    view(false);

}

/// Shows the reply's body, or its headers.
fn view(body: bool) void {

    reply_tab.selected = body;
    head_tab.selected = !body;
    reply_field.hidden = !body;
    head_field.hidden = body;
    window.refresh();

}

/// Puts history entry `node.data` back in the fields, to send again.
fn recall(node: *gui.Node) void {

    const entry = entries[node.data];

    method = entry.method;
    url_text.set(entry.url);
    headers_text.set(entry.headers);
    body_text.set(entry.body);
    tab(entry.body.len == 0);
    show();

}

fn offer(node: *gui.Node, at: gui.Point) void {

    offered = node.data;
    entry_menu.show(at);

}

fn remove() void {

    if (offered >= entry_count) return;

    rewrite(null, offered);

}

fn forget() void {

    entry_count = 0;
    rewrite(null, null);

}

/// Puts `entry` first in the history, once.
fn remember(entry: Entry) void {

    rewrite(entry, null);

}

/// Writes the history afresh: `first` ahead of the entries kept, leaving out `dropped` and any the same as `first`.
fn rewrite(first: ?Entry, dropped: ?usize) void {

    var next: std.ArrayList(u8) = .empty;
    var written: usize = 0;

    if (first) |entry| {

        append(&next, entry) catch return;
        written += 1;

    }

    for (entries[0..entry_count], 0..) |entry, index| {

        if (written == most) break;
        if (dropped == index or (first != null and entry.same(first.?))) continue;

        append(&next, entry) catch return;
        written += 1;

    }

    history.deinit(api.pages);
    history = next;
    split();
    store();
    show();

}

fn append(list: *std.ArrayList(u8), entry: Entry) !void {

    for ([_][]const u8{ @tagName(entry.method), entry.url, entry.headers, entry.body }, 0..) |part, index| {

        if (index != 0) try list.append(api.pages, field);

        // The separators never appear inside a field.
        for (part) |byte| {

            if (byte != field and byte != record) try list.append(api.pages, byte);

        }

    }

    try list.append(api.pages, record);

}

/// Finds each entry in `history`.
fn split() void {

    var records = std.mem.tokenizeScalar(u8, history.items, record);

    entry_count = 0;

    while (records.next()) |text| {

        if (entry_count == most) break;

        var fields = std.mem.splitScalar(u8, text, field);

        entries[entry_count] = .{

            .method = std.meta.stringToEnum(Method, fields.next() orelse continue) orelse continue,
            .url = fields.next() orelse continue,
            .headers = fields.next() orelse "",
            .body = fields.rest(),

        };

        entry_count += 1;

    }

}

fn path() []const u8 {

    return std.fmt.bufPrint(&path_bytes, "{s}/{s}/requests.history", .{ api.config.root, user }) catch "";

}

fn load() void {

    const bytes = files.load(api.pages, path()) catch return;

    history = .fromOwnedSlice(bytes);
    split();

}

fn store() void {

    files.save(api.pages, path(), history.items) catch {

    };

}
