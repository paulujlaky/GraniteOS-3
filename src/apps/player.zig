//! Player: plays music and films from a queue, with seeking, volume, shuffle, and repeat; opening a file queues the others
//! in its folder around it.

const std = @import("std");

const catalog = @import("catalog.zig");

const api = @import("api");
const gui = @import("gui");
const media = @import("media");

const theme = gui.theme;
pub const panic = api.panic;

/// Entries the queue holds at most.
const most = 200;

/// The window onto a file that decoders read through, and the most one read asks the files service for, so the window
/// keeps answering while a large file streams in.
const window_bytes = 1024 * 1024;
const piece = 256 * 1024;

/// Seconds the arrow keys move through a track, and how far back Previous restarts it rather than going back.
const nudge = 5;
const restart = 3;

const Entry = struct {

    path: [256]u8 = undefined,
    length: u16 = 0,
    kind: media.Kind = .mp3,

    fn get(self: *const Entry) []const u8 {

        return self.path[0..self.length];

    }

    /// The file's name without its extension, as the queue lists it.
    fn name(self: *const Entry) []const u8 {

        const base = std.fs.path.basenamePosix(self.get());

        return base[0 .. std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len];

    }

};

var entries: [most]Entry = undefined;
var count: usize = 0;

/// The order entries play in, the queue's own or shuffled, and how far along it playback is.
var order: [most]u16 = undefined;
var place: usize = 0;

const Repeat = enum {

    off,
    all,
    one,

};

var repeat: Repeat = .off;
var shuffled = false;
var volume: u8 = 80;
var muted = false;

var prng = std.Random.DefaultPrng.init(0);

/// Reads the playing file for its decoder, straight into the decoder's window.
const Reader = struct {

    files: api.Files = .{},
    bytes: [256]u8 = undefined,
    length: usize = 0,

    fn path(self: *const Reader) []const u8 {

        return self.bytes[0..self.length];

    }

    fn read(context: *anyopaque, offset: u64, buffer: []u8) error{Unreadable}!usize {

        const self: *Reader = @ptrCast(@alignCast(context));
        const part = buffer[0..@min(buffer.len, piece)];

        if (part.len > self.length) return self.files.fetch(self.path(), @intCast(offset), part) catch error.Unreadable;

        // A sliver too short to carry the path goes through the file service's own window instead.
        const bytes = self.files.read(self.path(), @intCast(offset), part.len) catch return error.Unreadable;
        const taken = @min(bytes.len, part.len);

        @memcpy(part[0..taken], bytes[0..taken]);

        return taken;

    }

};

/// The track loaded and all that decodes and times it; it stays put while loaded, since the decoder points into it.
const Playback = struct {

    arena: std.heap.ArenaAllocator,
    reader: Reader,
    source: media.Source,
    track: media.Track,
    duration: ?f64,

    /// Where the track starts on its own clock, as a film's first sound may come a moment in; times show from here.
    start: f64 = 0,

    /// The seconds into the track where the speakers' count of frames stood at `mark`, or the clock at `ticks`, when it
    /// last started from somewhere new.
    origin: f64 = 0,
    mark: u64 = 0,
    ticks: u64 = 0,

    /// The decoder gave the last of its sound, or of its pictures.
    drained: bool = false,
    ended: bool = false,

    /// The next picture, held until it is due, and whether to show it at once, as after a seek.
    upcoming: ?*const media.Picture = null,
    fresh: bool = true,

};

var playback: Playback = undefined;
var loaded = false;
var playing = false;

/// The speakers' stream, kept from track to track while their formats match.
var stream: ?api.audio.Stream = null;
var samples: [8192]f32 = undefined;

/// The film's picture as shown, and the second the time labels last showed.
var frame: ?gui.Image = null;
var shown_second: i64 = -1;

var preferences = api.Config{};

var screen = gui.custom(&paint, .{

    .grow = 1,

});

var art = gui.icon(.music, theme.icon.with(.{

    .width = null,
    .size = 72,
    .color = theme.faint,
    .text_align = .center,

}));

