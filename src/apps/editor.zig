//! Editor: text, code, and Markdown in tabs, opened from and saved to files. Code shows in syntax colours beside line numbers,
//! Markdown beside a live preview, and a find bar searches and replaces by plain text or regular expression.

const std = @import("std");

const catalog = @import("catalog.zig");

const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;
const syntax = gui.syntax;
pub const panic = api.panic;

const control = api.Event.Modifiers{

    .control = true,

};

const control_shift = api.Event.Modifiers{

    .shift = true,
    .control = true,

};

/// Files open at once, at most.
const most = 12;

/// Text sizes the slider runs between, in pixels at 100%.
const smallest: f32 = 10;
const largest: f32 = 24;

/// Matches counted for the find bar, at most.
const counted = 10000;

const View = enum {

    source,
    split,
    preview,

};

/// One open file, and its place in the strip of tabs.
const Tab = struct {

    code: gui.Code,

    path_bytes: [512]u8 = undefined,
    path_length: usize = 0,

    /// The text's revision when last opened or saved, to tell unsaved changes.
    saved: u64 = 0,

    /// How Markdown shows: its source, the source beside its preview, or the preview alone.
    view: View = .source,

    title_bytes: [160]u8 = undefined,
    icon: gui.Node = undefined,
    label: gui.Node = undefined,
    cross: gui.Node = undefined,
    parts: [3]*gui.Node = undefined,
    node: gui.Node = undefined,

    fn path(self: *const Tab) []const u8 {

        return self.path_bytes[0..self.path_length];

    }

    fn name(self: *const Tab) []const u8 {

        return if (self.path_length == 0) "Untitled" else std.fs.path.basenamePosix(self.path());

    }

    fn modified(self: *const Tab) bool {

        return self.code.document.revision() != self.saved;

    }

    /// Nothing typed and no file: a tab a file can open into instead of a new one.
    fn blank(self: *const Tab) bool {

        return self.path_length == 0 and self.code.document.length() == 0 and !self.modified();

    }

};

var window: gui.Window = undefined;
var files = api.Files{};
var dialog = gui.Dialog{};
var finder: gui.Finder = undefined;
var preview: gui.Preview = undefined;

var tabs: [most]Tab = undefined;
var count: usize = 0;
var current: usize = 0;

/// The tab a dialog asks about closing.
var pending: usize = 0;

var folder_bytes: [512]u8 = undefined;
var folder: []const u8 = "/";

var text_size: f32 = 14;

var create = gui.tool(.new, &startNew);
var load = gui.tool(.folder_open, &askOpen);
var keep = gui.tool(.save, &save);
var first_divider = gui.box(theme.divider, &.{});
var undo_tool = gui.tool(.undo, &undoTool);
var redo_tool = gui.tool(.redo, &redoTool);
var second_divider = gui.box(theme.divider, &.{});
var search_tool = gui.tool(.search, &findTool);
var third_divider = gui.box(theme.divider, &.{});

var bold_tool = gui.tool(.bold, &embolden);
var italic_tool = gui.tool(.italic, &slant);
var heading_tool = gui.tool(.heading, &headline);
var list_tool = gui.tool(.list, &bullets);
var numbered_tool = gui.tool(.list_ordered, &numbers);
var quote_tool = gui.tool(.quote, &quotes);
var link_tool = gui.tool(.link, &hyperlink);
var fourth_divider = gui.box(theme.divider, &.{});
var eye_tool = gui.tool(.eye, &showPreview);
var columns_tool = gui.tool(.columns, &showSplit);

var markdown_parts = [_]*gui.Node{ &bold_tool, &italic_tool, &heading_tool, &list_tool, &numbered_tool, &quote_tool, &link_tool, &fourth_divider, &eye_tool, &columns_tool };

var markdown_tools = gui.box(.{

    .direction = .row,
    .gap = theme.gap / 2,
    .items = .center,

}, &markdown_parts);

var spring = gui.box(theme.spring, &.{});
var wrap_tool = gui.tool(.wrap, &toggleWrap);
var keep_as = gui.button("Save as", &askSave);

var tools = [_]*gui.Node{ &create, &load, &keep, &first_divider, &undo_tool, &redo_tool, &second_divider, &search_tool, &third_divider, &markdown_tools, &spring, &wrap_tool, &keep_as };
var toolbar = gui.box(theme.bar, &tools);

var strip_list: [most]*gui.Node = undefined;

