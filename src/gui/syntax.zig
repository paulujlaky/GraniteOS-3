//! Syntax colours: splits a line of code or Markdown into spans by kind, carrying whatever runs on, such as a block comment,
//! from one line to the next, so a view need only work out the lines it shows and those above them.

const std = @import("std");

const theme = @import("theme.zig");

pub const Kind = enum(u8) {

    plain,
    keyword,
    types,
    constant,
    number,
    string,
    comment,
    function,
    builtin,
    punctuation,

    heading,
    strong,
    emphasis,
    code,
    link,
    quote,
    marker,

};

/// What a line leaves open for the next.
pub const State = enum(u8) {

    normal,
    comment,
    double,
    single,
    backtick,
    triple_double,
    triple_single,

    /// Inside a fenced block of Markdown code.
    fence,

};

/// One run of a line in one kind, ending at `end`; each starts where the one before ends.
pub const Span = struct {

    end: usize,
    kind: Kind,

};

pub const Words = std.StaticStringMap(Kind);

pub const Language = struct {

    name: []const u8,

    /// File extensions, and the names a Markdown code fence may give, all lowercase.
    names: []const []const u8,

    words: Words = .initComptime(.{}),

    /// Coloured at all; plain text stays in one colour.
    coloured: bool = true,

    line_comment: []const u8 = "",
    block_comment: ?[2][]const u8 = null,

    /// Characters that open strings; those also in `runs` carry on past the end of a line.
    quotes: []const u8 = "\"'",
    runs: []const u8 = "",

    /// Python's triple-quoted strings.
    triple: bool = false,

    /// A character starting builtins, such as Zig's `@import` or a shell's `$HOME`.
    sigil: u8 = 0,

    /// Lines of Zig's multiline strings start with two backslashes.
    backslashes: bool = false,

    /// `'a` is a Rust lifetime rather than an unclosed character.
    lifetimes: bool = false,

    /// Capitalised names are types, as in Zig, Rust, and JavaScript.
    capitals: bool = false,

    /// Names such as `u8` and `i32` are integer types.
    integers: bool = false,

    /// `name!` is a Rust macro.
    macros: bool = false,

    /// Comments start only at the start of a word, as `#` does in a shell.
    detached: bool = false,

    /// A hash first on a line starts a preprocessor directive.
    preprocessor: bool = false,

    /// Strings followed by a colon are keys, as in JSON.
    keys: bool = false,

    /// Brackets open blocks: typing one closes it, and Enter indents inside it.
    brackets: bool = true,

    /// A colon ending a line opens a block, as in Python.
    colon: bool = false,

    markdown: bool = false,

};

pub const plain = Language{

    .name = "Plain text",
    .names = &.{ "txt", "text", "log" },
    .coloured = false,
    .quotes = "",
    .brackets = false,

};

pub const markdown = Language{

    .name = "Markdown",
    .names = &.{ "md", "markdown" },
    .quotes = "",
    .brackets = false,
    .markdown = true,

};

pub const zig = Language{

    .name = "Zig",
    .names = &.{ "zig", "zon" },
    .words = .initComptime(.{

        .{ "addrspace", .keyword }, .{ "align", .keyword }, .{ "allowzero", .keyword }, .{ "and", .keyword },
        .{ "anyframe", .keyword }, .{ "anytype", .keyword }, .{ "asm", .keyword }, .{ "break", .keyword },
        .{ "callconv", .keyword }, .{ "catch", .keyword }, .{ "comptime", .keyword }, .{ "const", .keyword },
        .{ "continue", .keyword }, .{ "defer", .keyword }, .{ "else", .keyword }, .{ "enum", .keyword },
        .{ "errdefer", .keyword }, .{ "error", .keyword }, .{ "export", .keyword }, .{ "extern", .keyword },
        .{ "fn", .keyword }, .{ "for", .keyword }, .{ "if", .keyword }, .{ "inline", .keyword },
        .{ "linksection", .keyword }, .{ "noalias", .keyword }, .{ "noinline", .keyword }, .{ "nosuspend", .keyword },
        .{ "opaque", .keyword }, .{ "or", .keyword }, .{ "orelse", .keyword }, .{ "packed", .keyword },
        .{ "pub", .keyword }, .{ "resume", .keyword }, .{ "return", .keyword }, .{ "struct", .keyword },
        .{ "suspend", .keyword }, .{ "switch", .keyword }, .{ "test", .keyword }, .{ "threadlocal", .keyword },
        .{ "try", .keyword }, .{ "union", .keyword }, .{ "unreachable", .keyword }, .{ "usingnamespace", .keyword },
        .{ "var", .keyword }, .{ "volatile", .keyword }, .{ "while", .keyword }, .{ "anyerror", .types },
        .{ "anyopaque", .types }, .{ "bool", .types }, .{ "comptime_float", .types }, .{ "comptime_int", .types },
        .{ "f16", .types }, .{ "f32", .types }, .{ "f64", .types }, .{ "f80", .types },
        .{ "f128", .types }, .{ "isize", .types }, .{ "noreturn", .types }, .{ "type", .types },
        .{ "usize", .types }, .{ "void", .types }, .{ "c_int", .types }, .{ "c_uint", .types },
        .{ "c_long", .types }, .{ "c_char", .types }, .{ "false", .constant }, .{ "null", .constant },
        .{ "true", .constant }, .{ "undefined", .constant },

    }),
    .line_comment = "//",
    .sigil = '@',
    .backslashes = true,
    .capitals = true,
    .integers = true,

};

