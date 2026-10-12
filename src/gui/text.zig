const std = @import("std");

const font = @import("font.zig");

const api = @import("api");

/// Editable UTF-8 text in caller-owned `buffer`; the caret always sits between characters; secret text shows dots and is wiped by `clear`.
pub const Text = struct {

    buffer: []u8,
    length: usize = 0,
    caret: usize = 0,

    /// Where a selection started; the selection runs from here to the caret.
    anchor: ?usize = null,

    placeholder: []const u8 = "",
    secret: bool = false,

    /// First visible line of multi-line text, and how far single-line text scrolled left, in pixels.
    top: usize = 0,
    left: i32 = 0,

    /// The caret position last scrolled into view, so scrolling away from the caret sticks until it moves.
    mark: usize = std.math.maxInt(usize),

    /// Bumped by every edit, so owners can tell unsaved changes.
    version: u64 = 0,

    pub const Range = struct {

        start: usize,
        end: usize,

    };

    pub fn text(self: *const Text) []const u8 {

        return self.buffer[0..self.length];

    }

    /// The selected bytes' range, or null when nothing is selected.
    pub fn selection(self: *const Text) ?Range {

        const anchor = self.anchor orelse return null;
        if (anchor == self.caret) return null;

        return .{

            .start = @min(anchor, self.caret),
            .end = @max(anchor, self.caret),

        };

    }

    /// The selected text; secret text never leaves.
    pub fn selected(self: *const Text) []const u8 {

        const range = self.selection() orelse return "";

        return if (self.secret) "" else self.buffer[range.start..range.end];

    }

    pub fn clear(self: *Text) void {

        std.crypto.secureZero(u8, self.buffer);
        self.length = 0;
        self.caret = 0;
        self.anchor = null;
        self.top = 0;
        self.left = 0;
        self.version +%= 1;

    }

    pub fn set(self: *Text, string: []const u8) void {

        self.clear();
        self.length = @min(string.len, self.buffer.len);
        @memcpy(self.buffer[0..self.length], string[0..self.length]);
        self.caret = self.length;

    }

    pub fn all(self: *Text) void {

        self.anchor = 0;
        self.caret = self.length;

    }

    /// Selects the word around the caret.
    pub fn word(self: *Text) void {

        const string = self.text();
        var first = self.caret;
        var end = self.caret;

        while (first > 0 and wordy(string[first - 1])) first -= 1;
        while (end < string.len and wordy(string[end])) end += 1;

        self.anchor = first;
        self.caret = end;

    }

    /// Replaces the selection, if any, with `string`; false when it does not fit.
    pub fn paste(self: *Text, string: []const u8) bool {

        _ = self.erase();
        if (self.length + string.len > self.buffer.len) return false;

        std.mem.copyBackwards(u8, self.buffer[self.caret + string.len .. self.length + string.len], self.buffer[self.caret..self.length]);
        @memcpy(self.buffer[self.caret..][0..string.len], string);
        self.length += string.len;
        self.caret += string.len;
        self.version +%= 1;

        return true;

    }

    /// Deletes the selection; false when there was none.
    pub fn erase(self: *Text) bool {

        const range = self.selection() orelse {

            self.anchor = null;
            return false;

        };

        self.caret = range.start;
        self.anchor = null;
        self.remove(range.end - range.start);

        return true;

    }

    /// Applies an editing key press; true when the text, caret, or selection changed.
    pub fn key(self: *Text, event: api.Event, multiline: bool) bool {

        if (event.kind != .key or !event.pressed) return false;

        const jump = event.modifiers.control;

        switch (event.key()) {

            .character => {

                if (event.chord(.{ .control = true }, 'a')) {

                    self.all();
                    return true;

                }

                if (event.modifiers.control or event.modifiers.alt or event.modifiers.super or event.char < 0x20 or event.char == 0x7f) return false;
                return self.insert(event.char);

            },
            .enter => return multiline and self.insert('\n'),
            .tab => return multiline and !event.modifiers.control and self.paste("    "),
            .backspace => {

                if (self.erase()) return true;
                if (self.caret == 0) return false;

                const end = self.caret;

                self.caret = if (jump) self.boundary(self.caret, -1) else self.before(self.caret);
                self.remove(end - self.caret);

            },
            .delete => {

                if (self.erase()) return true;
                if (self.caret == self.length) return false;
                self.remove((if (jump) self.boundary(self.caret, 1) else self.after(self.caret)) - self.caret);

            },
            .left, .right, .home, .end => {

                const range = self.selection();

                // Without shift, an arrow collapses a selection to its edge.
                if (!event.modifiers.shift and range != null and (event.key() == .left or event.key() == .right)) {

                    self.caret = if (event.key() == .left) range.?.start else range.?.end;
                    self.anchor = null;

                    return true;

                }

                const target = switch (event.key()) {

                    .left => if (self.caret == 0) 0 else if (jump) self.boundary(self.caret, -1) else self.before(self.caret),
                    .right => if (self.caret == self.length) self.length else if (jump) self.boundary(self.caret, 1) else self.after(self.caret),
                    .home => if (multiline and !jump) self.start(self.caret) else 0,
                    else => if (multiline and !jump) std.mem.indexOfScalarPos(u8, self.text(), self.caret, '\n') orelse self.length else self.length,

                };

                if (target == self.caret and (event.modifiers.shift or self.anchor == null)) return false;

                self.select(target, event.modifiers.shift);

            },
            else => return false,

        }

        return true;

    }

    /// Moves the caret to `target`, extending the selection when `extend`, else dropping it.
    pub fn select(self: *Text, target: usize, extend: bool) void {

        if (extend and self.anchor == null) self.anchor = self.caret;
        if (!extend) self.anchor = null;
        self.caret = @min(target, self.length);

    }

    /// Moves the caret `delta` wrapped lines, keeping its horizontal position; false at the first or last line.
    pub fn vertical(self: *Text, face: *const font.Font, size: f32, width: i32, delta: i32, extend: bool) bool {

        const scale = size / face.units;
        const string = self.text();
        var lines = Lines.init(face, string, size, width);
        var trail: [64]Line = undefined;
        var seen: usize = 0;

        while (lines.next()) |line| : (seen += 1) {

            trail[seen % trail.len] = line;
            if (!line.holds(string, self.caret)) continue;

            const x = face.measure(string[line.start..self.caret], scale);
            var target = line;

            if (delta < 0) {

                const back: usize = @min(@abs(delta), seen, trail.len - 1);
                if (back == 0) return false;

                target = trail[(seen - back) % trail.len];

            } else {

                for (0..@abs(delta)) |_| target = lines.next() orelse break;
                if (target.start == line.start) return false;

            }

            self.select(nearest(face, scale, string, target, x), extend);

            return true;

        }

        return false;

    }

    /// The caret position closest to `x` pixels into wrapped line `row`, or into the only line of single-line text.
    pub fn locate(self: *const Text, face: *const font.Font, size: f32, width: i32, x: f32, row: ?usize) usize {

        const scale = size / face.units;
        const string = self.text();

        if (row == null) return nearest(face, scale, string, .{

            .start = 0,
            .end = string.len,

        }, x);

        var lines = Lines.init(face, string, size, width);
        var index: usize = 0;

        var last = Line{

            .start = 0,
            .end = 0,

        };

        while (lines.next()) |line| : (index += 1) {

            last = line;
            if (index == row.?) break;

        }

        return nearest(face, scale, string, last, x);

    }

    fn insert(self: *Text, char: u21) bool {

        var bytes: [4]u8 = undefined;
        const count = std.unicode.utf8Encode(char, &bytes) catch return false;

        return self.paste(bytes[0..count]);

    }

    /// Removes `count` bytes at the caret.
    fn remove(self: *Text, count: usize) void {

        std.mem.copyForwards(u8, self.buffer[self.caret .. self.length - count], self.buffer[self.caret + count .. self.length]);
        self.length -= count;
        @memset(self.buffer[self.length..][0..count], 0);
        self.version +%= 1;

    }

    /// Where the word before (`direction` -1) or after (1) `at` begins or ends.
    fn boundary(self: *const Text, at: usize, direction: i8) usize {

        const string = self.text();
        var index = at;

        if (direction < 0) {

            while (index > 0 and !wordy(string[index - 1])) index -= 1;
            while (index > 0 and wordy(string[index - 1])) index -= 1;

        } else {

            while (index < string.len and !wordy(string[index])) index += 1;
            while (index < string.len and wordy(string[index])) index += 1;

        }

        return index;

    }

    /// Where the character before `at` starts.
    fn before(self: *const Text, at: usize) usize {

        var index = at - 1;

        while (index > 0 and inner(self.buffer[index])) index -= 1;

        return index;

    }

    /// Where the character after `at` starts.
    fn after(self: *const Text, at: usize) usize {

        var index = at + 1;

        while (index < self.length and inner(self.buffer[index])) index += 1;

        return index;

    }

    fn start(self: *const Text, from: usize) usize {

        const newline = std.mem.lastIndexOfScalar(u8, self.buffer[0..from], '\n') orelse return 0;

        return newline + 1;

    }

};