var strip = gui.box(.{

    .height = 36,
    .padding = .axes(3, theme.gap),

    .direction = .row,
    .gap = 4,
    .items = .center,
    .scroll = true,

    .background = theme.pane,

}, &.{});

const tab_style = theme.item.with(.{

    .height = 30,
    .padding = gui.Edges{ .left = 10, .right = 4 },
    .gap = 6,

});

const small_tool = theme.tool.with(.{

    .width = 22,
    .height = 22,
    .size = 12,

});

var find_bytes: [256]u8 = undefined;

var find_text = gui.Text{

    .buffer = &find_bytes,
    .placeholder = "Find",

};

var find_field = gui.input(&find_text);
var case_tool = gui.tool(.case, &toggleCase);
var word_tool = gui.tool(.word, &toggleWord);
var regex_tool = gui.tool(.regex, &toggleRegex);
var matches = gui.label("", theme.caption);
var previous_tool = gui.tool(.up, &findPrevious);
var next_tool = gui.tool(.down, &findNext);
var swap_tool = gui.tool(.replace, &toggleReplace);
var hide_tool = gui.tool(.close, &hideFind);
var find_parts = [_]*gui.Node{ &find_field, &case_tool, &word_tool, &regex_tool, &matches, &previous_tool, &next_tool, &swap_tool, &hide_tool };

var find_row = gui.box(.{

    .direction = .row,
    .gap = theme.gap / 2,
    .items = .center,

}, &find_parts);

var replace_bytes: [256]u8 = undefined;

var replace_text = gui.Text{

    .buffer = &replace_bytes,
    .placeholder = "Replace with",

};

var replace_field = gui.input(&replace_text);
var replace_one = gui.button("Replace", &replaceOne);
var replace_every = gui.button("Replace all", &replaceEvery);
var replace_parts = [_]*gui.Node{ &replace_field, &replace_one, &replace_every };

var replace_row = gui.box(.{

    .direction = .row,
    .gap = theme.gap / 2,
    .items = .center,

}, &replace_parts);

var bar_parts = [_]*gui.Node{ &find_row, &replace_row };

var bar = gui.box(.{

    .padding = .axes(6, theme.gap),
    .gap = 6,

    .background = theme.pane,

}, &bar_parts);

var view: gui.Node = undefined;
var split = gui.box(theme.divider.with(.{ .height = null }), &.{});
var shown: gui.Node = undefined;
var body_parts = [_]*gui.Node{ &view, &split, &shown };

var body = gui.box(.{

    .grow = 1,
    .direction = .row,

}, &body_parts);

var position_bytes: [80]u8 = undefined;

var position = gui.label("", theme.caption.with(.{

    .padding = gui.Edges{ .right = theme.spacing },

}));

var notice = gui.label("", theme.caption);
var status_spring = gui.box(theme.spring, &.{});
var language_icon = gui.icon(.file_code, theme.icon.with(.{ .size = 13, .color = theme.muted }));
var language_label = gui.label("", theme.caption);
var language_parts = [_]*gui.Node{ &language_icon, &language_label };

var language_button = gui.box(theme.item.with(.{

    .height = 22,
    .padding = gui.Edges.axes(0, 6),
    .gap = 4,

}), &language_parts);

var indent_bytes: [24]u8 = undefined;
var indent_label = gui.label("", theme.caption);
var sizer = gui.Slider{ .changed = &resize };
var sizer_node: gui.Node = undefined;
var size_bytes: [16]u8 = undefined;
var size_label = gui.label("", theme.caption);
var status_parts = [_]*gui.Node{ &position, &notice, &status_spring, &language_button, &indent_label, &sizer_node, &size_label };

var status = gui.box(.{

    .height = 28,

    .padding = .axes(0, theme.spacing),
    .gap = theme.gap,

    .direction = .row,
    .items = .center,

    .background = theme.pane,

}, &status_parts);

var parts = [_]*gui.Node{ &toolbar, &strip, &bar, &body, &status };
var root = gui.box(.{}, &parts);