var song = gui.label("", theme.title_text.with(.{

    .text_align = .center,

}));

var artist = gui.label("", theme.caption.with(.{

    .text_align = .center,

}));

var detail_bytes: [96]u8 = undefined;

var detail = gui.label("", theme.caption.with(.{

    .color = theme.faint,
    .text_align = .center,

}));

var cover_parts = [_]*gui.Node{ &art, &song, &artist, &detail };

var cover = gui.box(.{

    .grow = 1,
    .padding = gui.Edges.all(theme.spacing * 2),
    .gap = theme.gap,
    .justify = .center,
    .items = .stretch,

}, &cover_parts);

var message = gui.label("Open music or a video from Files to play it here.", theme.caption.with(.{

    .grow = 1,
    .text_align = .center,

}));

var stage_parts = [_]*gui.Node{ &screen, &cover, &message };

var stage = gui.box(.{

    .grow = 1,
    .direction = .stack,

    .background = 0x000000,

}, &stage_parts);

var heading = gui.label("Queue", theme.caption.with(.{

    .grow = 1,
    .padding = gui.Edges.axes(0, 6),

}));

var adding = gui.tool(.plus, &askAdd);
var clearing = gui.tool(.trash, &clearChosen);
var side_top_parts = [_]*gui.Node{ &heading, &adding, &clearing };

var side_top = gui.box(.{

    .height = theme.control,
    .direction = .row,
    .items = .center,

}, &side_top_parts);

var row_icons: [most]gui.Node = undefined;
var row_names: [most]gui.Node = undefined;
var row_parts: [most][2]*gui.Node = undefined;
var rows: [most]gui.Node = undefined;
var row_list: [most]*gui.Node = undefined;

var list = gui.box(.{

    .grow = 1,
    .gap = 2,
    .scroll = true,

}, &row_list);

var empty = gui.label("Nothing queued.", theme.caption.with(.{

    .height = 60,
    .text_align = .center,

}));

var side_parts = [_]*gui.Node{ &side_top, &empty, &list };

var side = gui.box(.{

    .width = 260,
    .padding = gui.Edges.all(theme.gap),
    .gap = 4,

    .background = theme.raised,

}, &side_parts);

var body_parts = [_]*gui.Node{ &stage, &side };

var body = gui.box(.{

    .grow = 1,
    .direction = .row,

}, &body_parts);

var elapsed_bytes: [16]u8 = undefined;
var total_bytes: [16]u8 = undefined;

var elapsed = gui.label("0:00", theme.caption.with(.{

    .width = 56,
    .text_align = .right,

}));

var position = gui.Slider{

    .changed = &seekMoved,

};

var seeker: gui.Node = undefined;

var total = gui.label("0:00", theme.caption.with(.{

    .width = 56,

}));

var timeline_parts = [_]*gui.Node{ &elapsed, &seeker, &total };

var timeline = gui.box(.{

    .height = 30,
    .padding = .axes(0, theme.gap),
    .direction = .row,
    .gap = theme.gap,
    .items = .center,

}, &timeline_parts);

var shuffle_tool = gui.tool(.shuffle, &shuffleChosen);
var back_tool = gui.tool(.skip_back, &backChosen);

var play_tool = gui.tool(.play, &playChosen);

var forward_tool = gui.tool(.skip_forward, &forwardChosen);
var repeat_tool = gui.tool(.repeat, &repeatChosen);
var spring = gui.box(theme.spring, &.{});
var loudness_tool = gui.tool(.volume_high, &muteChosen);

var loudness = gui.Slider{

    .value = 0.8,
    .changed = &volumeMoved,

};

var leveler: gui.Node = undefined;
var queue_tool = gui.tool(.playlist, &queueChosen);
var control_parts = [_]*gui.Node{ &shuffle_tool, &back_tool, &play_tool, &forward_tool, &repeat_tool, &spring, &loudness_tool, &leveler, &queue_tool };

var controls = gui.box(.{

    .height = 52,
    .padding = .axes(0, theme.gap),
    .direction = .row,
    .gap = 4,
    .items = .center,

}, &control_parts);