/// One wrapped line as a byte range; a hard break's newline is not included.
pub const Line = struct {

    start: usize,
    end: usize,

    /// Whether `caret` sits on this line; a caret at a soft break belongs to the next one.
    pub fn holds(self: Line, string: []const u8, caret: usize) bool {

        if (caret < self.start or caret > self.end) return false;

        return caret < self.end or caret == string.len or string[caret] == '\n';

    }

};

/// Splits `string` into lines no wider than `width` pixels, breaking after spaces where possible.
pub const Lines = struct {

    face: *const font.Font,
    string: []const u8,
    scale: f32,
    width: f32,
    index: usize = 0,

    pub fn init(face: *const font.Font, string: []const u8, size: f32, width: i32) Lines {

        return .{

            .face = face,
            .string = string,
            .scale = size / face.units,
            .width = @floatFromInt(@max(width, 1)),

        };

    }

    pub fn next(self: *Lines) ?Line {

        if (self.index > self.string.len) return null;

        const begin = self.index;
        const stop = std.mem.indexOfScalarPos(u8, self.string, begin, '\n') orelse self.string.len;
        var span: f32 = 0;
        var previous: u16 = 0;
        var space: ?usize = null;

        var characters = font.Characters{

            .bytes = self.string[0..stop],
            .index = begin,

        };

        while (characters.index < stop) {

            const position = characters.index;
            const char = characters.next().?;
            const glyph = self.face.lookup(char);

            span += (self.face.kerning(previous, glyph) + self.face.advance(glyph)) * self.scale;
            previous = glyph;

            if (span > self.width and position > begin) {

                const end = space orelse position;

                self.index = end;

                return .{

                    .start = begin,
                    .end = end,

                };

            }

            if (char == ' ') space = characters.index;

        }

        self.index = stop + 1;

        return .{

            .start = begin,
            .end = stop,

        };

    }

};