pub const c = Language{

    .name = "C",
    .names = &.{ "c", "h", "cpp", "hpp", "cc", "cxx", "hh", "c++" },
    .words = .initComptime(.{

        .{ "auto", .keyword }, .{ "break", .keyword }, .{ "case", .keyword }, .{ "class", .keyword },
        .{ "const", .keyword }, .{ "constexpr", .keyword }, .{ "continue", .keyword }, .{ "default", .keyword },
        .{ "delete", .keyword }, .{ "do", .keyword }, .{ "else", .keyword }, .{ "enum", .keyword },
        .{ "extern", .keyword }, .{ "for", .keyword }, .{ "goto", .keyword }, .{ "if", .keyword },
        .{ "inline", .keyword }, .{ "namespace", .keyword }, .{ "new", .keyword }, .{ "private", .keyword },
        .{ "protected", .keyword }, .{ "public", .keyword }, .{ "register", .keyword }, .{ "return", .keyword },
        .{ "sizeof", .keyword }, .{ "static", .keyword }, .{ "struct", .keyword }, .{ "switch", .keyword },
        .{ "template", .keyword }, .{ "typedef", .keyword }, .{ "typename", .keyword }, .{ "union", .keyword },
        .{ "using", .keyword }, .{ "virtual", .keyword }, .{ "volatile", .keyword }, .{ "while", .keyword },
        .{ "bool", .types }, .{ "char", .types }, .{ "double", .types }, .{ "float", .types },
        .{ "int", .types }, .{ "long", .types }, .{ "short", .types }, .{ "signed", .types },
        .{ "size_t", .types }, .{ "unsigned", .types }, .{ "void", .types }, .{ "int8_t", .types },
        .{ "int16_t", .types }, .{ "int32_t", .types }, .{ "int64_t", .types }, .{ "uint8_t", .types },
        .{ "uint16_t", .types }, .{ "uint32_t", .types }, .{ "uint64_t", .types }, .{ "false", .constant },
        .{ "true", .constant }, .{ "NULL", .constant }, .{ "nullptr", .constant },

    }),
    .line_comment = "//",
    .block_comment = .{ "/*", "*/" },
    .preprocessor = true,

};

pub const python = Language{

    .name = "Python",
    .names = &.{ "py", "pyw", "python" },
    .words = .initComptime(.{

        .{ "and", .keyword }, .{ "as", .keyword }, .{ "assert", .keyword }, .{ "async", .keyword },
        .{ "await", .keyword }, .{ "break", .keyword }, .{ "class", .keyword }, .{ "continue", .keyword },
        .{ "def", .keyword }, .{ "del", .keyword }, .{ "elif", .keyword }, .{ "else", .keyword },
        .{ "except", .keyword }, .{ "finally", .keyword }, .{ "for", .keyword }, .{ "from", .keyword },
        .{ "global", .keyword }, .{ "if", .keyword }, .{ "import", .keyword }, .{ "in", .keyword },
        .{ "is", .keyword }, .{ "lambda", .keyword }, .{ "match", .keyword }, .{ "nonlocal", .keyword },
        .{ "not", .keyword }, .{ "or", .keyword }, .{ "pass", .keyword }, .{ "raise", .keyword },
        .{ "return", .keyword }, .{ "try", .keyword }, .{ "while", .keyword }, .{ "with", .keyword },
        .{ "yield", .keyword }, .{ "self", .builtin }, .{ "False", .constant }, .{ "None", .constant },
        .{ "True", .constant }, .{ "bool", .types }, .{ "bytes", .types }, .{ "dict", .types },
        .{ "float", .types }, .{ "int", .types }, .{ "list", .types }, .{ "set", .types },
        .{ "str", .types }, .{ "tuple", .types },

    }),
    .line_comment = "#",
    .triple = true,
    .sigil = '@',
    .colon = true,

};