var rule = gui.box(theme.rule, &.{});
var parts = [_]*gui.Node{ &body, &rule, &timeline, &controls };

var root = gui.box(.{

    .background = theme.background,

}, &parts);

var window: gui.Window = undefined;
var dialog = gui.Dialog{};

var row_menu: gui.Menu(&.{

    .{ .icon = .play, .title = "Play", .hint = "Enter", .run = playPicked },
    .{ .icon = .close, .title = "Remove from queue", .hint = "Del", .run = removePicked },
    gui.menu.separator,
    .{ .icon = .trash, .title = "Clear queue", .run = clearPicked },

}) = .{};

/// The queue entry a row's menu acts on.
var picked: usize = 0;

var title_bytes: [128]u8 = undefined;

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .application);

    var argument_bytes: [256]u8 = undefined;
    const argument = api.argument(&argument_bytes);
    var seed: [8]u8 = undefined;

    api.random(&seed);
    prng = std.Random.DefaultPrng.init(std.mem.readInt(u64, &seed, .little));

    seeker = position.node(.{

        .grow = 1,

    });

    leveler = loudness.node(.{

        .width = 100,

    });

    play_tool.style = play_tool.style.with(.{

        .width = 40,
        .height = 40,
        .size = 18,
        .radius = 20,

        .background = theme.accent,
        .color = theme.background,

        .hover = .{

            .background = theme.text,

        },
        .focus = .{

            .background = theme.text,

        },
        .pressed = .{

            .background = theme.muted,

        },

    });

    for (&rows, 0..) |*row, index| {

        row_icons[index] = gui.icon(.music, theme.icon.with(.{

            .color = theme.muted,

        }));

        row_names[index] = gui.label("", .{

            .grow = 1,

        });

        row_parts[index] = .{ &row_icons[index], &row_names[index] };
        row.* = gui.box(theme.item.with(.{

            .height = 30,

        }), &row_parts[index]);

        row.action = &rowChosen;
        row.menu = &rowOffered;
        row.data = index;
        row_list[index] = row;

    }

    preferences.open(std.fs.path.basename(catalog.home(argument) orelse ""), "player");
    volume = @min(preferences.number(u8, "volume") orelse 80, 100);
    repeat = std.meta.stringToEnum(Repeat, preferences.get("repeat") orelse "") orelse .off;
    loudness.value = @as(f32, @floatFromInt(volume)) / 100;

    window = gui.Window.open(&root, .{

        .title = "Player",
        .application = .player,

        .width = 820,
        .height = 520,

    }) catch api.exit(3);

    dialog.init();
    row_menu.init(&window);
    window.react = &shortcut;

    if (argument.len != 0 and media.Kind.named(argument) != null) {

        queueFolder(argument);
        start(find(argument) orelse 0);

    }

    sync();

    while (true) {

        const event = window.next(if (!playing) 25 else if (frame != null) 1 else 4);

        if (event) |happened| {

            if (happened.kind == .close) quit();

        }

        tick();

    }

}

fn quit() noreturn {

    if (stream) |*open| open.close();

    window.quit();

}

/// Keys that work wherever the focus is, unless a node took them.
fn shortcut(_: *gui.Window, event: api.Event) bool {

    if (event.kind != .key or !event.pressed) return false;
    if (event.chord(.{ .control = true }, 'o')) return consume(askAdd, &adding);

    switch (event.key()) {

        .left => if (event.modifiers.control) backChosen(&back_tool) else jump(-nudge),
        .right => if (event.modifiers.control) forwardChosen(&forward_tool) else jump(nudge),
        .up => setVolume(volume +| 5, true),
        .down => setVolume(volume -| 5, true),
        .delete => if (window.focused) |node| if (isRow(node)) remove(order[node.data]) else return false else return false,
        .character => switch (event.char) {

            ' ', 'k' => playChosen(&play_tool),
            'n' => forwardChosen(&forward_tool),
            'p' => backChosen(&back_tool),
            'm' => muteChosen(&loudness_tool),
            's' => shuffleChosen(&shuffle_tool),
            'r' => repeatChosen(&repeat_tool),
            else => return false,

        },
        else => return false,

    }

    return true;

}

