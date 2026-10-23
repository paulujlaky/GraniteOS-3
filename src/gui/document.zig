//! Text being edited: UTF-8 bytes that grow as needed, an index of where each line starts, and a history to undo and redo.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = error{OutOfMemory};

/// A caret and where the selection it drags began, as byte offsets; equal when nothing is selected.
pub const Selection = struct {

    anchor: usize,
    caret: usize,

    pub fn at(offset: usize) Selection {

        return .{

            .anchor = offset,
            .caret = offset,

        };

    }

    pub fn start(self: Selection) usize {

        return @min(self.anchor, self.caret);

    }

    pub fn end(self: Selection) usize {

        return @max(self.anchor, self.caret);

    }

    pub fn empty(self: Selection) bool {

        return self.anchor == self.caret;

    }

};

/// How an edit joins the history: typed characters gather into a step a word at a time, deletions into one step, and `joined`
/// adds to the step before, as the parts of one command do; anything else, or a `seal`, starts a step of its own.
pub const Kind = enum {

    typing,
    deleting,
    other,
    joined,

};

/// A run of bytes in the history's log.
const Span = struct {

    start: usize,
    length: usize,

};

const Record = struct {

    at: usize,
    removed: Span,
    inserted: Span,

    step: u64,
    kind: Kind,

    /// The selection before the step began, given back when it is undone.
    before: Selection,

};