pub const shell = Language{

    .name = "Shell",
    .names = &.{ "sh", "bash", "zsh", "shell" },
    .words = .initComptime(.{

        .{ "case", .keyword }, .{ "do", .keyword }, .{ "done", .keyword }, .{ "elif", .keyword },
        .{ "else", .keyword }, .{ "esac", .keyword }, .{ "export", .keyword }, .{ "fi", .keyword },
        .{ "for", .keyword }, .{ "function", .keyword }, .{ "if", .keyword }, .{ "in", .keyword },
        .{ "local", .keyword }, .{ "return", .keyword }, .{ "then", .keyword }, .{ "until", .keyword },
        .{ "while", .keyword }, .{ "cd", .function }, .{ "echo", .function }, .{ "exit", .function },
        .{ "printf", .function }, .{ "read", .function }, .{ "set", .function }, .{ "shift", .function },

    }),
    .line_comment = "#",
    .runs = "\"'",
    .sigil = '$',
    .detached = true,

};

pub const javascript = Language{

    .name = "JavaScript",
    .names = &.{ "js", "mjs", "cjs", "jsx", "ts", "tsx", "javascript", "typescript" },
    .words = .initComptime(.{

        .{ "async", .keyword }, .{ "await", .keyword }, .{ "break", .keyword }, .{ "case", .keyword },
        .{ "catch", .keyword }, .{ "class", .keyword }, .{ "const", .keyword }, .{ "continue", .keyword },
        .{ "default", .keyword }, .{ "delete", .keyword }, .{ "do", .keyword }, .{ "else", .keyword },
        .{ "export", .keyword }, .{ "extends", .keyword }, .{ "finally", .keyword }, .{ "for", .keyword },
        .{ "from", .keyword }, .{ "function", .keyword }, .{ "if", .keyword }, .{ "import", .keyword },
        .{ "in", .keyword }, .{ "instanceof", .keyword }, .{ "interface", .keyword }, .{ "let", .keyword },
        .{ "new", .keyword }, .{ "of", .keyword }, .{ "return", .keyword }, .{ "static", .keyword },
        .{ "switch", .keyword }, .{ "throw", .keyword }, .{ "try", .keyword }, .{ "type", .keyword },
        .{ "typeof", .keyword }, .{ "var", .keyword }, .{ "void", .keyword }, .{ "while", .keyword },
        .{ "yield", .keyword }, .{ "false", .constant }, .{ "null", .constant }, .{ "true", .constant },
        .{ "undefined", .constant }, .{ "NaN", .constant }, .{ "this", .builtin }, .{ "super", .builtin },

    }),
    .line_comment = "//",
    .block_comment = .{ "/*", "*/" },
    .quotes = "\"'`",
    .runs = "`",
    .capitals = true,

};

pub const json = Language{

    .name = "JSON",
    .names = &.{ "json", "jsonc" },
    .words = .initComptime(.{

        .{ "false", .constant }, .{ "null", .constant }, .{ "true", .constant },

    }),
    .quotes = "\"",
    .keys = true,

};