fn consume(comptime action: fn (*gui.Node) void, node: *gui.Node) bool {

    action(node);

    return true;

}

fn isRow(node: *const gui.Node) bool {

    return @intFromPtr(node) >= @intFromPtr(&rows[0]) and @intFromPtr(node) <= @intFromPtr(&rows[most - 1]);

}

/// Moves playback on: sound to the speakers, a picture when one falls due, and the next track once this one ends.
fn tick() void {

    if (!loaded) return;

    if (playing) {

        fill();
        present();

        if (finished()) advance(false);

    } else if (playback.fresh) {

        // Paused, a seek still shows the picture it landed on.
        present();

    }

    times(false);

}

/// Decodes sound into the stream's free room, a bounded amount at a time so the window stays responsive.
fn fill() void {

    const channels = playback.track.channels();

    if (channels == 0 or playback.drained) return;

    for (0..4) |_| {

        // Without speakers, sound is decoded only as fast as the clock runs, keeping a film's pictures moving.
        const room: usize = if (stream) |*open| open.room() else @intFromFloat(@max((clock() + 0.25 - decoded()) * @as(f64, @floatFromInt(playback.track.rate())), 0));

        if (room < 256) return;

        const frames = @min(room, samples.len / channels);
        const got = playback.track.read(samples[0 .. frames * channels]) catch |err| return fail(err);

        if (got == 0) {

            playback.drained = true;
            return;

        }

        if (stream) |*open| _ = open.write(f32, samples[0 .. got * channels]) else playback.mark += got;

    }

}

/// Seconds of sound decoded so far, when there are no speakers to count them.
fn decoded() f64 {

    return playback.origin + @as(f64, @floatFromInt(playback.mark)) / @as(f64, @floatFromInt(playback.track.rate()));

}

/// Shows the film's next picture once the clock reaches it, passing over any that came too late to matter.
fn present() void {

    const movie = film() orelse return;

    if (playback.ended) return;

    const now = clock();
    const interval = 1 / @max(movie.frameRate(), 1);

    while (true) {

        if (playback.upcoming == null) {

            playback.upcoming = movie.picture() catch |err| return fail(err);

            if (playback.upcoming == null) {

                playback.ended = true;
                return;

            }

        }

        const next = playback.upcoming.?;

        if (!playback.fresh and next.time > now) return;

        playback.upcoming = null;

        if (!playback.fresh and next.time + interval < now) continue;

        playback.fresh = false;
        show(next);

        return;

    }

}

fn show(picture: *const media.Picture) void {

    if (frame) |*old| if (old.width != picture.width or old.height != picture.height) {

        old.deinit();
        frame = null;

    };

    if (frame == null) {

        frame = gui.Image.init(picture.width, picture.height) catch return;
        sync();

    }

    const shown = &frame.?;

    picture.convert(shown.pixels());
    shown.change(null) catch {

    };

    window.invalidate(&screen);

}

/// Whether everything the track holds has been heard and seen.
fn finished() bool {

    if (film() != null and !playback.ended) return false;
    if (playback.track.channels() == 0) return true;
    if (!playback.drained) return false;

    const open = if (stream) |*speakers| speakers else return clock() >= decoded();

    // The service may hold back a few frames as it resamples, so the last hundredth of a second counts as played.
    return open.position() + open.format.rate / 100 >= @atomicLoad(u64, &open.header.written, .acquire);

}

/// The film, when the track has pictures to show.
fn film() ?*media.Movie {

    const movie = playback.track.movie() orelse return null;

    return if (movie.size() != null) movie else null;

}