var edit_menu: gui.Menu(&.{

    .{ .icon = .undo, .title = "Undo", .hint = "Ctrl+Z", .run = undo },
    .{ .icon = .redo, .title = "Redo", .hint = "Ctrl+Y", .run = redo },
    gui.menu.separator,
    .{ .icon = .cut, .title = "Cut", .hint = "Ctrl+X", .run = cut },
    .{ .icon = .copy, .title = "Copy", .hint = "Ctrl+C", .run = copySelection },
    .{ .icon = .paste, .title = "Paste", .hint = "Ctrl+V", .run = paste },
    gui.menu.separator,
    .{ .title = "Select all", .hint = "Ctrl+A", .run = selectAll },
    .{ .icon = .search, .title = "Find", .hint = "Ctrl+F", .run = find },
    .{ .icon = .replace, .title = "Replace", .hint = "Ctrl+H", .run = replace },

}) = .{};

const language_choices = blk: {

    var choices: [syntax.languages.len]gui.Choice = undefined;

    for (syntax.languages, &choices, 0..) |language, *choice, index| choice.* = .{

        .title = language.name,
        .run = speaker(index),

    };

    break :blk choices;

};

var language_menu: gui.Menu(&language_choices) = .{};

/// What the find bar searches for: the field's text, by its version, and how.
const Search = struct {

    version: u64,
    options: gui.search.Options,

};

var searched: ?Search = null;
var options = gui.search.Options{};

/// Bumped by each new search, so the count knows to start again.
var generation: u64 = 0;
var matches_bytes: [48]u8 = undefined;

var tallied: struct {

    generation: u64 = std.math.maxInt(u64),
    version: u64 = 0,
    tab: usize = 0,
    anchor: usize = 0,
    caret: usize = 0,

} = .{};

/// What the window last showed, so `update` does nothing when nothing changed.
const Shown = struct {

    current: usize,
    count: usize,
    version: u64,
    revision: u64,
    caret: usize,
    anchor: usize,
    language: *const syntax.Language,
    top: usize,

};

var last: ?Shown = null;
var title_bytes: [96]u8 = undefined;

/// The text's version when the notice was given, and the notice, kept since callers build it on their stacks.
var told: u64 = 0;
var notice_bytes: [96]u8 = undefined;

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .application);
    dialog.init();

    finder = gui.Finder.init(api.pages);
    preview = gui.Preview.init(api.pages);
    build();

    var argument_bytes: [256]u8 = undefined;
    const argument = api.argument(&argument_bytes);

    folder = copy(&folder_bytes, catalog.home(argument) orelse "/");

    window = gui.Window.open(&root, .{

        .title = "Editor",
        .application = .editor,

        .width = 900,
        .height = 600,

        .capacity = 1024 * 1024,

    }) catch api.exit(3);

    edit_menu.init(&window);
    language_menu.init(&window);

    _ = add();
    select(0);
    rescale();

    if (argument.len != 0 and !std.mem.eql(u8, argument, folder)) open(argument);

    update();

    while (true) {

        const event = window.next(500) orelse {

            update();
            continue;

        };

        if (event.kind == .close) leave();
        react(event);
        update();

    }

}

/// Styles what the declarations above cannot.
fn build() void {

    view = tabs[0].code.node(.{

        .grow = 1,
        .padding = .axes(6, 0),
        .background = theme.background,

    });

    view.menu = &offerEdit;

    shown = preview.node(.{

        .grow = 1,
        .background = theme.background,

    });

    sizer_node = sizer.node(.{

        .width = 90,

    });

    find_field.style = find_field.style.with(.{

        .grow = 1,
        .height = 30,

    });

    replace_field.style = find_field.style;
    replace_one.style = replace_one.style.with(.{ .height = 30 });
    replace_every.style = replace_every.style.with(.{ .height = 30 });
    keep_as.style = keep_as.style.with(.{ .height = 30 });
    find_field.action = &findNext;
    replace_field.action = &replaceOne;
    language_button.action = &offerLanguage;
    bar.hidden = true;
    replace_row.hidden = true;

    for ([_]*gui.Node{ &case_tool, &word_tool, &regex_tool, &previous_tool, &next_tool, &swap_tool, &hide_tool }) |tool| {

        tool.style = tool.style.with(.{ .width = 28, .height = 28 });

    }

    sizer.value = (text_size - smallest) / (largest - smallest);

}

