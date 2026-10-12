//! Calculator: four functions with percent and sign, clicked or typed, and a history of results to pick up again.

const std = @import("std");

const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;
pub const panic = api.panic;

const control = api.Event.Modifiers{

    .control = true,

};

/// Digits an entry may hold, about as many as a double keeps exactly.
const longest = 15;

const Operator = enum {

    none,
    add,
    subtract,
    multiply,
    divide,

    fn symbol(self: Operator) []const u8 {

        return switch (self) {

            .none => "",
            .add => "+",
            .subtract => "\u{2212}",
            .multiply => "\u{00d7}",
            .divide => "\u{00f7}",

        };

    }

    /// `left` and `right` combined; null when dividing by zero.
    fn apply(self: Operator, left: f64, right: f64) ?f64 {

        return switch (self) {

            .none => right,
            .add => left + right,
            .subtract => left - right,
            .multiply => left * right,
            .divide => if (right == 0) null else left / right,

        };

    }

};

const Key = struct {

    label: []const u8,

    kind: enum {

        digit,
        point,
        operator,
        equals,
        percent,
        negate,
        clear,
        erase,

    },

    operator: Operator = .none,

};

/// The keypad, row by row.
const keys = [_]Key{

    .{ .label = "C", .kind = .clear },
    .{ .label = "\u{00b1}", .kind = .negate },
    .{ .label = "%", .kind = .percent },
    .{ .label = "\u{00f7}", .kind = .operator, .operator = .divide },
    .{ .label = "7", .kind = .digit },
    .{ .label = "8", .kind = .digit },
    .{ .label = "9", .kind = .digit },
    .{ .label = "\u{00d7}", .kind = .operator, .operator = .multiply },
    .{ .label = "4", .kind = .digit },
    .{ .label = "5", .kind = .digit },
    .{ .label = "6", .kind = .digit },
    .{ .label = "\u{2212}", .kind = .operator, .operator = .subtract },
    .{ .label = "1", .kind = .digit },
    .{ .label = "2", .kind = .digit },
    .{ .label = "3", .kind = .digit },
    .{ .label = "+", .kind = .operator, .operator = .add },
    .{ .label = gui.Icon.delete.text(), .kind = .erase },
    .{ .label = "0", .kind = .digit },
    .{ .label = ".", .kind = .point },
    .{ .label = "=", .kind = .equals },

};

const columns = 4;

var window: gui.Window = undefined;

/// What the display shows: typed digits while `entering`, else a result; `stored` and `pending` wait for the next operand.
var entry_bytes: [32]u8 = undefined;
var entry: []const u8 = "0";
var entering = false;
var stored: f64 = 0;
var pending = Operator.none;

/// A division by zero shows until the next key.
var failed = false;

var history_tool = gui.tool(.history, &toggle);
var expression_bytes: [96]u8 = undefined;

var expression = gui.label("", theme.caption.with(.{

    .grow = 1,
    .text_align = .right,

}));

var top_parts = [_]*gui.Node{ &history_tool, &expression };

var top = gui.box(.{

    .direction = .row,
    .items = .center,

}, &top_parts);

var value_bytes: [48]u8 = undefined;

var value = gui.label("0", .{

    .face = .mono,
    .size = 38,
    .text_align = .right,

});

var screen_parts = [_]*gui.Node{ &top, &value };

var screen = gui.box(theme.panel.with(.{

    .padding = gui.Edges{ .top = 6, .right = 14, .bottom = 10, .left = 6 },
    .gap = 2,

}), &screen_parts);

var buttons: [keys.len]gui.Node = undefined;
var rows: [keys.len / columns]gui.Node = undefined;
var row_parts: [keys.len / columns][columns]*gui.Node = undefined;
var row_list: [keys.len / columns]*gui.Node = undefined;

var pad = gui.box(.{

    .grow = 1,
    .gap = 6,

}, &row_list);

// History: the last results, newest first.
const kept = 24;

var history: [kept][96]u8 = undefined;
var results: [kept]f64 = undefined;
var lines: [kept]gui.Node = undefined;
var line_list: [kept]*gui.Node = undefined;
var count: usize = 0;

var log = gui.box(.{

    .grow = 1,
    .gap = 2,
    .scroll = true,

}, &line_list);

var empty = gui.label("Results show here.", theme.caption.with(.{

    .grow = 1,
    .text_align = .center,

}));

var forget = gui.button("Clear history", &clear_history);
var past_parts = [_]*gui.Node{ &log, &empty, &forget };

var past = gui.box(.{

    .grow = 1,
    .gap = theme.gap,

}, &past_parts);

var parts = [_]*gui.Node{ &screen, &pad, &past };