pub const rust = Language{

    .name = "Rust",
    .names = &.{ "rs", "rust" },
    .words = .initComptime(.{

        .{ "as", .keyword }, .{ "async", .keyword }, .{ "await", .keyword }, .{ "break", .keyword },
        .{ "const", .keyword }, .{ "continue", .keyword }, .{ "crate", .keyword }, .{ "dyn", .keyword },
        .{ "else", .keyword }, .{ "enum", .keyword }, .{ "extern", .keyword }, .{ "fn", .keyword },
        .{ "for", .keyword }, .{ "if", .keyword }, .{ "impl", .keyword }, .{ "in", .keyword },
        .{ "let", .keyword }, .{ "loop", .keyword }, .{ "match", .keyword }, .{ "mod", .keyword },
        .{ "move", .keyword }, .{ "mut", .keyword }, .{ "pub", .keyword }, .{ "ref", .keyword },
        .{ "return", .keyword }, .{ "static", .keyword }, .{ "struct", .keyword }, .{ "trait", .keyword },
        .{ "type", .keyword }, .{ "unsafe", .keyword }, .{ "use", .keyword }, .{ "where", .keyword },
        .{ "while", .keyword }, .{ "self", .builtin }, .{ "Self", .types }, .{ "bool", .types },
        .{ "char", .types }, .{ "f32", .types }, .{ "f64", .types }, .{ "isize", .types },
        .{ "str", .types }, .{ "usize", .types }, .{ "false", .constant }, .{ "true", .constant },

    }),
    .line_comment = "//",
    .block_comment = .{ "/*", "*/" },
    .quotes = "\"'",
    .lifetimes = true,
    .capitals = true,
    .integers = true,
    .macros = true,

};

pub const go = Language{

    .name = "Go",
    .names = &.{ "go", "golang" },
    .words = .initComptime(.{

        .{ "break", .keyword }, .{ "case", .keyword }, .{ "chan", .keyword }, .{ "const", .keyword },
        .{ "continue", .keyword }, .{ "default", .keyword }, .{ "defer", .keyword }, .{ "else", .keyword },
        .{ "fallthrough", .keyword }, .{ "for", .keyword }, .{ "func", .keyword }, .{ "go", .keyword },
        .{ "goto", .keyword }, .{ "if", .keyword }, .{ "import", .keyword }, .{ "interface", .keyword },
        .{ "map", .keyword }, .{ "package", .keyword }, .{ "range", .keyword }, .{ "return", .keyword },
        .{ "select", .keyword }, .{ "struct", .keyword }, .{ "switch", .keyword }, .{ "type", .keyword },
        .{ "var", .keyword }, .{ "bool", .types }, .{ "byte", .types }, .{ "error", .types },
        .{ "float64", .types }, .{ "int", .types }, .{ "int64", .types }, .{ "rune", .types },
        .{ "string", .types }, .{ "uint", .types }, .{ "uint8", .types }, .{ "false", .constant },
        .{ "iota", .constant }, .{ "nil", .constant }, .{ "true", .constant },

    }),
    .line_comment = "//",
    .block_comment = .{ "/*", "*/" },
    .quotes = "\"'`",
    .runs = "`",

};

/// Every language, in the order people pick from.
pub const languages = [_]*const Language{ &plain, &markdown, &c, &go, &javascript, &json, &python, &rust, &shell, &zig };

/// The language a file named `name` is written in, by its extension or, failing that, a `#!` first line.
pub fn detect(name: []const u8, first: []const u8) *const Language {

    const base = std.fs.path.basenamePosix(name);

    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| if (find(base[dot + 1 ..])) |language| return language;

    if (std.mem.startsWith(u8, first, "#!")) {

        if (std.mem.indexOf(u8, first, "python") != null) return &python;
        if (std.mem.indexOf(u8, first, "node") != null) return &javascript;
        if (std.mem.indexOf(u8, first, "sh") != null) return &shell;

    }

    return &plain;

}

/// The language going by `label`, an extension or the name on a Markdown code fence, ignoring case.
pub fn find(label: []const u8) ?*const Language {

    for (languages) |language| {

        for (language.names) |known| if (std.ascii.eqlIgnoreCase(known, label)) return language;
        if (std.ascii.eqlIgnoreCase(language.name, label)) return language;

    }

    return null;

}

pub fn color(kind: Kind) u32 {

    return switch (kind) {

        .plain => theme.text,
        .keyword, .emphasis => theme.syntax.keyword,
        .types, .marker => theme.syntax.types,
        .constant, .number => theme.syntax.number,
        .string, .code => theme.syntax.string,
        .comment => theme.syntax.comment,
        .function, .heading, .link => theme.syntax.function,
        .builtin, .strong => theme.syntax.builtin,
        .punctuation => theme.syntax.punctuation,
        .quote => theme.muted,

    };

}