fn react(event: api.Event) void {

    if (event.kind != .key or !event.pressed) return;

    if (event.chord(control, 's')) return save(&keep);
    if (event.chord(control_shift, 's')) return askSave(&keep_as);
    if (event.chord(control, 'o')) return askOpen(&load);
    if (event.chord(control, 'n')) return startNew(&create);
    if (event.chord(control, 'w')) return dismiss(current);
    if (event.chord(control, 'f')) return find();
    if (event.chord(control, 'h')) return replace();
    if (event.chord(control, 'g')) return askLine();
    if (event.chord(control, '=')) return zoom(1);
    if (event.chord(control, '-')) return zoom(-1);
    if (event.chord(control, '0')) return zoom(0);
    if (event.chord(.{ .alt = true }, 'z')) return toggleWrap(&wrap_tool);

    if (active().code.language.markdown) {

        if (event.chord(control, 'b')) return embolden(&bold_tool);
        if (event.chord(control, 'i')) return slant(&italic_tool);
        if (event.chord(control, 'k')) return hyperlink(&link_tool);

    }

    if (event.pressing(.tab) and event.modifiers.control) {

        const step = if (event.modifiers.shift) count - 1 else 1;

        return select((current + step) % count);

    }

    if (event.pressing(.f3)) return if (event.modifiers.shift) findPrevious(&previous_tool) else findNext(&next_tool);

    if (event.pressing(.escape)) {

        if (dialog.open()) {

            dialog.close();
            window.focus(&view);

        } else if (!bar.hidden) {

            hideFind(&hide_tool);

        }

        return;

    }

    if (window.focused == &view and active().code.key(event)) window.invalidate(&view);

}

/// Keeps the title, tabs, status, find count, and preview current with the text.
fn update() void {

    const tab = active();
    const code = &tab.code;

    if (!bar.hidden) {

        const now = Search{ .version = find_text.version, .options = options };

        if (searched == null or !std.meta.eql(searched.?, now)) research();

        tally();

    }

    const state = Shown{

        .current = current,
        .count = count,
        .version = code.document.version,
        .revision = code.document.revision(),
        .caret = code.caret,
        .anchor = code.anchor,
        .language = code.language,
        .top = code.top.line,

    };

    if (last != null and std.meta.eql(last.?, state)) return;

    // A notice such as "Saved." lasts until the text changes.
    if (told != code.document.version) notice.content.label = "";

    const moved = last == null or last.?.top != state.top or last.?.current != current;

    last = state;

    if (tab.view == .split and moved) preview.follow(code.top.line);

    const heading = std.fmt.bufPrint(&title_bytes, "{s}{s} - Editor", .{ if (tab.modified()) "* " else "", tab.name() }) catch "Editor";

    if (!std.mem.eql(u8, heading, window.surface.spec.name())) window.retitle(heading);

    for (tabs[0..count]) |*each| each.label.content.label = caption(each);

    const line, const column = code.position();
    const range = code.selection();

    position.content.label = if (range.empty())
        std.fmt.bufPrint(&position_bytes, "Line {d}, column {d}", .{ line, column }) catch ""
    else
        std.fmt.bufPrint(&position_bytes, "Line {d}, column {d} ({d} selected)", .{ line, column, range.end() - range.start() }) catch "";

    language_label.content.label = code.language.name;
    language_icon.content.label = symbol(tab).text();
    indent_label.content.label = if (code.indent.tabs) "Tabs" else std.fmt.bufPrint(&indent_bytes, "Spaces: {d}", .{code.indent.width}) catch "";
    window.refresh();

}

/// Counts the matches and which one is selected, when the text, the search, or the selection changed since last time.
fn tally() void {

    const code = &active().code;

    if (tallied.generation == generation and tallied.version == code.document.version and tallied.tab == current and tallied.anchor == code.anchor and tallied.caret == code.caret) return;

    tallied = .{ .generation = generation, .version = code.document.version, .tab = current, .anchor = code.anchor, .caret = code.caret };

    const all = code.bytes();
    const range = code.selection();
    var at: usize = 0;
    var total: usize = 0;
    var which: ?usize = null;

    if (!finder.idle()) while (total < counted) {

        const match = finder.next(all, at) orelse break;

        total += 1;
        if (match.start == range.start() and match.end == range.end()) which = total;
        at = gui.search.past(all, match);

    };

    matches.content.label = if (finder.idle())
        ""
    else if (total == 0)
        "No matches"
    else if (total == counted)
        std.fmt.bufPrint(&matches_bytes, "{d}+ matches", .{counted}) catch ""
    else if (which) |index|
        std.fmt.bufPrint(&matches_bytes, "{d} of {d}", .{ index, total }) catch ""
    else
        std.fmt.bufPrint(&matches_bytes, "{d} matches", .{total}) catch "";

    window.refresh();

}