var root = gui.box(.{

    .padding = .all(theme.spacing),
    .gap = theme.spacing,

}, &parts);

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .application);

    // No natural width, so every key in a row takes an equal share.
    const key = theme.button.with(.{

        .width = 0,
        .height = null,

        .grow = 1,
        .size = 20,

    });

    for (&buttons, keys, 0..) |*button, entry_key, index| {

        button.* = gui.button(entry_key.label, &press);
        button.data = index;

        button.style = switch (entry_key.kind) {

            .equals => theme.primary.with(.{

                .width = 0,
                .height = null,

                .grow = 1,
                .size = 22,

            }),
            .operator => key.with(.{

                .background = theme.selected,
                .size = 22,

            }),
            .erase => key.with(.{

                .face = .icons,
                .size = 18,

            }),
            else => key,

        };

        row_parts[index / columns][index % columns] = button;

    }

    for (&rows, 0..) |*row, index| {

        row.* = gui.box(.{

            .grow = 1,
            .direction = .row,
            .gap = 6,

        }, &row_parts[index]);

        row_list[index] = row;

    }

    for (&lines, 0..) |*line, index| {

        line.* = gui.label("", theme.item.with(.{

            .height = 40,

            .face = .mono,
            .size = theme.small,

            .text_align = .right,

        }));

        line.action = &recall;
        line.data = index;
        line_list[index] = line;

    }

    past.hidden = true;

    window = gui.Window.open(&root, .{

        .title = "Calculator",
        .application = .calculator,

        .width = 320,
        .height = 470,

    }) catch api.exit(3);

    while (true) {

        const event = window.next(1000) orelse continue;

        if (event.kind == .close) window.quit();
        if (event.kind == .key and event.pressed) typed(event);

    }

}

/// Runs the key a button stands for.
fn press(node: *gui.Node) void {

    run(keys[node.data]);

}

/// Maps a typed key to the keypad, plus copying and pasting the display.
fn typed(event: api.Event) void {

    if (event.chord(control, 'c')) return gui.display.copy(entry) catch {};

    if (event.chord(control, 'v')) {

        var bytes: [64]u8 = undefined;
        const pasted = std.mem.trim(u8, gui.display.paste(&bytes) catch return, " \t\r\n");
        const number = std.fmt.parseFloat(f64, pasted) catch return;

        show(number);
        return sync();

    }

    const digit = [1]u8{@truncate(event.char)};

    const found: ?Key = switch (event.key()) {

        .enter => keys[keys.len - 1],
        .backspace => keys[16],
        .escape, .delete => keys[0],
        .character => switch (event.char) {

            '0'...'9' => Key{ .label = &digit, .kind = .digit },
            '.', ',' => keys[18],
            '+' => keys[15],
            '-' => keys[11],
            '*', 'x', 'X' => keys[7],
            '/' => keys[3],
            '%' => keys[2],
            '=' => keys[keys.len - 1],
            else => null,

        },
        else => null,

    };

    if (found) |key| run(key);

}

fn run(key: Key) void {

    const label = key.label;

    // An error clears with whatever comes next.
    if (failed) {

        failed = false;
        stored = 0;
        pending = .none;
        entry = "0";
        entering = false;

    }

    switch (key.kind) {

        .digit => {

            if (!entering or std.mem.eql(u8, entry, "0")) {

                entry = copy(label);
                entering = true;

            } else if (digits(entry) < longest) {

                entry = append(label);

            }

        },
        .point => {

            if (!entering) {

                entry = copy("0.");
                entering = true;

            } else if (std.mem.indexOfScalar(u8, entry, '.') == null) {

                entry = append(".");

            }

        },
        .erase => {

            if (!entering) return;

            entry = if (entry.len <= 1 or (entry.len == 2 and entry[0] == '-')) "0" else entry[0 .. entry.len - 1];
            entry = copy(entry);

        },
        .negate => {

            if (std.mem.eql(u8, entry, "0")) return;

            entry = if (entry[0] == '-') copy(entry[1..]) else prefix(entry);

        },
        .percent => {

            // Against a sum or difference, a percentage of what it adds to, as on paper.
            const number = current();

            show(if (pending == .add or pending == .subtract) stored * number / 100 else number / 100);

        },
        .operator => {

            if (pending != .none and entering) {

                if (!settle(false)) return sync();

            } else if (pending == .none) {

                stored = current();

            }

            pending = key.operator;
            entering = false;
            expression.content.label = std.fmt.bufPrint(&expression_bytes, "{s} {s}", .{ pretty(stored, &value_bytes), pending.symbol() }) catch "";

        },
        .equals => {

            if (pending != .none) _ = settle(true);

        },
        .clear => {

            // The first press clears what is being typed, the next everything.
            if (entering and !std.mem.eql(u8, entry, "0")) {

                entry = "0";

            } else {

                stored = 0;
                pending = .none;
                expression.content.label = "";
                entry = "0";

            }

            entering = false;

        },

    }

    sync();

}

/// Works out the pending operation on the entry; when `finished`, records it in the history. False on a division by zero.
fn settle(finished: bool) bool {

    const right = current();

    const result = pending.apply(stored, right) orelse {

        failed = true;
        expression.content.label = "";
        entry = "Cannot divide by zero";

        return false;

    };

    if (finished) {

        var left_bytes: [48]u8 = undefined;
        var right_bytes: [48]u8 = undefined;
        var result_bytes: [48]u8 = undefined;
        const line = std.fmt.bufPrint(&expression_bytes, "{s} {s} {s} =", .{ pretty(stored, &left_bytes), pending.symbol(), pretty(right, &right_bytes) }) catch "";

        expression.content.label = line;
        remember(line, pretty(result, &result_bytes), result);
        pending = .none;

    }

    stored = result;
    show(result);

    return true;

}