/// Gathers spans into `out`, joining neighbours of a kind; once it is full the last span runs on to cover the rest.
const Spans = struct {

    out: []Span,
    count: usize = 0,

    fn add(self: *Spans, end: usize, kind: Kind) void {

        if (self.out.len == 0) return;

        if (self.count != 0) {

            const last = &self.out[self.count - 1];

            if (end <= last.end) return;

            if (last.kind == kind or self.count == self.out.len) {

                last.end = end;
                return;

            }

        }

        self.out[self.count] = .{

            .end = end,
            .kind = kind,

        };

        self.count += 1;

    }

};

/// Splits `line` into spans in `out`, starting in `state`; returns how many it filled and the state it leaves for the next line.
/// An empty `out` only works out that state.
pub fn split(language: *const Language, line: []const u8, state: State, out: []Span) struct { usize, State } {

    var spans = Spans{

        .out = out,

    };

    const next = if (!language.coloured) .normal else if (language.markdown) prose(line, state, &spans) else code(language, line, state, &spans);

    spans.add(line.len, .plain);

    return .{ spans.count, next };

}

fn code(language: *const Language, line: []const u8, state: State, spans: *Spans) State {

    var index: usize = 0;

    switch (state) {

        .comment => {

            const close = language.block_comment.?[1];
            const at = std.mem.indexOf(u8, line, close) orelse return finish(spans, line, .comment, .comment);

            index = at + close.len;
            spans.add(index, .comment);

        },
        .double, .single, .backtick => {

            index = closing(line, 0, quote(state)) orelse return finish(spans, line, .string, state);
            spans.add(index, .string);

        },
        .triple_double, .triple_single => {

            const close = if (state == .triple_double) "\"\"\"" else "'''";
            const at = std.mem.indexOf(u8, line, close) orelse return finish(spans, line, .string, state);

            index = at + 3;
            spans.add(index, .string);

        },
        .normal, .fence => {},

    }

    while (index < line.len) {

        const char = line[index];
        const rest = line[index..];

        if (language.line_comment.len != 0 and std.mem.startsWith(u8, rest, language.line_comment) and (!language.detached or index == 0 or blank(line[index - 1]))) {

            return finish(spans, line, .comment, .normal);

        }

        if (language.block_comment) |marks| if (std.mem.startsWith(u8, rest, marks[0])) {

            const at = std.mem.indexOfPos(u8, line, index + marks[0].len, marks[1]) orelse return finish(spans, line, .comment, .comment);

            index = at + marks[1].len;
            spans.add(index, .comment);
            continue;

        };

        if (language.backslashes and std.mem.startsWith(u8, rest, "\\\\")) return finish(spans, line, .string, .normal);

        if (language.preprocessor and char == '#' and std.mem.trim(u8, line[0..index], " \t").len == 0) {

            index += 1;
            while (index < line.len and blank(line[index])) index += 1;
            while (index < line.len and identifier(line[index])) index += 1;
            spans.add(index, .builtin);
            continue;

        }

        if (language.triple and (std.mem.startsWith(u8, rest, "\"\"\"") or std.mem.startsWith(u8, rest, "'''"))) {

            const at = std.mem.indexOfPos(u8, line, index + 3, rest[0..3]) orelse return finish(spans, line, .string, if (char == '"') .triple_double else .triple_single);

            index = at + 3;
            spans.add(index, .string);
            continue;

        }

        if (std.mem.indexOfScalar(u8, language.quotes, char) != null) {

            if (language.lifetimes and char == '\'' and lifetime(line, index)) {

                index += 1;
                while (index < line.len and identifier(line[index])) index += 1;
                spans.add(index, .types);
                continue;

            }

            const end = closing(line, index + 1, char) orelse {

                const runs = std.mem.indexOfScalar(u8, language.runs, char) != null;

                return finish(spans, line, .string, if (runs) opened(char) else .normal);

            };

            index = end;
            spans.add(index, if (language.keys and following(line, index) == ':') .types else .string);
            continue;

        }

        if (std.ascii.isDigit(char) and (index == 0 or !identifier(line[index - 1]))) {

            index += 1;

            while (index < line.len) : (index += 1) {

                const digit = line[index];
                const exponent = (digit == '+' or digit == '-') and (line[index - 1] | 0x20 == 'e' or line[index - 1] | 0x20 == 'p') and !std.mem.startsWith(u8, rest, "0x");

                if (!(identifier(digit) or exponent or (digit == '.' and index + 1 < line.len and std.ascii.isDigit(line[index + 1])))) break;

            }

            spans.add(index, .number);
            continue;

        }

        if (identifier(char) or (language.sigil != 0 and char == language.sigil)) {

            const start = index;

            index += 1;

            if (char == language.sigil and char == '$' and index < line.len and line[index] == '{') {

                index = if (std.mem.indexOfScalarPos(u8, line, index, '}')) |close| close + 1 else line.len;

            } else if (char == language.sigil and char == '$' and index < line.len and std.mem.indexOfScalar(u8, "?#@*!$0123456789", line[index]) != null) {

                index += 1;

            } else {

                while (index < line.len and identifier(line[index])) index += 1;

            }

            spans.add(index, classify(language, line, start, index));
            continue;

        }

        if (blank(char)) {

            while (index < line.len and blank(line[index])) index += 1;
            spans.add(index, .plain);
            continue;

        }

        index += 1;
        spans.add(index, if (std.ascii.isPrint(char)) .punctuation else .plain);

    }

    return .normal;

}