fn caption(tab: *Tab) []const u8 {

    return std.fmt.bufPrint(&tab.title_bytes, "{s}{s}", .{ if (tab.modified()) "\u{2022} " else "", tab.name() }) catch tab.name();

}

fn symbol(tab: *const Tab) gui.Icon {

    if (tab.code.language.markdown) return .document;

    return if (tab.code.language == &syntax.plain) .file else .file_code;

}

fn active() *Tab {

    return &tabs[current];

}

/// Opens a new, empty tab; null when there is no room for another.
fn add() ?*Tab {

    if (count == most) {

        say("Close a tab to open another.");
        return null;

    }

    tabs[count] = .{

        .code = gui.Code.init(api.pages),

    };

    const tab = &tabs[count];

    tab.code.size = text_size;
    tab.code.wrap = true;
    tab.code.finder = if (bar.hidden) null else &finder;
    count += 1;
    wire();

    return tab;

}

/// Links every tab's nodes to each other and to the strip, after tabs come, go, or move.
fn wire() void {

    for (tabs[0..count], 0..) |*tab, index| {

        tab.icon = gui.icon(symbol(tab), theme.icon.with(.{ .size = 14 }));
        tab.label = gui.label(caption(tab), theme.caption.with(.{ .color = theme.text }));
        tab.cross = gui.tool(.close, &shut);
        tab.cross.style = small_tool;
        tab.cross.data = index;
        tab.parts = .{ &tab.icon, &tab.label, &tab.cross };
        tab.node = gui.box(tab_style, &tab.parts);
        tab.node.action = &pick;
        tab.node.data = index;
        tab.node.selected = index == current;
        strip_list[index] = &tab.node;

    }

    strip.content.box = strip_list[0..count];
    last = null;
    window.refresh();

}

/// Shows tab `index`.
fn select(index: usize) void {

    current = @min(index, count - 1);

    for (tabs[0..count], 0..) |*tab, place| tab.node.selected = place == current;

    view.data = @intFromPtr(&active().code);
    preview.show(&active().code.document);
    arrange();

    if (!view.hidden) window.focus(&view);
    if (window.root.reveal(&active().node)) window.refresh();

}

/// Shows the editor, preview, and tools the current tab calls for.
fn arrange() void {

    const tab = active();
    const markdown = tab.code.language.markdown;
    const mode = if (markdown) tab.view else .source;

    view.hidden = mode == .preview;
    shown.hidden = mode == .source;
    split.hidden = mode != .split;
    markdown_tools.hidden = !markdown;
    eye_tool.selected = mode == .preview;
    columns_tool.selected = mode == .split;
    wrap_tool.selected = tab.code.wrap;
    search_tool.selected = !bar.hidden;
    tab.icon.content.label = symbol(tab).text();

    if (mode == .split) preview.follow(tab.code.top.line);

    last = null;
    window.refresh();

}

fn pick(node: *gui.Node) void {

    select(node.data);

}

fn shut(node: *gui.Node) void {

    dismiss(node.data);

}

/// Closes tab `index`, asking first when it has unsaved changes.
fn dismiss(index: usize) void {

    if (!tabs[index].modified()) return remove(index);

    var detail: [200]u8 = undefined;

    pending = index;
    dialog.check(&window, "Close without saving?", std.fmt.bufPrint(&detail, "Changes to {s} will be lost.", .{tabs[index].name()}) catch "", "Close", &discard);

}

fn discard(_: []const u8) void {

    remove(pending);

}

fn remove(index: usize) void {

    tabs[index].code.deinit();

    for (index..count - 1) |place| tabs[place] = tabs[place + 1];

    count -= 1;

    if (count == 0) _ = add() else wire();
    if (current > index or current == count) current -|= 1;

    select(current);

}

/// Quits, asking first when any tab has unsaved changes.
fn leave() void {

    var unsaved: usize = 0;

    for (tabs[0..count]) |*tab| unsaved += @intFromBool(tab.modified());

    if (unsaved == 0) window.quit();

    var detail: [96]u8 = undefined;
    const words = if (unsaved == 1) "A file has unsaved changes." else std.fmt.bufPrint(&detail, "{d} files have unsaved changes.", .{unsaved}) catch "";

    dialog.check(&window, "Quit without saving?", words, "Quit", &quit);

}

fn quit(_: []const u8) void {

    window.quit();

}