pub const Document = struct {

    allocator: Allocator,

    bytes: std.ArrayList(u8) = .empty,

    /// Where each line after the first starts: one past every newline, in order.
    starts: std.ArrayList(usize) = .empty,

    records: std.ArrayList(Record) = .empty,
    log: std.ArrayList(u8) = .empty,

    /// Records before this one can be undone; the rest are redone in order.
    done: usize = 0,

    /// The last step given out, so every step is told apart even after being undone and replaced.
    steps: u64 = 0,

    /// The next edit starts a step of its own whatever its kind.
    sealed: bool = true,

    /// Bumped by every change, undo and redo included.
    version: u64 = 0,

    /// The first line changed since an owner last cleared it, such as a highlighter keeping per-line state.
    touched: usize = std.math.maxInt(usize),

    pub fn init(allocator: Allocator) Document {

        return .{

            .allocator = allocator,

        };

    }

    pub fn deinit(self: *Document) void {

        self.bytes.deinit(self.allocator);
        self.starts.deinit(self.allocator);
        self.records.deinit(self.allocator);
        self.log.deinit(self.allocator);
        self.* = init(self.allocator);

    }

    pub fn text(self: *const Document) []const u8 {

        return self.bytes.items;

    }

    pub fn length(self: *const Document) usize {

        return self.bytes.items.len;

    }

    /// Lines, counting the one after a final newline.
    pub fn count(self: *const Document) usize {

        return self.starts.items.len + 1;

    }

    pub fn start(self: *const Document, number: usize) usize {

        return if (number == 0) 0 else self.starts.items[@min(number, self.starts.items.len) - 1];

    }

    /// Where line `number` ends, before its newline.
    pub fn end(self: *const Document, number: usize) usize {

        return if (number + 1 < self.count()) self.starts.items[number] - 1 else self.bytes.items.len;

    }

    /// The bytes of line `number`, without its newline.
    pub fn content(self: *const Document, number: usize) []const u8 {

        return self.bytes.items[self.start(number)..self.end(number)];

    }

    /// The line holding byte `offset`; an offset just past a newline begins the next line.
    pub fn line(self: *const Document, offset: usize) usize {

        return std.sort.upperBound(usize, self.starts.items, offset, order);

    }

    /// Replaces the whole text with `string` and forgets the history, as when opening a file.
    pub fn set(self: *Document, string: []const u8) Error!void {

        try self.bytes.ensureTotalCapacity(self.allocator, string.len);

        self.bytes.clearRetainingCapacity();
        self.bytes.appendSliceAssumeCapacity(string);
        try self.reset();

    }

    /// Takes `owned`, allocated by the document's allocator, as the whole text, saving a copy of a file just read.
    pub fn adopt(self: *Document, owned: []u8) Error!void {

        self.bytes.deinit(self.allocator);
        self.bytes = .fromOwnedSlice(owned);
        try self.reset();

    }

    fn reset(self: *Document) Error!void {

        self.records.clearRetainingCapacity();
        self.log.clearRetainingCapacity();
        self.done = 0;
        self.sealed = true;
        self.version +%= 1;
        self.touched = 0;
        self.starts.clearRetainingCapacity();

        const string = self.bytes.items;

        try self.starts.ensureTotalCapacity(self.allocator, std.mem.count(u8, string, "\n"));

        for (string, 0..) |byte, index| {

            if (byte == '\n') self.starts.appendAssumeCapacity(index + 1);

        }

    }

    /// Replaces bytes `from` to `to` with `string`, recording it to undo; `before` is the selection to give back on undoing.
    pub fn replace(self: *Document, from: usize, to: usize, string: []const u8, before: Selection, kind: Kind) Error!void {

        if (from == to and string.len == 0) return;

        try self.reserve(string.len, std.mem.count(u8, string, "\n"));
        self.record(from, to, string, before, kind);
        self.splice(from, to, string);

    }

    /// Undoes the newest step, returning the selection from before it; null when there is nothing to undo.
    pub fn undo(self: *Document) Error!?Selection {

        if (self.done == 0) return null;

        const step = self.records.items[self.done - 1].step;
        var first = self.done;
        var bytes: usize = 0;
        var lines: usize = 0;

        while (first > 0 and self.records.items[first - 1].step == step) {

            first -= 1;

            const removed = self.slice(self.records.items[first].removed);

            bytes += removed.len;
            lines += std.mem.count(u8, removed, "\n");

        }

        try self.reserve(bytes, lines);

        var index = self.done;

        while (index > first) {

            index -= 1;

            const change = self.records.items[index];

            self.splice(change.at, change.at + change.inserted.length, self.slice(change.removed));

        }

        self.done = first;
        self.sealed = true;

        return self.records.items[first].before;

    }

    /// Redoes the newest step undone, returning a caret just after it; null when there is nothing to redo.
    pub fn redo(self: *Document) Error!?Selection {

        if (self.done == self.records.items.len) return null;

        const step = self.records.items[self.done].step;
        var last = self.done;
        var bytes: usize = 0;
        var lines: usize = 0;

        while (last < self.records.items.len and self.records.items[last].step == step) : (last += 1) {

            const inserted = self.slice(self.records.items[last].inserted);

            bytes += inserted.len;
            lines += std.mem.count(u8, inserted, "\n");

        }

        try self.reserve(bytes, lines);

        for (self.records.items[self.done..last]) |change| {

            self.splice(change.at, change.at + change.removed.length, self.slice(change.inserted));

        }

        const final = self.records.items[last - 1];

        self.done = last;
        self.sealed = true;

        return .at(final.at + final.inserted.length);

    }

    /// Which step the text is at, to tell whether it matches what was saved; zero before any edit since opening.
    pub fn revision(self: *const Document) u64 {

        return if (self.done == 0) 0 else self.records.items[self.done - 1].step;

    }

    /// Ends the current step, so the next edit starts another, as after the caret jumps or the text is saved.
    pub fn seal(self: *Document) void {

        self.sealed = true;

    }

    /// Makes room for `bytes` more bytes and `lines` more line starts, so a change cannot fail halfway.
    fn reserve(self: *Document, bytes: usize, lines: usize) Error!void {

        try self.bytes.ensureUnusedCapacity(self.allocator, bytes);
        try self.starts.ensureUnusedCapacity(self.allocator, lines);

    }

    /// Notes a change in the history, joining the step before when `kind` continues it; forgets the history rather than fail.
    fn record(self: *Document, from: usize, to: usize, string: []const u8, before: Selection, kind: Kind) void {

        // A new change drops whatever was undone.
        self.records.shrinkRetainingCapacity(self.done);
        self.log.shrinkRetainingCapacity(if (self.done == 0) 0 else blk: {

            const last = self.records.items[self.done - 1];

            break :blk last.inserted.start + last.inserted.length;

        });

        const joined = !self.sealed and self.done != 0 and self.continues(self.records.items[self.done - 1], from, to, string, kind);

        if (!joined) self.steps += 1;

        self.records.ensureUnusedCapacity(self.allocator, 1) catch return self.forget();
        self.log.ensureUnusedCapacity(self.allocator, to - from + string.len) catch return self.forget();

        const removed = Span{

            .start = self.log.items.len,
            .length = to - from,

        };

        self.log.appendSliceAssumeCapacity(self.bytes.items[from..to]);

        const inserted = Span{

            .start = self.log.items.len,
            .length = string.len,

        };

        self.log.appendSliceAssumeCapacity(string);

        self.records.appendAssumeCapacity(.{

            .at = from,
            .removed = removed,
            .inserted = inserted,

            .step = self.steps,
            .kind = if (kind == .joined and joined) .other else kind,

            .before = before,

        });

        self.done = self.records.items.len;
        self.sealed = false;

    }

    /// Whether a change of `kind` replacing `from` to `to` with `string` carries on from `last`.
    fn continues(self: *const Document, last: Record, from: usize, to: usize, string: []const u8, kind: Kind) bool {

        return switch (kind) {

            .joined => true,
            .other => false,
            .typing => blk: {

                if (last.kind != .typing or from != to or from != last.at + last.inserted.length) break :blk false;
                if (last.inserted.length == 0) break :blk true;

                // A word and the spaces after it undo together; a newline or the next word starts afresh.
                const previous = self.log.items[last.inserted.start + last.inserted.length - 1];

                break :blk previous != '\n' and !(space(previous) and !space(string[0]));

            },
            .deleting => last.kind == .deleting and string.len == 0 and last.inserted.length == 0 and (to == last.at or from == last.at),

        };

    }

    fn forget(self: *Document) void {

        self.records.clearRetainingCapacity();
        self.log.clearRetainingCapacity();
        self.done = 0;
        self.sealed = true;

    }

    fn slice(self: *const Document, span: Span) []const u8 {

        return self.log.items[span.start..][0..span.length];

    }

    /// Replaces bytes `from` to `to` with `string` and moves the line starts after them, in room already reserved.
    fn splice(self: *Document, from: usize, to: usize, string: []const u8) void {

        const line_index = self.line(from);
        const starts = &self.starts;

        // Lines starting inside the replaced bytes go, and those the new bytes begin take their place.
        const first = line_index;
        const last = std.sort.upperBound(usize, starts.items, to, order);
        const added = std.mem.count(u8, string, "\n");
        const old = starts.items.len;
        const total = old - (last - first) + added;

        if (total > old) {

            starts.items.len = total;
            std.mem.copyBackwards(usize, starts.items[first + added ..], starts.items[last..old]);

        } else {

            std.mem.copyForwards(usize, starts.items[first + added ..][0 .. old - last], starts.items[last..old]);
            starts.items.len = total;

        }

        var slot = first;

        for (string, 0..) |byte, index| {

            if (byte != '\n') continue;

            starts.items[slot] = from + index + 1;
            slot += 1;

        }

        for (starts.items[first + added ..]) |*value| value.* = value.* + string.len - (to - from);

        self.bytes.replaceRangeAssumeCapacity(from, to - from, string);
        self.version +%= 1;
        self.touched = @min(self.touched, line_index);

    }

};

fn order(key: usize, value: usize) std.math.Order {

    return std.math.order(key, value);

}

fn space(byte: u8) bool {

    return byte == ' ' or byte == '\t';

}
