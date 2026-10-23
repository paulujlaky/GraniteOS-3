//! Regular expressions over UTF-8 text, matched by a Pike VM so time grows with the text and never explodes with the pattern:
//! literals and escapes, `.`, classes such as `[^a-z]` and `\d\w\s`, anchors `^ $ \b`, groups, alternation, and greedy or lazy
//! `* + ? {n,m}`. The leftmost match wins, and among those the one the pattern prefers, as in Perl.

const std = @import("std");

const font = @import("font.zig");
const text = @import("text.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{ Invalid, Complex, OutOfMemory };

/// Capturing groups a pattern may number, as `$1` to `$9` name them in a replacement; later groups only group.
pub const groups = 9;

/// Where the whole match, then each group, starts and ends; `unset` for a group that took no part.
pub const Captures = [slots]usize;
pub const unset = std.math.maxInt(usize);

const slots = 2 * (groups + 1);

/// Instructions in a compiled pattern, at most; counted repeats copy their body, so nesting them reaches this quickly.
const most = 4096;

/// Groups nested inside each other, at most.
const deepest = 32;

const none = std.math.maxInt(u16);

const Range = struct {

    low: u21,
    high: u21,

};

/// A run of `ranges`, any of which matches, or none when negated.
const Class = struct {

    first: u16,
    count: u16,
    negated: bool,

};

/// One parsed piece of the pattern; `next` links the pieces of a sequence or the branches of a choice.
const Tree = struct {

    node: union(enum) {

        empty,
        char: u21,
        any,
        class: Class,
        start,
        finish,
        boundary: bool,
        group: struct {

            inner: u16,
            slot: ?u8,

        },
        sequence: u16,
        choice: u16,
        repeat: struct {

            inner: u16,
            min: u16,
            max: ?u16,
            greedy: bool,

        },

    },

    next: u16 = none,

};

const Op = union(enum) {

    char: u21,
    any,
    class: Class,

    /// Both ways on, the first preferred.
    split: [2]u16,
    jump: u16,
    save: u8,

    start,
    finish,
    boundary: bool,
    match,

};

/// Threads at one position of the text, in order of preference, each with its captures.
const List = struct {

    pcs: []u16,
    captures: []usize,
    count: usize = 0,
    stamp: u64 = 0,

};

const Frame = union(enum) {

    visit: u16,

    /// Puts a capture back once everything after the save that changed it has been followed.
    restore: struct {

        slot: u8,
        value: usize,

    },

};

pub const Regex = struct {

    arena: std.heap.ArenaAllocator,
    program: []const Op,
    ranges: []const Range,

    /// Letters match either case.
    fold: bool,

    /// A byte every match starts with, to skip ahead to while no thread is alive.
    lead: ?u8,

    lists: [2]List,
    seen: []u64,
    stamp: u64 = 0,
    stack: []Frame,
    scratch: Captures = undefined,

    pub fn compile(allocator: Allocator, pattern: []const u8, fold: bool) Error!Regex {

        var arena = std.heap.ArenaAllocator.init(allocator);

        errdefer arena.deinit();

        const memory = arena.allocator();

        var parser = Parser{

            .pattern = pattern,
            .allocator = memory,

        };

        const root = try parser.choice();

        if (parser.index != pattern.len) return error.Invalid;

        var builder = Builder{

            .allocator = memory,
            .trees = parser.trees.items,
            .fold = fold,

        };

        try builder.push(.{ .save = 0 });
        try builder.emit(root);
        try builder.push(.{ .save = 1 });
        try builder.push(.match);

        const program = builder.program.items;
        const length = program.len;

        var lead: ?u8 = null;

        for (program) |op| switch (op) {

            .save => continue,
            .char => |char| {

                if (char < 0x80 and !(fold and std.ascii.isAlphabetic(@intCast(char)))) lead = @intCast(char);
                break;

            },
            else => break,

        };

        var result = Regex{

            .arena = undefined,
            .program = program,
            .ranges = parser.ranges.items,
            .fold = fold,
            .lead = lead,

            .lists = undefined,
            .seen = try memory.alloc(u64, length),
            .stack = try memory.alloc(Frame, 2 * length + 2),

        };

        for (&result.lists) |*list| list.* = .{

            .pcs = try memory.alloc(u16, length),
            .captures = try memory.alloc(usize, length * slots),

        };

        @memset(result.seen, 0);
        result.arena = arena;

        return result;

    }

    pub fn deinit(self: *Regex) void {

        self.arena.deinit();

    }

    /// The leftmost match starting at or after `from` in `haystack`, with its groups.
    pub fn find(self: *Regex, haystack: []const u8, from: usize) ?Captures {

        var current = &self.lists[0];
        var following = &self.lists[1];
        var found: ?Captures = null;
        var position = from;

        self.begin(current);

        while (true) {

            // Until something matches, every position may start a match, least preferred of all.
            if (found == null) {

                if (current.count == 0) if (self.lead) |byte| {

                    position = std.mem.indexOfScalarPos(u8, haystack, position, byte) orelse return null;

                };

                @memset(&self.scratch, unset);
                self.add(current, 0, &self.scratch, haystack, position);

            }

            const char, const width = decode(haystack, position);

            if (current.count == 0) {

                if (found != null or char == null) break;

                // Nothing can start here, as when an assertion fails, so try the next character.
                position += width;
                self.begin(current);
                continue;

            }

            self.begin(following);

            for (0..current.count) |index| {

                const pc = current.pcs[index];
                const captures = current.captures[index * slots ..][0..slots];

                const advance = switch (self.program[pc]) {

                    .match => {

                        // Whatever this thread was preferred over can only come second.
                        found = captures.*;
                        break;

                    },
                    .char => |want| char != null and self.folded(char.?) == want,
                    .any => char != null and char.? != '\n',
                    .class => |class| char != null and self.within(class, char.?),
                    else => unreachable,

                };

                if (advance) self.add(following, pc + 1, captures, haystack, position + width);

            }

            if (char == null) break;

            std.mem.swap(*List, &current, &following);
            position += width;

        }

        return found;

    }

    fn begin(self: *Regex, list: *List) void {

        self.stamp += 1;
        list.count = 0;
        list.stamp = self.stamp;

    }

    /// Adds the thread at `pc` to `list`, following every jump, split, save, and assertion first.
    fn add(self: *Regex, list: *List, pc: u16, captures: *const Captures, haystack: []const u8, position: usize) void {

        var scratch = captures.*;
        var depth: usize = 0;

        self.stack[depth] = .{ .visit = pc };
        depth += 1;

        while (depth > 0) {

            depth -= 1;

            const at = switch (self.stack[depth]) {

                .restore => |saved| {

                    scratch[saved.slot] = saved.value;
                    continue;

                },
                .visit => |at| at,

            };

            if (self.seen[at] == list.stamp) continue;
            self.seen[at] = list.stamp;

            switch (self.program[at]) {

                .jump => |target| {

                    self.stack[depth] = .{ .visit = target };
                    depth += 1;

                },
                .split => |targets| {

                    self.stack[depth] = .{ .visit = targets[1] };
                    self.stack[depth + 1] = .{ .visit = targets[0] };
                    depth += 2;

                },
                .save => |slot| {

                    self.stack[depth] = .{ .restore = .{ .slot = slot, .value = scratch[slot] } };
                    self.stack[depth + 1] = .{ .visit = at + 1 };
                    scratch[slot] = position;
                    depth += 2;

                },
                .start, .finish, .boundary => {

                    if (!assert(self.program[at], haystack, position)) continue;

                    self.stack[depth] = .{ .visit = at + 1 };
                    depth += 1;

                },
                else => {

                    list.pcs[list.count] = at;
                    @memcpy(list.captures[list.count * slots ..][0..slots], &scratch);
                    list.count += 1;

                },

            }

        }

    }

    fn folded(self: *const Regex, char: u21) u21 {

        return if (self.fold) lower(char) else char;

    }

    fn within(self: *const Regex, class: Class, char: u21) bool {

        var inside = false;

        for (self.ranges[class.first..][0..class.count]) |range| {

            if (char >= range.low and char <= range.high) inside = true;
            if (self.fold and (lower(char) >= range.low and lower(char) <= range.high or upper(char) >= range.low and upper(char) <= range.high)) inside = true;

        }

        return inside != class.negated;

    }

};

fn assert(op: Op, haystack: []const u8, position: usize) bool {

    return switch (op) {

        .start => position == 0 or haystack[position - 1] == '\n',
        .finish => position == haystack.len or haystack[position] == '\n' or (haystack[position] == '\r' and position + 1 < haystack.len and haystack[position + 1] == '\n'),
        .boundary => |wanted| wanted == ((position > 0 and text.wordy(haystack[position - 1])) != (position < haystack.len and text.wordy(haystack[position]))),
        else => unreachable,

    };

}

/// The character at `position` and its length in bytes; null past the end. A malformed byte reads as U+FFFD.
fn decode(haystack: []const u8, position: usize) struct { ?u21, usize } {

    if (position >= haystack.len) return .{ null, 0 };

    var characters = font.Characters{

        .bytes = haystack,
        .index = position,

    };

    const char = characters.next().?;

    return .{ char, characters.index - position };

}

fn lower(char: u21) u21 {

    return if (char < 0x80) std.ascii.toLower(@intCast(char)) else char;

}

fn upper(char: u21) u21 {

    return if (char < 0x80) std.ascii.toUpper(@intCast(char)) else char;

}

const Parser = struct {

    pattern: []const u8,
    index: usize = 0,
    allocator: Allocator,

    trees: std.ArrayList(Tree) = .empty,
    ranges: std.ArrayList(Range) = .empty,

    groups: u8 = 0,
    depth: usize = 0,

    fn choice(self: *Parser) Error!u16 {

        const first = try self.sequence();
        if (self.peek() != '|') return first;

        var last = first;

        while (self.peek() == '|') {

            self.index += 1;

            const branch = try self.sequence();

            self.trees.items[last].next = branch;
            last = branch;

        }

        return self.add(.{ .choice = first });

    }

    fn sequence(self: *Parser) Error!u16 {

        var first: u16 = none;
        var last: u16 = none;

        while (self.index < self.pattern.len and self.peek() != '|' and self.peek() != ')') {

            const piece = try self.quantify(try self.atom());

            if (first == none) first = piece else self.trees.items[last].next = piece;
            last = piece;

        }

        if (first == none) return self.add(.empty);
        if (self.trees.items[first].next == none) return first;

        return self.add(.{ .sequence = first });

    }

    fn atom(self: *Parser) Error!u16 {

        const char = self.take();

        return switch (char) {

            '.' => self.add(.any),
            '^' => self.add(.start),
            '$' => self.add(.finish),
            '[' => self.add(.{ .class = try self.class() }),
            '(' => self.group(),
            '\\' => self.escape(),
            '*', '+', '?', ')' => error.Invalid,
            else => self.add(.{ .char = char }),

        };

    }

    fn group(self: *Parser) Error!u16 {

        if (self.depth == deepest) return error.Complex;

        var slot: ?u8 = null;

        if (std.mem.startsWith(u8, self.pattern[self.index..], "?:")) {

            self.index += 2;

        } else if (self.peek() == '?') {

            return error.Invalid;

        } else if (self.groups < groups) {

            self.groups += 1;
            slot = self.groups;

        }

        self.depth += 1;

        const inner = try self.choice();

        self.depth -= 1;
        if (self.peek() != ')') return error.Invalid;
        self.index += 1;

        return self.add(.{ .group = .{ .inner = inner, .slot = slot } });

    }

    fn escape(self: *Parser) Error!u16 {

        if (self.index == self.pattern.len) return error.Invalid;

        const char = self.pattern[self.index];

        switch (char) {

            'b', 'B' => {

                self.index += 1;
                return self.add(.{ .boundary = char == 'b' });

            },
            'd', 'D', 'w', 'W', 's', 'S' => {

                self.index += 1;

                const first: u16 = @intCast(self.ranges.items.len);

                try self.shorthand(std.ascii.toLower(char));

                return self.add(.{ .class = .{ .first = first, .count = @intCast(self.ranges.items.len - first), .negated = std.ascii.isUpper(char) } });

            },
            else => return self.add(.{ .char = try self.literal() }),

        }

    }

    /// An escaped character after a backslash, as a literal.
    fn literal(self: *Parser) Error!u21 {

        const char = self.pattern[self.index];

        self.index += 1;

        return switch (char) {

            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'f' => 0x0c,
            'v' => 0x0b,
            '0' => 0,
            'x' => {

                if (self.index + 2 > self.pattern.len) return error.Invalid;

                const value = std.fmt.parseInt(u8, self.pattern[self.index..][0..2], 16) catch return error.Invalid;

                self.index += 2;

                return value;

            },
            else => if (std.ascii.isAlphanumeric(char)) error.Invalid else char,

        };

    }

    fn shorthand(self: *Parser, which: u8) Error!void {

        const sets: []const Range = switch (which) {

            'd' => &[_]Range{.{ .low = '0', .high = '9' }},
            'w' => &[_]Range{ .{ .low = '0', .high = '9' }, .{ .low = 'A', .high = 'Z' }, .{ .low = 'a', .high = 'z' }, .{ .low = '_', .high = '_' } },
            else => &[_]Range{ .{ .low = ' ', .high = ' ' }, .{ .low = '\t', .high = '\r' } },

        };

        try self.ranges.appendSlice(self.allocator, sets);

    }

    fn class(self: *Parser) Error!Class {

        const first: u16 = @intCast(self.ranges.items.len);
        const negated = self.peek() == '^';

        if (negated) self.index += 1;

        var initial = true;

        while (true) : (initial = false) {

            if (self.index == self.pattern.len) return error.Invalid;
            if (self.peek() == ']' and !initial) break;

            var low = self.take();

            if (low == '\\') {

                if (self.index == self.pattern.len) return error.Invalid;

                const which = self.pattern[self.index];

                if (which == 'd' or which == 'w' or which == 's') {

                    self.index += 1;
                    try self.shorthand(which);
                    continue;

                }

                if (which == 'D' or which == 'W' or which == 'S' or which == 'b' or which == 'B') return error.Invalid;

                low = try self.literal();

            }

            var high = low;

            if (self.peek() == '-' and self.index + 1 < self.pattern.len and self.pattern[self.index + 1] != ']') {

                self.index += 1;
                high = self.take();

                if (high == '\\') {

                    if (self.index == self.pattern.len) return error.Invalid;
                    high = try self.literal();

                }

                if (high < low) return error.Invalid;

            }

            try self.ranges.append(self.allocator, .{ .low = low, .high = high });

        }

        self.index += 1;

        if (self.ranges.items.len - first > std.math.maxInt(u16)) return error.Complex;

        return .{

            .first = first,
            .count = @intCast(self.ranges.items.len - first),
            .negated = negated,

        };

    }

    fn quantify(self: *Parser, inner: u16) Error!u16 {

        var min: u16 = 0;
        var max: ?u16 = null;

        switch (self.peek()) {

            '*' => {},
            '+' => min = 1,
            '?' => max = 1,
            '{' => {

                const counted = self.count() orelse return inner;

                min = counted[0];
                max = counted[1];
                self.index -= 1;

            },
            else => return inner,

        }

        self.index += 1;

        const greedy = self.peek() != '?';

        if (!greedy) self.index += 1;

        const next = self.peek();

        if (next == '*' or next == '+' or next == '?') return error.Invalid;
        if (next == '{' and self.count() != null) return error.Invalid;

        return self.add(.{ .repeat = .{ .inner = inner, .min = min, .max = max, .greedy = greedy } });

    }

    /// Reads `{n}`, `{n,}`, or `{n,m}` at the cursor, leaving it on the closing brace; null, moving nothing, when it is none.
    fn count(self: *Parser) ?struct { u16, ?u16 } {

        const rest = self.pattern[self.index..];
        const close = std.mem.indexOfScalar(u8, rest, '}') orelse return null;
        const inside = rest[1..close];
        const comma = std.mem.indexOfScalar(u8, inside, ',');
        const low = std.fmt.parseInt(u16, inside[0 .. comma orelse inside.len], 10) catch return null;
        var high: ?u16 = low;

        if (comma) |split| {

            high = if (split + 1 == inside.len) null else std.fmt.parseInt(u16, inside[split + 1 ..], 10) catch return null;

        }

        if (high != null and high.? < low) return null;

        self.index += close + 1;

        return .{ low, high };

    }

    fn add(self: *Parser, node: @FieldType(Tree, "node")) Error!u16 {

        if (self.trees.items.len >= none) return error.Complex;

        try self.trees.append(self.allocator, .{

            .node = node,

        });

        return @intCast(self.trees.items.len - 1);

    }

    fn peek(self: *const Parser) u8 {

        return if (self.index < self.pattern.len) self.pattern[self.index] else 0;

    }

    /// The next character of the pattern, a whole UTF-8 sequence.
    fn take(self: *Parser) u21 {

        const char, const width = decode(self.pattern, self.index);

        self.index += width;

        return char orelse 0;

    }

};

const Builder = struct {

    allocator: Allocator,
    trees: []const Tree,
    fold: bool,
    program: std.ArrayList(Op) = .empty,

    fn push(self: *Builder, op: Op) Error!void {

        if (self.program.items.len >= most) return error.Complex;

        try self.program.append(self.allocator, op);

    }

    fn here(self: *const Builder) u16 {

        return @intCast(self.program.items.len);

    }

    fn emit(self: *Builder, index: u16) Error!void {

        switch (self.trees[index].node) {

            .empty => {},
            .char => |char| try self.push(.{ .char = if (self.fold) lower(char) else char }),
            .any => try self.push(.any),
            .class => |class| try self.push(.{ .class = class }),
            .start => try self.push(.start),
            .finish => try self.push(.finish),
            .boundary => |wanted| try self.push(.{ .boundary = wanted }),
            .group => |group| {

                if (group.slot) |slot| try self.push(.{ .save = 2 * slot });
                try self.emit(group.inner);
                if (group.slot) |slot| try self.push(.{ .save = 2 * slot + 1 });

            },
            .sequence => |first| {

                var piece = first;

                while (piece != none) : (piece = self.trees[piece].next) try self.emit(piece);

            },
            .choice => |first| {

                // Each branch but the last splits off the rest; their jumps to the end chain through their targets until patched.
                var branch = first;
                var chain: u16 = none;

                while (branch != none) : (branch = self.trees[branch].next) {

                    if (self.trees[branch].next == none) {

                        try self.emit(branch);
                        break;

                    }

                    const split = self.here();

                    try self.push(.{ .split = .{ split + 1, none } });
                    try self.emit(branch);
                    try self.push(.{ .jump = chain });
                    chain = self.here() - 1;
                    self.program.items[split].split[1] = self.here();

                }

                self.patch(chain, null);

            },
            .repeat => |repeat| {

                for (0..repeat.min) |_| try self.emit(repeat.inner);

                // The way on into the body comes first when greedy, and the way past it when lazy.
                const into: u1 = if (repeat.greedy) 0 else 1;

                if (repeat.max) |max| {

                    var chain: u16 = none;

                    for (repeat.min..max) |_| {

                        var targets: [2]u16 = undefined;

                        targets[into] = self.here() + 1;
                        targets[1 - into] = chain;
                        chain = self.here();
                        try self.push(.{ .split = targets });
                        try self.emit(repeat.inner);

                    }

                    self.patch(chain, 1 - into);

                } else {

                    const loop = self.here();
                    var targets: [2]u16 = undefined;

                    targets[into] = loop + 1;
                    targets[1 - into] = none;
                    try self.push(.{ .split = targets });
                    try self.emit(repeat.inner);
                    try self.push(.{ .jump = loop });
                    self.program.items[loop].split[1 - into] = self.here();

                }

            },

        }

    }

    /// Points every jump, or split way `way`, along `chain` at the next instruction.
    fn patch(self: *Builder, chain: u16, way: ?u1) void {

        var link = chain;
        const target = self.here();

        while (link != none) {

            const op = &self.program.items[link];

            if (way) |side| {

                link = op.split[side];
                op.split[side] = target;

            } else {

                link = op.jump;
                op.jump = target;

            }

        }

    }

};