fn open(target: []const u8) void {

    for (tabs[0..count], 0..) |*tab, index| {

        if (std.mem.eql(u8, tab.path(), target)) return select(index);

    }

    const bytes = files.load(api.pages, target) catch |err| return report(err);
    const reuse = active().blank();

    if (!reuse and add() == null) return api.pages.free(bytes);

    const index = if (reuse) current else count - 1;
    const tab = &tabs[index];

    tab.code.load(bytes, target) catch return say("There is not enough memory to open that file.");
    tab.saved = tab.code.document.revision();
    tab.code.wrap = tab.code.language.markdown or tab.code.language == &syntax.plain;
    tab.view = if (tab.code.language.markdown) .split else .source;
    rename(tab, target);
    select(index);
    say("");

}

/// Gives `tab` the path `target`, and the folder it is in to the next dialog.
fn rename(tab: *Tab, target: []const u8) void {

    tab.path_length = copy(&tab.path_bytes, target).len;
    folder = copy(&folder_bytes, std.fs.path.dirnamePosix(target) orelse "/");
    wire();

}

fn startNew(_: *gui.Node) void {

    _ = add() orelse return;
    select(count - 1);
    say("");

}

fn askOpen(_: *gui.Node) void {

    var initial: [520]u8 = undefined;

    dialog.ask(&window, "Open", std.fmt.bufPrint(&initial, "{s}/", .{folder}) catch folder, "Open", &openPath);

}

fn openPath(target: []const u8) void {

    var kept: [512]u8 = undefined;

    open(copy(&kept, target));

}

fn save(_: *gui.Node) void {

    const tab = active();

    if (tab.path_length == 0) return askSave(&keep_as);

    var kept: [512]u8 = undefined;

    write(copy(&kept, tab.path()));

}

fn askSave(_: *gui.Node) void {

    var initial: [600]u8 = undefined;
    const tab = active();
    const extension = if (tab.code.language.markdown) "md" else if (tab.code.language == &syntax.plain) "txt" else tab.code.language.names[0];
    const suggestion = if (tab.path_length != 0) tab.path() else std.fmt.bufPrint(&initial, "{s}/Untitled.{s}", .{ folder, extension }) catch folder;

    dialog.ask(&window, "Save as", suggestion, "Save", &saveAs);

}

fn saveAs(target: []const u8) void {

    var kept: [512]u8 = undefined;

    write(copy(&kept, target));

}

fn write(target: []const u8) void {

    var scratch = std.heap.ArenaAllocator.init(api.pages);

    defer scratch.deinit();

    const tab = active();

    files.save(scratch.allocator(), target, tab.code.bytes()) catch |err| return report(err);

    tab.code.document.seal();
    tab.saved = tab.code.document.revision();

    // A new file's name says what it holds.
    if (tab.code.language == &syntax.plain) {

        tab.code.speak(syntax.detect(target, tab.code.document.content(0)));
        if (tab.code.language.markdown) tab.view = .split;

    }

    rename(tab, target);
    arrange();
    say("Saved.");
    window.focus(&view);

}

fn report(err: api.ServiceError) void {

    say(switch (err) {

        error.Missing => "That file or folder does not exist.",
        error.Denied => "Permission denied.",
        error.Full => "The volume is full.",
        error.Invalid => "That isn't a file that can be opened here.",
        error.Exhausted => "There is not enough memory for that file.",
        else => "The file service is unavailable.",

    });

}

fn say(message: []const u8) void {

    notice.content.label = copy(&notice_bytes, message);
    told = active().code.document.version;
    last = null;
    window.refresh();

}

fn copy(out: []u8, value: []const u8) []const u8 {

    const length = @min(value.len, out.len);

    std.mem.copyForwards(u8, out[0..length], value[0..length]);

    return out[0..length];

}

/// Runs an edit on the current tab's text and repaints, saying so if memory ran out.
fn edit(result: gui.code.Error!void) void {

    result catch say("There is not enough memory for that change.");
    window.invalidate(&view);
    last = null;

}

fn undo() void {

    _ = active().code.undo() catch say("There is not enough memory to undo that.");
    window.invalidate(&view);

}

fn redo() void {

    _ = active().code.redo() catch say("There is not enough memory to redo that.");
    window.invalidate(&view);

}

fn undoTool(_: *gui.Node) void {

    undo();
    window.focus(&view);

}

fn redoTool(_: *gui.Node) void {

    redo();
    window.focus(&view);

}

