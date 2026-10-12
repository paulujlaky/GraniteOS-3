//! Monitor: processor and memory use over time, and every running process.

const std = @import("std");

const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;
const Usage = api.abi.Usage;
pub const panic = api.panic;

/// Seconds of history the graphs keep.
const span = 60;
const shown = 64;

var window: gui.Window = undefined;
var accounts = api.Accounts{};

var records: [256]Usage = undefined;
var before: [256]Usage = undefined;
var before_count: usize = 0;
var previous = api.abi.Summary{};

/// Recent processor and memory use, from 0 to 1, oldest first.
var processor_history = [_]f32{0} ** span;
var memory_history = [_]f32{0} ** span;

const Card = struct {

    title: gui.Node,
    value: gui.Node,
    detail: gui.Node,
    plot: gui.Graph,
    graph: gui.Node,
    parts: [4]*gui.Node,
    node: gui.Node,
    bytes: [32]u8 = undefined,
    detail_bytes: [64]u8 = undefined,

    fn init(self: *Card, heading_text: []const u8, history: *const [span]f32) void {

        self.title = gui.label(heading_text, theme.caption);

        self.value = gui.label("", .{

            .size = 26,

        });

        self.detail = gui.label("", theme.caption);

        self.plot = .{

            .values = history,

        };

        self.graph = gui.chart(&self.plot, .{

            .height = 112,

        });

        self.parts = .{ &self.title, &self.value, &self.detail, &self.graph };

        self.node = gui.box(theme.panel.with(.{

            .grow = 1,
            .gap = 4,

        }), &self.parts);

    }

};

var processor: Card = undefined;
var memory: Card = undefined;

var cards = gui.box(.{

    .direction = .row,
    .gap = theme.spacing,
    .padding = .all(theme.spacing),

}, &.{});

var card_parts: [2]*gui.Node = undefined;

const columns = [_]struct { title: []const u8, width: ?i32 }{

    .{ .title = "Process", .width = null },
    .{ .title = "ID", .width = 50 },
    .{ .title = "User", .width = 90 },
    .{ .title = "State", .width = 80 },
    .{ .title = "Memory", .width = 80 },
    .{ .title = "CPU", .width = 60 },

};

var heading_cells: [columns.len]gui.Node = undefined;
var heading_parts: [columns.len]*gui.Node = undefined;

var heading = gui.box(.{

    .height = 26,
    .padding = .axes(0, 18),

    .direction = .row,
    .items = .center,

}, &heading_parts);

var cells: [shown][columns.len]gui.Node = undefined;
var cell_bytes: [shown][columns.len][32]u8 = undefined;
var cell_parts: [shown][columns.len]*gui.Node = undefined;
var rows: [shown]gui.Node = undefined;
var row_list: [shown]*gui.Node = undefined;

var table = gui.box(.{

    .grow = 1,
    .padding = .axes(0, theme.gap),
    .scroll = true,

}, &row_list);

var parts = [_]*gui.Node{ &cards, &heading, &table };
var root = gui.box(.{}, &parts);

/// Account names by user id, read once.
var names: [8][32]u8 = undefined;
var name_lengths: [8]usize = undefined;
var ids: [8]u32 = undefined;
var name_count: usize = 0;

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .application);

    processor.init("Processors", &processor_history);
    memory.init("Memory", &memory_history);
    card_parts = .{ &processor.node, &memory.node };
    cards.content.box = &card_parts;

    for (columns, 0..) |column, index| {

        heading_cells[index] = gui.label(column.title, theme.caption.with(.{

            .width = column.width,
            .grow = @as(u8, if (column.width == null) 1 else 0),
            .text_align = if (index == 0) gui.style.Alignment.left else .right,

        }));

        heading_parts[index] = &heading_cells[index];

    }

    for (&rows, 0..) |*row, index| {

        for (columns, 0..) |column, place| {

            cells[index][place] = gui.label("", .{

                .width = column.width,
                .grow = @as(u8, if (column.width == null) 1 else 0),

                .size = theme.small,
                .color = if (place == 0) theme.text else theme.muted,
                .text_align = if (place == 0) gui.style.Alignment.left else .right,

            });

            cell_parts[index][place] = &cells[index][place];

        }

        row.* = gui.box(theme.item.with(.{

            .height = 28,

        }), &cell_parts[index]);

        row_list[index] = row;

    }

    names_load();

    window = gui.Window.open(&root, .{

        .title = "Monitor",
        .application = .monitor,

        .width = 760,
        .height = 560,

    }) catch api.exit(3);

    var next: u64 = 0;

    while (true) {

        if (api.ticks() >= next) {

            next = api.ticks() + 100;
            sample();

        }

        const event = window.next(50) orelse continue;

        if (event.kind == .close) window.quit();

    }

}