/// The kind of the word from `start` to `end` of `line`, by what it is and what follows it.
fn classify(language: *const Language, line: []const u8, start: usize, end: usize) Kind {

    const word = line[start..end];

    if (language.sigil != 0 and word[0] == language.sigil) return .builtin;
    if (language.words.get(word)) |kind| return kind;
    if (language.macros and end < line.len and line[end] == '!' and (end + 1 == line.len or line[end + 1] != '=')) return .builtin;

    if (language.integers and word.len > 1 and (word[0] == 'u' or word[0] == 'i')) {

        for (word[1..]) |digit| {

            if (!std.ascii.isDigit(digit)) break;

        } else return .types;

    }

    if (language.capitals and std.ascii.isUpper(word[0])) {

        for (word[1..]) |letter| if (std.ascii.isLower(letter)) return .types;

    }

    return if (following(line, end) == '(') .function else .plain;

}

/// Markdown, line by line: fences, headings, quotes, rules, and list markers, then inline styles.
fn prose(line: []const u8, state: State, spans: *Spans) State {

    const indent = std.mem.indexOfNone(u8, line, " ") orelse line.len;
    const rest = line[indent..];

    if (state == .fence) return finish(spans, line, if (fence(rest)) .marker else .code, if (fence(rest)) .normal else .fence);
    if (indent < 4 and fence(rest)) return finish(spans, line, .marker, .fence);
    if (indent < 4 and heading(rest) != 0) return finish(spans, line, .heading, .normal);
    if (indent < 4 and rest.len != 0 and rest[0] == '>') return finish(spans, line, .quote, .normal);
    if (indent < 4 and rule(rest)) return finish(spans, line, .marker, .normal);

    var index = indent;

    if (bullet(rest)) |width| {

        index += width;
        spans.add(index, .marker);

    }

    while (index < line.len) {

        const char = line[index];

        if (char == '\\' and index + 1 < line.len) {

            index += 2;
            spans.add(index, .plain);
            continue;

        }

        const found: struct { ?usize, Kind } = switch (char) {

            '`' => .{ pair(line, index, line[index .. index + run(line, index, '`')]), .code },
            '*', '_' => blk: {

                const width = @min(run(line, index, char), 2);
                const intraword = char == '_' and index > 0 and std.ascii.isAlphanumeric(line[index - 1]);

                break :blk .{ if (intraword) null else pair(line, index, line[index..][0..width]), if (width == 2) .strong else .emphasis };

            },
            '[', '!' => .{ link(line, index), .link },
            else => .{ null, .plain },

        };

        const end, const kind = found;

        index = end orelse index + 1;
        spans.add(index, if (end == null) .plain else kind);

    }

    return .normal;

}

/// Where the run opened by `delimiter` at `index` of `line` closes, just past the closer; null when it never does.
fn pair(line: []const u8, index: usize, delimiter: []const u8) ?usize {

    var at = index + delimiter.len;

    while (std.mem.indexOfPos(u8, line, at, delimiter)) |close| {

        // A closer hugs the text before it, and ends a run of exactly the opener's length.
        if (close > index + delimiter.len and !blank(line[close - 1]) and run(line, close, delimiter[0]) == delimiter.len) return close + delimiter.len;
        at = close + run(line, close, delimiter[0]);

    }

    return null;

}