/// Seconds into the track the speakers have reached, or the clock when nothing plays through them.
fn clock() f64 {

    if (!loaded) return 0;

    if (audible()) {

        const open = &stream.?;
        const rate: f64 = @floatFromInt(open.format.rate);

        return playback.origin + @as(f64, @floatFromInt(open.position() -| playback.mark)) / rate;

    }

    const ticks = if (playing) api.ticks() -| playback.ticks else 0;

    return playback.origin + @as(f64, @floatFromInt(ticks)) / 100;

}

fn audible() bool {

    return stream != null and playback.track.channels() != 0;

}

/// Loads queue entry `order[at]` and plays it from the start.
fn start(at: usize) void {

    unload();

    if (at >= count) return sync();

    place = at;

    const entry = &entries[order[at]];

    playback = .{

        .arena = .init(api.pages),
        .reader = .{},
        .source = undefined,
        .track = undefined,
        .duration = null,

    };

    @memcpy(playback.reader.bytes[0..entry.length], entry.get());
    playback.reader.length = entry.length;

    const allocator = playback.arena.allocator();

    load(allocator, entry) catch |err| {

        playback.arena.deinit();
        message.content.label = trouble(err);
        playing = false;

        return sync();

    };

    loaded = true;
    playing = true;
    playback.duration = playback.track.duration();
    playback.ticks = api.ticks();

    // A film's sound may start a moment after its first picture.
    if (playback.track.movie()) |movie| {

        playback.origin = movie.beginning;
        playback.start = movie.beginning;

    }

    if (playback.track.channels() != 0) connect();

    sync();

}

fn load(allocator: std.mem.Allocator, entry: *const Entry) !void {

    const size = (try playback.reader.files.find(entry.get())).size;
    const buffer = try allocator.alloc(u8, window_bytes);

    playback.source = media.Source.init(buffer, size, &playback.reader, Reader.read);

    const kind = media.Kind.detect(try playback.source.peek(16), entry.get()) orelse return error.Unsupported;

    playback.track = try media.Track.open(allocator, &playback.source, kind);

}

/// Readies the speakers for the track's format, keeping the stream when it already suits.
fn connect() void {

    const format = api.audio.Format{

        .rate = playback.track.rate(),
        .channels = playback.track.channels(),
        .encoding = .f32,

    };

    if (stream) |*open_stream| {

        if (open_stream.format.rate == format.rate and open_stream.format.channels == format.channels) {

            open_stream.flush();
            open_stream.pause(false);
            playback.mark = @atomicLoad(u64, &open_stream.header.written, .acquire);

            return;

        }

        open_stream.close();
        stream = null;

    }

    // A computer without sound still plays, by the clock and in silence.
    stream = api.audio.Stream.open(format, format.rate / 2) catch null;
    playback.mark = 0;
    level();

}

fn unload() void {

    if (!loaded) return;

    playback.track.deinit(playback.arena.allocator());
    playback.arena.deinit();
    loaded = false;
    playing = false;

    if (stream) |*open| {

        open.flush();
        open.pause(true);

    }

    if (frame) |*old| old.deinit();

    frame = null;
    shown_second = -1;

}

/// Starts the track from `seconds` in, dropping whatever was decoded ahead.
fn seek(seconds: f64) void {

    if (!loaded) return;

    const target = std.math.clamp(seconds, playback.start, @max(playback.duration orelse seconds, playback.start));
    const landed = playback.track.seek(target) catch |err| return fail(err);

    playback.origin = landed;
    playback.ticks = api.ticks();
    playback.drained = false;
    playback.ended = false;
    playback.upcoming = null;
    playback.fresh = true;

    if (stream) |*open| {

        open.flush();
        playback.mark = @atomicLoad(u64, &open.header.written, .acquire);

    } else {

        playback.mark = 0;

    }

    times(true);

}

fn jump(seconds: f64) void {

    seek(clock() + seconds);

}

/// Moves to the next track as the order and repeat say; `chosen` when the person asked rather than the track ending.
fn advance(chosen: bool) void {

    if (repeat == .one and !chosen) return seek(playback.start);

    if (place + 1 < count) return start(place + 1);

    if (repeat == .all or chosen) {

        if (shuffled) mix(0);

        return start(0);

    }

    // The queue ran out: stopped at its first track, ready to play again.
    start(0);
    pause(true);

}