fn cut() void {

    _ = active().code.cut() catch say("There is not enough memory for that change.");
    window.invalidate(&view);

}

fn copySelection() void {

    _ = active().code.copy();

}

fn paste() void {

    _ = active().code.paste() catch say("There is not enough memory to paste that.");
    window.invalidate(&view);

}

fn selectAll() void {

    const code = &active().code;

    code.select(0, code.document.length());
    window.invalidate(&view);

}

fn offerEdit(_: *gui.Node, at: gui.Point) void {

    edit_menu.show(at);

}

fn offerLanguage(node: *gui.Node) void {

    language_menu.show(.{ .x = node.rect.x, .y = node.rect.y - language_menu.root.measure().height });

}

fn speaker(comptime index: usize) *const fn () void {

    return struct {

        fn run() void {

            speak(syntax.languages[index]);

        }

    }.run;

}

fn speak(language: *const syntax.Language) void {

    const tab = active();

    tab.code.speak(language);
    if (language.markdown and tab.view == .source) tab.view = .split;
    wire();
    arrange();

}

fn toggleWrap(_: *gui.Node) void {

    const code = &active().code;

    code.wrap = !code.wrap;
    code.top.row = 0;
    code.left = 0;
    arrange();

}

fn showPreview(_: *gui.Node) void {

    const tab = active();

    tab.view = if (tab.view == .preview) .source else .preview;
    arrange();
    if (!view.hidden) window.focus(&view);

}

fn showSplit(_: *gui.Node) void {

    const tab = active();

    tab.view = if (tab.view == .split) .source else .split;
    arrange();
    window.focus(&view);

}

fn resize(slider: *gui.Slider, _: bool) void {

    text_size = @round(smallest + slider.value * (largest - smallest));
    rescale();

}

/// Grows the text a pixel (`step` 1), shrinks it (-1), or puts it back to its usual size (0).
fn zoom(step: i8) void {

    text_size = if (step == 0) 14 else std.math.clamp(text_size + @as(f32, @floatFromInt(step)), smallest, largest);
    sizer.value = (text_size - smallest) / (largest - smallest);
    rescale();

}

fn rescale() void {

    for (tabs[0..count]) |*tab| tab.code.size = text_size;

    preview.size = text_size + 1;
    size_label.content.label = std.fmt.bufPrint(&size_bytes, "{d} px", .{@as(u32, @intFromFloat(text_size))}) catch "";
    window.refresh();

}

fn askLine() void {

    dialog.ask(&window, "Go to line", "", "Go", &goLine);

}

fn goLine(answer: []const u8) void {

    const code = &active().code;
    const line = std.fmt.parseInt(usize, std.mem.trim(u8, answer, " "), 10) catch return dialog.refuse("Type a line number.");
    const start = code.document.start(std.math.clamp(line, 1, code.document.count()) - 1);

    code.select(start, start);
    code.middle();
    window.focus(&view);

}

fn find() void {

    showFind(false);

}

fn replace() void {

    showFind(true);

}

fn findTool(_: *gui.Node) void {

    if (bar.hidden) showFind(false) else hideFind(&hide_tool);

}

/// Opens the find bar, with the replace row when `replacing`, seeded with the selection if it is one line.
fn showFind(replacing: bool) void {

    const selected = active().code.selected();

    if (selected.len != 0 and selected.len <= find_bytes.len and std.mem.indexOfScalar(u8, selected, '\n') == null) find_text.set(selected);

    find_text.all();
    bar.hidden = false;
    replace_row.hidden = !replacing and replace_row.hidden;
    swap_tool.selected = !replace_row.hidden;

    for (tabs[0..count]) |*tab| tab.code.finder = &finder;

    searched = null;
    window.focus(&find_field);
    arrange();

}

fn hideFind(_: *gui.Node) void {

    bar.hidden = true;

    for (tabs[0..count]) |*tab| tab.code.finder = null;

    arrange();
    window.focus(&view);

}

fn toggleReplace(_: *gui.Node) void {

    replace_row.hidden = !replace_row.hidden;
    swap_tool.selected = !replace_row.hidden;
    window.focus(if (replace_row.hidden) &find_field else &replace_field);
    window.refresh();

}

fn toggleCase(node: *gui.Node) void {

    options.case = !options.case;
    node.selected = options.case;

}

fn toggleWord(node: *gui.Node) void {

    options.word = !options.word;
    node.selected = options.word;

}