/// Where `[text](target)` or `![text](target)` at `index` of `line` ends; null when it is not one.
fn link(line: []const u8, index: usize) ?usize {

    const open = if (line[index] == '!') index + 1 else index;

    if (open >= line.len or line[open] != '[') return null;

    const close = std.mem.indexOfScalarPos(u8, line, open, ']') orelse return null;

    if (close + 1 >= line.len or line[close + 1] != '(') return null;

    const end = std.mem.indexOfScalarPos(u8, line, close, ')') orelse return null;

    return end + 1;

}

/// How many `char` in a row start at `index` of `line`.
fn run(line: []const u8, index: usize, char: u8) usize {

    var end = index;

    while (end < line.len and line[end] == char) end += 1;

    return end - index;

}

/// A fence of three or more backticks or tildes, opening or closing a block of Markdown code.
pub fn fence(line: []const u8) bool {

    return line.len >= 3 and (line[0] == '`' or line[0] == '~') and run(line, 0, line[0]) >= 3;

}

/// The level of a Markdown heading, `#` to `######` then a space; zero when `line` is none.
pub fn heading(line: []const u8) usize {

    const level = run(line, 0, '#');

    return if (level >= 1 and level <= 6 and (level == line.len or blank(line[level]))) level else 0;

}

/// A thematic break: three or more of one of `-`, `*`, or `_`, spaces allowed between.
pub fn rule(line: []const u8) bool {

    if (line.len == 0 or std.mem.indexOfScalar(u8, "-*_", line[0]) == null) return false;

    var count: usize = 0;

    for (line) |char| {

        if (char == line[0]) count += 1 else if (!blank(char)) return false;

    }

    return count >= 3;

}

/// How wide a list marker such as `- `, `* `, or `12. ` starting `line` is, with the space after it; null when there is none.
pub fn bullet(line: []const u8) ?usize {

    if (line.len >= 2 and std.mem.indexOfScalar(u8, "-*+", line[0]) != null and blank(line[1])) return 2;
    if (line.len == 1 and std.mem.indexOfScalar(u8, "-*+", line[0]) != null) return 1;

    const digits = std.mem.indexOfNone(u8, line, "0123456789") orelse return null;

    if (digits == 0 or digits > 9 or (line[digits] != '.' and line[digits] != ')')) return null;
    if (digits + 1 < line.len and !blank(line[digits + 1])) return null;

    return @min(digits + 2, line.len);

}

/// Fills the rest of `line` with `kind` and returns `state` for the next line.
fn finish(spans: *Spans, line: []const u8, kind: Kind, state: State) State {

    spans.add(line.len, kind);

    return state;

}

/// Just past the `close` quote ending a string that runs from `from`, skipping backslash escapes; null if the line ends first.
fn closing(line: []const u8, from: usize, close: u8) ?usize {

    var index = from;

    while (index < line.len) : (index += 1) {

        if (line[index] == '\\') {

            index += 1;
            continue;

        }

        if (line[index] == close) return index + 1;

    }

    return null;

}

/// Whether the quote at `index` starts a Rust lifetime such as `'a`, rather than a character such as `'a'`.
fn lifetime(line: []const u8, index: usize) bool {

    if (index + 1 >= line.len or !identifier(line[index + 1])) return false;

    return index + 2 >= line.len or line[index + 2] != '\'';

}

fn quote(state: State) u8 {

    return switch (state) {

        .single => '\'',
        .backtick => '`',
        else => '"',

    };

}

fn opened(char: u8) State {

    return switch (char) {

        '\'' => .single,
        '`' => .backtick,
        else => .double,

    };

}

/// The first character after `index` of `line` that is not a space, or zero.
fn following(line: []const u8, index: usize) u8 {

    const at = std.mem.indexOfNonePos(u8, line, index, " \t") orelse return 0;

    return line[at];

}

fn identifier(char: u8) bool {

    return std.ascii.isAlphanumeric(char) or char == '_' or char >= 0x80;

}

fn blank(char: u8) bool {

    return char == ' ' or char == '\t';

}