fn pause(on: bool) void {

    if (!loaded) return;

    if (!audible()) {

        if (on) playback.origin = clock() else playback.ticks = api.ticks();

    }

    playing = !on;

    if (stream) |*open| open.pause(on);

    sync();

}

fn fail(err: anyerror) void {

    message.content.label = trouble(err);
    unload();
    sync();

}

fn trouble(err: anyerror) []const u8 {

    return switch (err) {

        error.Unsupported => "That file uses a format the player can't decode.",
        error.Invalid => "That file is damaged or isn't music or video.",
        error.OutOfMemory, error.Exhausted => "There isn't enough memory to play that.",
        error.Missing => "That file could not be found.",
        error.Denied => "You don't have permission to play that.",
        else => "That file could not be read.",

    };

}

/// Adds the playable files in `path`'s folder, sorted by name, when `path` is a file; or those in `path` itself, a folder.
fn queueFolder(path: []const u8) void {

    const folder = if (media.Kind.named(path) != null) std.fs.path.dirnamePosix(path) orelse "/" else std.mem.trimRight(u8, path, "/");
    var files = api.Files{};
    var arena = std.heap.ArenaAllocator.init(api.pages);

    defer arena.deinit();

    var names: std.ArrayList([]const u8) = .empty;
    var listed: [32]api.files.Entry = undefined;
    var index: u56 = 0;

    while (true) {

        const found = files.list(if (folder.len == 0) "/" else folder, index, &listed) catch break;

        if (found == 0) break;

        for (listed[0..found]) |entry| {

            if (entry.kind == .file and media.Kind.named(entry.name) != null) names.append(arena.allocator(), arena.allocator().dupe(u8, entry.name) catch break) catch break;

        }

        index += @intCast(found);

    }

    std.mem.sort([]const u8, names.items, {}, ordered);

    var bytes: [256]u8 = undefined;

    for (names.items) |name| {

        add(std.fmt.bufPrint(&bytes, "{s}/{s}", .{ folder, name }) catch continue);

    }

    // A file whose folder could not be listed still plays.
    if (names.items.len == 0 and media.Kind.named(path) != null) add(path);

}

fn ordered(_: void, left: []const u8, right: []const u8) bool {

    return std.ascii.lessThanIgnoreCase(left, right);

}

fn add(path: []const u8) void {

    if (count == most or path.len > 256) return;

    const kind = media.Kind.named(path) orelse return;

    entries[count] = .{

        .length = @intCast(path.len),
        .kind = kind,

    };

    @memcpy(entries[count].path[0..path.len], path);

    // Shuffled, a newcomer lands somewhere after what plays now.
    const slot = if (shuffled and count > place + 1) place + 1 + prng.random().uintLessThan(usize, count - place) else count;

    std.mem.copyBackwards(u16, order[slot + 1 .. count + 1], order[slot..count]);
    order[slot] = @intCast(count);
    count += 1;

}

/// Where entry `path` sits in the play order.
fn find(path: []const u8) ?usize {

    for (order[0..count], 0..) |index, at| {

        if (std.mem.eql(u8, entries[index].get(), path)) return at;

    }

    return null;

}

/// Takes entry `index` out of the queue, moving on if it was playing.
fn remove(index: usize) void {

    if (index >= count) return;

    const current = loaded and order[place] == index;
    const at = std.mem.indexOfScalar(u16, order[0..count], @intCast(index)).?;

    std.mem.copyForwards(Entry, entries[index .. count - 1], entries[index + 1 .. count]);
    std.mem.copyForwards(u16, order[at .. count - 1], order[at + 1 .. count]);
    count -= 1;

    for (order[0..count]) |*value| {

        if (value.* > index) value.* -= 1;

    }

    if (at < place or at == place and place == count and place > 0) place -= 1;

    if (current) {

        if (count == 0) {

            unload();

        } else {

            start(@min(place, count - 1));

        }

    }

    sync();

}

