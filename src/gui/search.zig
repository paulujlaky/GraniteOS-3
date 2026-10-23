//! Finding text by a plain or regular-expression pattern, matching case and whole words or not, and filling in replacements.

const std = @import("std");

const regex = @import("regex.zig");
const text = @import("text.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {

    /// Letters match only in the same case.
    case: bool = false,

    /// Matches must not run on into letters or digits either side.
    word: bool = false,

    /// The pattern is a regular expression; see `regex.zig`.
    regex: bool = false,

};

pub const Match = struct {

    start: usize,
    end: usize,

};

/// Patterns longer than this are cut short.
const longest = 256;

pub const Finder = struct {

    allocator: Allocator,
    bytes: [longest]u8 = undefined,
    length: usize = 0,
    options: Options = .{},
    compiled: ?regex.Regex = null,

    pub fn init(allocator: Allocator) Finder {

        return .{

            .allocator = allocator,

        };

    }

    pub fn deinit(self: *Finder) void {

        if (self.compiled) |*expression| expression.deinit();
        self.compiled = null;

    }

    /// Searches for `wanted` from now on; an expression that does not parse finds nothing, and says why.
    pub fn set(self: *Finder, wanted: []const u8, options: Options) regex.Error!void {

        self.deinit();
        self.length = @min(wanted.len, longest);
        @memcpy(self.bytes[0..self.length], wanted[0..self.length]);
        self.options = options;

        if (!options.regex or self.length == 0) return;

        self.compiled = regex.Regex.compile(self.allocator, self.pattern(), !options.case) catch |err| {

            self.length = 0;
            return err;

        };

    }

    pub fn pattern(self: *const Finder) []const u8 {

        return self.bytes[0..self.length];

    }

    /// Whether there is nothing to look for.
    pub fn idle(self: *const Finder) bool {

        return self.length == 0;

    }

    /// The first match starting at or after `from` in `haystack`.
    pub fn next(self: *Finder, haystack: []const u8, from: usize) ?Match {

        var position = from;

        while (position <= haystack.len) {

            const found = self.raw(haystack, position) orelse return null;

            if (!self.options.word or whole(haystack, found)) return found;
            position = if (found.start < haystack.len) text.after(haystack, found.start) else haystack.len + 1;

        }

        return null;

    }

    /// The last match starting before `before`, looking back a widening stretch of lines at a time.
    pub fn previous(self: *Finder, haystack: []const u8, before: usize) ?Match {

        var reach: usize = 4096;

        while (true) : (reach *= 4) {

            const from = if (std.mem.lastIndexOfScalar(u8, haystack[0 .. before -| reach], '\n')) |newline| newline + 1 else 0;
            var position = from;
            var last: ?Match = null;

            while (self.next(haystack, position)) |found| {

                if (found.start >= before) break;

                last = found;
                position = past(haystack, found);

            }

            if (last != null or from == 0) return last;

        }

    }

    /// How many matches `haystack` holds, counting no further than `limit`.
    pub fn count(self: *Finder, haystack: []const u8, limit: usize) usize {

        var total: usize = 0;
        var position: usize = 0;

        while (total < limit) : (total += 1) {

            const found = self.next(haystack, position) orelse break;

            position = past(haystack, found);

        }

        return total;

    }

    /// Appends what replaces `found` to `out`: `replacement` itself, or for an expression with `$1` to `$9` and `$&` filled in
    /// from the match's groups, `$$` a dollar sign, and `\n` and `\t` a newline and a tab.
    pub fn expand(self: *Finder, haystack: []const u8, found: Match, replacement: []const u8, out: *std.ArrayList(u8), allocator: Allocator) Allocator.Error!void {

        const expression = if (self.compiled) |*compiled| compiled else return out.appendSlice(allocator, replacement);
        const captures = expression.find(haystack, found.start) orelse return out.appendSlice(allocator, replacement);
        var index: usize = 0;

        while (index < replacement.len) : (index += 1) {

            const char = replacement[index];
            const following = if (index + 1 < replacement.len) replacement[index + 1] else 0;

            if (char == '$' and (std.ascii.isDigit(following) or following == '&')) {

                const group: usize = if (following == '&') 0 else following - '0';

                if (captures[2 * group] != regex.unset and captures[2 * group + 1] != regex.unset) {

                    try out.appendSlice(allocator, haystack[captures[2 * group]..captures[2 * group + 1]]);

                }

                index += 1;

            } else if ((char == '$' and following == '$') or (char == '\\' and following == '\\')) {

                try out.append(allocator, char);
                index += 1;

            } else if (char == '\\' and (following == 'n' or following == 't')) {

                try out.append(allocator, if (following == 'n') '\n' else '\t');
                index += 1;

            } else {

                try out.append(allocator, char);

            }

        }

    }

    fn raw(self: *Finder, haystack: []const u8, from: usize) ?Match {

        if (self.length == 0 or from > haystack.len) return null;

        if (self.compiled) |*expression| {

            const captures = expression.find(haystack, from) orelse return null;

            return .{

                .start = captures[0],
                .end = captures[1],

            };

        }

        const needle = self.pattern();
        const start = (if (self.options.case) std.mem.indexOfPos(u8, haystack, from, needle) else std.ascii.indexOfIgnoreCasePos(haystack, from, needle)) orelse return null;

        return .{

            .start = start,
            .end = start + needle.len,

        };

    }

};

/// Where to look after `found`: its end, or past the next character when it matched nothing.
pub fn past(haystack: []const u8, found: Match) usize {

    if (found.end > found.start) return found.end;

    return if (found.end < haystack.len) text.after(haystack, found.end) else haystack.len + 1;

}

fn whole(haystack: []const u8, found: Match) bool {

    const open = found.start == 0 or !text.wordy(haystack[found.start - 1]);
    const close = found.end == haystack.len or !text.wordy(haystack[found.end]);

    return open and close;

}