/// Reads the counters once more and updates every view.
fn sample() void {

    const summary = api.stats(&records) catch return;
    const count: usize = @intCast(summary.records);
    const busy = summary.busy -| previous.busy;
    const total = busy + (summary.idle -| previous.idle);
    const elapsed = summary.uptime -| previous.uptime;
    const share = if (total == 0) 0 else @as(f32, @floatFromInt(busy)) / @as(f32, @floatFromInt(total));
    const used = summary.pages - summary.free;
    const fraction = @as(f32, @floatFromInt(used)) / @as(f32, @floatFromInt(@max(summary.pages, 1)));

    // The first reading stands for the time before the window opened, so the graphs do not climb from nothing.
    if (previous.uptime == 0) {

        @memset(&processor_history, std.math.clamp(share, 0, 1));
        @memset(&memory_history, std.math.clamp(fraction, 0, 1));

    }

    push(&processor_history, share);
    push(&memory_history, fraction);
    processor.plot.invalidate();
    memory.plot.invalidate();

    processor.value.content.label = std.fmt.bufPrint(&processor.bytes, "{d:.0}%", .{share * 100}) catch "";
    processor.detail.content.label = std.fmt.bufPrint(&processor.detail_bytes, "{d} processors, {d} processes", .{ summary.processors, summary.processes }) catch "";
    memory.value.content.label = std.fmt.bufPrint(&memory.bytes, "{d} MB", .{used * 4 / 1024}) catch "";
    memory.detail.content.label = std.fmt.bufPrint(&memory.detail_bytes, "of {d} MB, {d} MB free", .{ summary.pages * 4 / 1024, summary.free * 4 / 1024 }) catch "";

    // The busiest processes come first.
    std.sort.insertion(Usage, records[0..count], {}, busier);

    for (&rows, 0..) |*row, index| {

        row.hidden = index >= count;
        if (index >= count) continue;

        const record = &records[index];
        const cpu = if (elapsed == 0) 0 else @as(f32, @floatFromInt(record.ticks -| earlier(record.id))) * 100 / @as(f32, @floatFromInt(elapsed));

        const texts = [_][]const u8{

            name(record),
            std.fmt.bufPrint(&cell_bytes[index][1], "{d}", .{record.id}) catch "",
            owner(record.identity.user),
            @tagName(record.state),
            std.fmt.bufPrint(&cell_bytes[index][4], "{d} KB", .{record.pages * 4}) catch "",
            std.fmt.bufPrint(&cell_bytes[index][5], "{d:.1}%", .{cpu}) catch "",

        };

        for (texts, 0..) |value, place| cells[index][place].content.label = value;

    }

    @memcpy(before[0..count], records[0..count]);
    before_count = count;
    previous = summary;
    window.refresh();

}

fn busier(_: void, left: Usage, right: Usage) bool {

    return left.ticks -| earlier(left.id) > right.ticks -| earlier(right.id);

}

/// A process's tick count at the last sample, or its current one when it is new.
fn earlier(id: u64) u64 {

    for (before[0..before_count]) |record| {

        if (record.id == id) return record.ticks;

    }

    return 0;

}

fn name(record: *const Usage) []const u8 {

    if (record.image == Usage.anonymous) return if (record.owner == 0) "supervisor" else "process";

    const image = std.enums.fromInt(api.abi.Image, record.image) orelse return "process";

    return @tagName(image);

}

fn owner(user: u32) []const u8 {

    if (user == api.abi.system.user) return "system";
    if (user == api.abi.nobody.user) return "nobody";

    for (ids[0..name_count], 0..) |id, index| {

        if (id == user) return names[index][0..name_lengths[index]];

    }

    return "user";

}

fn names_load() void {

    while (name_count < names.len) {

        const account = (accounts.list(@intCast(name_count)) catch return) orelse return;
        const length = @min(account.name.len, 32);

        @memcpy(names[name_count][0..length], account.name[0..length]);
        name_lengths[name_count] = length;
        ids[name_count] = account.identity.user;
        name_count += 1;

    }

}

fn push(history: *[span]f32, value: f32) void {

    std.mem.copyForwards(f32, history[0 .. span - 1], history[1..]);
    history[span - 1] = std.math.clamp(value, 0, 1);

}