/// Shuffles the order, keeping entry `order[keep]` first.
fn mix(keep: usize) void {

    std.mem.swap(u16, &order[0], &order[keep]);
    prng.random().shuffle(u16, order[1..count]);
    place = 0;

}

/// Shows what plays, the queue, and the controls' states.
fn sync() void {

    const current: ?*const Entry = if (loaded) &entries[order[place]] else null;
    const moving = loaded and film() != null;

    screen.hidden = !moving;
    stage.style.background = if (moving) 0x000000 else theme.background;
    cover.hidden = !loaded or moving;
    message.hidden = loaded;

    if (count == 0 and !loaded) message.content.label = "Open music or a video from Files to play it here.";

    if (current) |entry| {

        const tags = playback.track.tags();

        song.content.label = if (tags.title.length != 0) tags.title.get() else entry.name();
        artist.content.label = tags.artist.get();
        artist.hidden = tags.artist.length == 0;
        detail.content.label = describe();

        window.retitle(std.fmt.bufPrint(&title_bytes, "{s} - Player", .{song.content.label}) catch "Player");

    } else {

        window.retitle("Player");

    }

    play_tool.content.label = (if (playing) gui.Icon.pause else gui.Icon.play).text();
    shuffle_tool.selected = shuffled;
    repeat_tool.selected = repeat != .off;
    repeat_tool.content.label = (if (repeat == .one) gui.Icon.repeat_one else gui.Icon.repeat).text();
    loudness_tool.content.label = speaker().text();
    empty.hidden = count != 0;
    clearing.hidden = count == 0;

    for (&rows, 0..) |*row, index| {

        row.hidden = index >= count;

        if (index >= count) continue;

        const entry = &entries[order[index]];
        const now = loaded and index == place;

        row_names[index].content.label = entry.name();
        row_names[index].style.color = if (now) theme.text else theme.muted;
        row_icons[index].content.label = (if (now) (if (playing) gui.Icon.volume_high else gui.Icon.pause) else if (entry.kind.moving()) gui.Icon.video else gui.Icon.music).text();
        row.selected = now;

    }

    times(true);
    window.refresh();

}

/// The track's format as people read it, such as `FLAC · 44.1 kHz · Stereo`.
fn describe() []const u8 {

    const track = &playback.track;
    const rate: f64 = @floatFromInt(track.rate());
    const layout = switch (track.channels()) {

        0 => "No sound",
        1 => "Mono",
        else => "Stereo",

    };

    if (film()) |movie| {

        const size = movie.size().?;

        return std.fmt.bufPrint(&detail_bytes, "{s} · {d}×{d} · {s}", .{ std.meta.activeTag(track.*).title(), size.width, size.height, layout }) catch "";

    }

    return std.fmt.bufPrint(&detail_bytes, "{s} · {d:.1} kHz · {s}", .{ std.meta.activeTag(track.*).title(), rate / 1000, layout }) catch "";

}

/// Updates the time labels and the position slider when the second shown changes, or always when `force`.
fn times(force: bool) void {

    const now = if (loaded) clock() - playback.start else 0;
    const second: i64 = @intFromFloat(@floor(now));

    if (!force and second == shown_second) return;

    shown_second = second;

    const length: ?f64 = if (loaded and playback.duration != null) playback.duration.? - playback.start else null;

    elapsed.content.label = stamp(&elapsed_bytes, now);
    total.content.label = if (length) |seconds| stamp(&total_bytes, @round(seconds)) else "--:--";

    if (!dragging) position.value = if (length) |seconds| @floatCast(std.math.clamp(now / @max(seconds, 0.001), 0, 1)) else 0;

    window.invalidate(&timeline);

}

/// `seconds` as `M:SS`, or `H:MM:SS` past an hour.
fn stamp(bytes: []u8, seconds: f64) []const u8 {

    const whole: u64 = @intFromFloat(@max(seconds, 0));

    if (whole >= 3600) return std.fmt.bufPrint(bytes, "{d}:{d:0>2}:{d:0>2}", .{ whole / 3600, whole / 60 % 60, whole % 60 }) catch "";

    return std.fmt.bufPrint(bytes, "{d}:{d:0>2}", .{ whole / 60, whole % 60 }) catch "";

}