fn toggleRegex(node: *gui.Node) void {

    options.regex = !options.regex;
    node.selected = options.regex;

}

/// Searches afresh for what the find field holds, selecting the first match from the selection on, as a search grows.
fn research() void {

    const code = &active().code;

    searched = .{ .version = find_text.version, .options = options };
    generation += 1;
    find_field.invalid = false;

    finder.set(find_text.text(), options) catch {

        find_field.invalid = true;
        window.invalidate(&find_field);
        return;

    };

    if (!finder.idle()) _ = code.seek(&finder, true, code.selection().start());
    window.invalidate(&view);

}

fn findNext(_: *gui.Node) void {

    const code = &active().code;

    if (bar.hidden) return find();
    if (!code.seek(&finder, true, code.selection().end())) say("No matches.");
    window.invalidate(&view);

}

fn findPrevious(_: *gui.Node) void {

    const code = &active().code;

    if (bar.hidden) return find();
    if (!code.seek(&finder, false, code.selection().start())) say("No matches.");
    window.invalidate(&view);

}

fn replaceOne(_: *gui.Node) void {

    if (finder.idle()) return;

    _ = active().code.substitute(&finder, replace_text.text()) catch say("There is not enough memory for that change.");
    window.invalidate(&view);

}

fn replaceEvery(_: *gui.Node) void {

    if (finder.idle()) return;

    var words: [48]u8 = undefined;
    const replaced = active().code.substituteAll(&finder, replace_text.text()) catch return say("There is not enough memory for that change.");

    say(if (replaced == 1) "Replaced 1 match." else std.fmt.bufPrint(&words, "Replaced {d} matches.", .{replaced}) catch "");
    window.invalidate(&view);

}

fn embolden(_: *gui.Node) void {

    edit(active().code.surround("**", "**"));
    window.focus(&view);

}

fn slant(_: *gui.Node) void {

    edit(active().code.surround("*", "*"));
    window.focus(&view);

}

fn hyperlink(_: *gui.Node) void {

    const code = &active().code;
    const named = !code.selection().empty();
    const target = "https://";

    edit(code.surround("[", "](" ++ target ++ ")"));

    // With text to show, the address is what is left to type.
    if (named) {

        const end = code.selection().end() + 2;

        code.select(end, end + target.len);

    }

    window.focus(&view);

}

fn quotes(_: *gui.Node) void {

    edit(active().code.toggle("> "));
    window.focus(&view);

}

fn bullets(_: *gui.Node) void {

    edit(active().code.toggle("- "));
    window.focus(&view);

}

/// Turns the selected lines into a numbered list, or back into plain lines if they all are one.
fn numbers(_: *gui.Node) void {

    const code = &active().code;
    const range = code.lines();
    var every = true;

    for (range.first..range.last + 1) |line| {

        const content = std.mem.trimLeft(u8, code.document.content(line), " ");

        if (content.len != 0 and numbered(content) == 0) every = false;

    }

    const Numbering = struct {

        fn change(clear: bool, line: []const u8, index: usize, scratch: []u8) gui.code.Splice {

            const indent = std.mem.indexOfNone(u8, line, " ") orelse return .{};
            const width = numbered(line[indent..]);

            if (clear) return .{ .at = indent, .remove = width };

            return .{

                .at = indent,
                .remove = width,
                .insert = std.fmt.bufPrint(scratch, "{d}. ", .{index + 1}) catch "",

            };

        }

    };

    edit(code.each(every, Numbering.change));
    window.focus(&view);

}

/// How wide a number marker such as `12. ` starting `line` is; zero when there is none.
fn numbered(line: []const u8) usize {

    const width = syntax.bullet(line) orelse return 0;

    return if (std.ascii.isDigit(line[0])) width else 0;

}

/// Steps the selected lines' heading level up, from none to three hashes, then back to none.
fn headline(_: *gui.Node) void {

    const Heading = struct {

        fn change(_: void, line: []const u8, _: usize, _: []u8) gui.code.Splice {

            const marks = [_][]const u8{ "# ", "## ", "### " };
            const level = syntax.heading(line);
            const width = if (level == 0) 0 else @min(level + 1, line.len);

            if (level >= marks.len) return .{ .remove = width };

            return .{

                .remove = width,
                .insert = marks[level],

            };

        }

    };

    edit(active().code.each({}, Heading.change));
    window.focus(&view);

}