/// How far below the top of a line of text at `size` its baseline sits.
pub fn ascent(face: *const font.Font, size: f32) i32 {

    return @intFromFloat(@as(f32, @floatFromInt(face.ascent)) * size / face.units);

}

/// Pixel height of one line of text at `size`.
pub fn leading(face: *const font.Font, size: f32) i32 {

    const span: f32 = @floatFromInt(@as(i32, face.ascent) + @as(i32, @abs(face.descent)));

    return @intFromFloat(@ceil(span * size / face.units));

}

/// The position in `line` whose distance from the line's start is closest to `x` pixels.
fn nearest(face: *const font.Font, scale: f32, string: []const u8, line: Line, x: f32) usize {

    var best = line.start;
    var distance = @abs(x);
    var pen: f32 = 0;
    var previous: u16 = 0;

    var characters = font.Characters{

        .bytes = string[0..line.end],
        .index = line.start,

    };

    while (characters.next()) |char| {

        const glyph = face.lookup(char);

        pen += (face.kerning(previous, glyph) + face.advance(glyph)) * scale;
        previous = glyph;

        if (@abs(pen - x) < distance) {

            distance = @abs(pen - x);
            best = characters.index;

        }

    }

    return best;

}

/// Whether `byte` belongs to a word: letters, digits, underscores, and any non-ASCII character.
fn wordy(byte: u8) bool {

    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte >= 0x80;

}

/// Whether `byte` continues a UTF-8 sequence rather than starting a character.
fn inner(byte: u8) bool {

    return byte & 0xc0 == 0x80;

}