var dragging = false;

fn seekMoved(slider: *gui.Slider, done: bool) void {

    const length = (if (loaded) playback.duration else null) orelse return;
    const target = playback.start + @as(f64, slider.value) * (length - playback.start);

    dragging = !done;

    if (done) return seek(target);

    elapsed.content.label = stamp(&elapsed_bytes, target - playback.start);
    window.invalidate(&timeline);

}

fn volumeMoved(slider: *gui.Slider, done: bool) void {

    setVolume(@intFromFloat(@round(slider.value * 100)), done);

}

fn setVolume(percent: u8, keep: bool) void {

    volume = @min(percent, 100);
    muted = false;
    loudness.value = @as(f32, @floatFromInt(volume)) / 100;
    level();

    if (keep) remember();

    loudness_tool.content.label = speaker().text();
    window.invalidate(&controls);

}

/// The volume control's icon for how loud the player is.
fn speaker() gui.Icon {

    return if (muted or volume == 0) .mute else if (volume < 50) .volume_low else .volume_high;

}

/// Sets the stream's own volume from the player's.
fn level() void {

    if (stream) |*open| open.loudness(if (muted) 0 else volume);

}

fn remember() void {

    _ = preferences.set("volume", volume);
    _ = preferences.set("repeat", @tagName(repeat));

    preferences.save() catch {

    };

}

fn paint(node: *gui.Node, target: *gui.List) void {

    const shown = frame orelse return;

    target.image(shown.handle, shown.place(node.rect));

}

fn playChosen(_: *gui.Node) void {

    if (loaded) return pause(playing);
    if (count != 0) start(place);

}

fn backChosen(_: *gui.Node) void {

    if (loaded and clock() - playback.start > restart or place == 0) return seek(playback.start);

    start(place - 1);

}

fn forwardChosen(_: *gui.Node) void {

    if (count != 0) advance(true);

}

fn shuffleChosen(_: *gui.Node) void {

    shuffled = !shuffled;

    if (count == 0) return sync();

    const current = order[place];

    if (shuffled) {

        mix(place);

    } else {

        for (order[0..count], 0..) |*value, index| value.* = @intCast(index);

        place = current;

    }

    sync();

}

fn repeatChosen(_: *gui.Node) void {

    repeat = switch (repeat) {

        .off => .all,
        .all => .one,
        .one => .off,

    };

    remember();
    sync();

}

fn muteChosen(_: *gui.Node) void {

    muted = !muted;
    level();
    sync();

}

fn queueChosen(_: *gui.Node) void {

    side.hidden = !side.hidden;
    queue_tool.selected = !side.hidden;
    window.refresh();

}

fn rowChosen(node: *gui.Node) void {

    start(node.data);

}

fn rowOffered(node: *gui.Node, at: gui.Point) void {

    picked = node.data;
    row_menu.show(at);

}

fn playPicked() void {

    start(picked);

}

fn removePicked() void {

    if (picked < count) remove(order[picked]);

}

fn clearPicked() void {

    clearChosen(&clearing);

}

fn clearChosen(_: *gui.Node) void {

    unload();
    count = 0;
    place = 0;
    sync();

}

fn askAdd(_: *gui.Node) void {

    var initial: [256]u8 = undefined;
    const folder = if (count != 0) std.fs.path.dirnamePosix(entries[order[place]].get()) orelse "/" else "";

    dialog.ask(&window, "Add to queue", std.fmt.bufPrint(&initial, "{s}/", .{folder}) catch "/", "Add", &addPath);

}

/// Queues the file or folder at `target`, playing it at once when nothing was queued.
fn addPath(target: []const u8) void {

    const was = count;
    const trimmed = std.mem.trim(u8, target, " ");

    if (media.Kind.named(trimmed) != null) add(trimmed) else queueFolder(trimmed);

    if (was == 0 and count != 0) start(0) else sync();

}