/// Shows `number` as a result, which the next digit replaces.
fn show(number: f64) void {

    entry = copy(format(number, &value_bytes));
    entering = false;

}

fn current() f64 {

    return std.fmt.parseFloat(f64, entry) catch 0;

}

/// Puts the entry, digit-grouped, on the display.
fn sync() void {

    value.content.label = if (failed) entry else group(entry, &value_bytes);
    value.style.size = if (value.content.label.len > 16) 24 else 38;
    window.refresh();

}

fn digits(text: []const u8) usize {

    var total: usize = 0;

    for (text) |char| {

        if (std.ascii.isDigit(char)) total += 1;

    }

    return total;

}

fn copy(text: []const u8) []const u8 {

    std.mem.copyForwards(u8, entry_bytes[0..text.len], text);

    return entry_bytes[0..text.len];

}

fn append(text: []const u8) []const u8 {

    const length = entry.len;

    @memcpy(entry_bytes[length..][0..text.len], text);

    return entry_bytes[0 .. length + text.len];

}

fn prefix(text: []const u8) []const u8 {

    std.mem.copyBackwards(u8, entry_bytes[1 .. text.len + 1], text);
    entry_bytes[0] = '-';

    return entry_bytes[0 .. text.len + 1];

}

/// `number` as people read it, digit-grouped, in `out`.
fn pretty(number: f64, out: *[48]u8) []const u8 {

    var plain: [48]u8 = undefined;

    return group(format(number, &plain), out);

}

/// `number` as plain text in `out`: up to ten decimals without trailing zeros, or in exponent form when very large or small.
fn format(number: f64, out: []u8) []const u8 {

    if (!std.math.isFinite(number)) return "Error";

    const magnitude = @abs(number);

    if (magnitude != 0 and (magnitude >= 1e15 or magnitude < 1e-9)) {

        const text = std.fmt.bufPrint(out, "{e:.9}", .{number}) catch return "Error";
        const split = std.mem.indexOfScalar(u8, text, 'e') orelse return text;
        const mantissa = trim(text[0..split]);
        const exponent = text[split..];

        std.mem.copyForwards(u8, out[mantissa.len..][0..exponent.len], exponent);

        return out[0 .. mantissa.len + exponent.len];

    }

    const text = trim(std.fmt.bufPrint(out, "{d:.10}", .{number}) catch return "Error");

    return if (std.mem.eql(u8, text, "-0")) "0" else text;

}

/// `text` without trailing zeros after a decimal point, nor the point itself when nothing follows it.
fn trim(text: []const u8) []const u8 {

    if (std.mem.indexOfScalar(u8, text, '.') == null) return text;

    return std.mem.trimRight(u8, std.mem.trimRight(u8, text, "0"), ".");

}

/// `text` with commas between thousands of its whole part, into `out`.
fn group(text: []const u8, out: []u8) []const u8 {

    if (std.mem.indexOfScalar(u8, text, 'e') != null or text.len > 24) {

        @memcpy(out[0..text.len], text);

        return out[0..text.len];

    }

    const negative = text.len != 0 and text[0] == '-';
    const body = text[@intFromBool(negative)..];
    const whole = std.mem.indexOfScalar(u8, body, '.') orelse body.len;
    var length: usize = 0;

    if (negative) {

        out[0] = '-';
        length = 1;

    }

    for (body[0..whole], 0..) |char, index| {

        if (index != 0 and (whole - index) % 3 == 0) {

            out[length] = ',';
            length += 1;

        }

        out[length] = char;
        length += 1;

    }

    @memcpy(out[length..][0 .. body.len - whole], body[whole..]);

    return out[0 .. length + body.len - whole];

}

fn remember(line: []const u8, result: []const u8, number: f64) void {

    var index = @min(count, kept - 1);

    while (index > 0) : (index -= 1) {

        history[index] = history[index - 1];
        results[index] = results[index - 1];
        lines[index].content.label = history[index][0..lines[index - 1].content.label.len];

    }

    const text = std.fmt.bufPrint(&history[0], "{s} {s}", .{ line, result }) catch "";

    lines[0].content.label = text;
    results[0] = number;
    count = @min(count + 1, kept);
    fill();

}

fn fill() void {

    for (&lines, 0..) |*line, index| line.hidden = index >= count;

    empty.hidden = count != 0;
    forget.hidden = count == 0;

}

fn toggle(_: *gui.Node) void {

    past.hidden = !past.hidden;
    pad.hidden = !past.hidden;
    history_tool.selected = !past.hidden;
    fill();
    window.refresh();

}

/// Picks a past result up as the entry.
fn recall(node: *gui.Node) void {

    show(results[node.data]);
    toggle(&history_tool);
    sync();

}

fn clear_history(_: *gui.Node) void {

    count = 0;
    fill();
    window.refresh();

}
