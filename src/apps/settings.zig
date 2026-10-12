//! Settings: the display mode, the wallpaper, and accounts.

const std = @import("std");

const catalog = @import("catalog.zig");

const api = @import("api");
const gui = @import("gui");

const protocol = api.protocol;
const theme = gui.theme;
pub const panic = api.panic;

const Section = enum {

    display,
    appearance,
    accounts,

};

const Pending = enum {

    none,
    name,
    password,
    current,
    replacement,

};

const modes = [_][2]u16{ .{ 1024, 768 }, .{ 1280, 720 }, .{ 1280, 800 }, .{ 1366, 768 }, .{ 1440, 900 }, .{ 1600, 900 }, .{ 1920, 1080 } };

const sections = [_]struct { title: []const u8, icon: gui.Icon }{

    .{ .title = "Display", .icon = .monitor },
    .{ .title = "Appearance", .icon = .palette },
    .{ .title = "Accounts", .icon = .users },

};

var window: gui.Window = undefined;
/// The desktop's config, which keeps the wallpaper.
var preferences = api.Config{};
var accounts = api.Accounts{};
var screen = api.Display{};

/// The process that launched us, normally the desktop, told when the wallpaper changes.
var session: u64 = 0;
var user: []const u8 = "";
var home: []const u8 = "/";
var home_bytes: [64]u8 = undefined;

var dialog = gui.Dialog{};
var pending = Pending.none;
var draft_name: [32]u8 = undefined;
var draft_length: usize = 0;
var draft_secret: [64]u8 = undefined;
var draft_secret_length: usize = 0;

// Sidebar.
var tab_icons: [sections.len]gui.Node = undefined;
var tab_labels: [sections.len]gui.Node = undefined;
var tab_parts: [sections.len][2]*gui.Node = undefined;
var tabs: [sections.len]gui.Node = undefined;
var tab_list: [sections.len]*gui.Node = undefined;

var sidebar = gui.box(.{

    .width = 180,

    .padding = .all(theme.gap),
    .gap = 2,

    .background = theme.raised,

}, &tab_list);

// Display.
var display_title = gui.label("Display", theme.title_text);
var display_note_bytes: [160]u8 = undefined;
var display_note = gui.label("", theme.caption);
var mode_labels: [modes.len][16]u8 = undefined;
var mode_rows: [modes.len]gui.Node = undefined;
var mode_list: [modes.len]*gui.Node = undefined;

var mode_box = gui.box(.{

    .gap = 2,

}, &mode_list);

var display_parts = [_]*gui.Node{ &display_title, &display_note, &mode_box };

var display_page = gui.box(.{

    .gap = theme.spacing,

}, &display_parts);

// Appearance.
var appearance_title = gui.label("Wallpaper", theme.title_text);
var appearance_note = gui.label("Personalize your desktop.", theme.caption);
var granite = gui.button("Use granite", &useGranite);
var picture_bytes: [256]u8 = undefined;

var picture_text = gui.Text{

    .buffer = &picture_bytes,
    .placeholder = "/home/you/picture.png",

};

var picture_field = gui.input(&picture_text);
var picture_apply = gui.button("Use picture", &usePicture);
var picture_parts = [_]*gui.Node{ &picture_field, &picture_apply };

var picture_row = gui.box(.{

    .direction = .row,
    .gap = theme.gap,

}, &picture_parts);

var appearance_status = gui.label("", theme.caption);
var appearance_parts = [_]*gui.Node{ &appearance_title, &appearance_note, &granite, &picture_row, &appearance_status };

var appearance_page = gui.box(.{

    .gap = theme.spacing,
    .items = .start,

}, &appearance_parts);

// Accounts.
var accounts_title = gui.label("Accounts", theme.title_text);
var account_names: [8][32]u8 = undefined;
var account_lengths: [8]usize = undefined;
var account_admins: [8]bool = undefined;
var account_count: usize = 0;
var account_selected: usize = 0;
var account_initials: [8][1]u8 = undefined;
var account_avatars: [8]gui.Node = undefined;
var account_labels: [8]gui.Node = undefined;
var account_roles: [8]gui.Node = undefined;
var account_parts: [8][3]*gui.Node = undefined;
var account_rows: [8]gui.Node = undefined;
var account_list: [8]*gui.Node = undefined;

var account_box = gui.box(.{

    .gap = 2,

}, &account_list);

var add = gui.button("Add account", &addAccount);
var administrator = gui.button("Administrator", &toggleAdministrator);
var remove = gui.button("Remove", &removeAccount);
var password = gui.button("Change password", &changePassword);
var account_actions = [_]*gui.Node{ &add, &administrator, &remove, &password };

var account_bar = gui.box(.{

    .direction = .row,
    .gap = theme.gap,

}, &account_actions);

var accounts_status = gui.label("", theme.caption);
var accounts_parts = [_]*gui.Node{ &accounts_title, &account_box, &account_bar, &accounts_status };

var accounts_page = gui.box(.{

    .gap = theme.spacing,

}, &accounts_parts);

var pages = [_]*gui.Node{ &display_page, &appearance_page, &accounts_page };

var content = gui.box(.{

    .grow = 1,
    .padding = .all(24),
    .scroll = true,

}, &pages);

var body_parts = [_]*gui.Node{ &sidebar, &content };

var body = gui.box(.{

    .grow = 1,
    .direction = .row,

}, &body_parts);

var root_parts = [_]*gui.Node{ &body };
var root = gui.box(.{}, &root_parts);

pub export fn app_main(parent: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .application);
    dialog.init();
    session = parent;

    var argument_bytes: [256]u8 = undefined;

    home = std.fmt.bufPrint(&home_bytes, "{s}", .{catalog.home(api.argument(&argument_bytes)) orelse "/"}) catch "/";
    user = std.fs.path.basename(home);

    for (sections, 0..) |section, index| {

        tab_icons[index] = gui.icon(section.icon, theme.icon);
        tab_labels[index] = gui.label(section.title, .{});
        tab_parts[index] = .{ &tab_icons[index], &tab_labels[index] };

        tabs[index] = gui.box(theme.item.with(.{

            .height = 36,

        }), &tab_parts[index]);

        tabs[index].action = &pick;
        tabs[index].data = index;
        tab_list[index] = &tabs[index];

    }

    for (modes, 0..) |mode, index| {

        mode_rows[index] = gui.label(std.fmt.bufPrint(&mode_labels[index], "{d} x {d}", .{ mode[0], mode[1] }) catch "", theme.item.with(.{

            .padding = gui.Edges.axes(0, 12),

        }));

        mode_rows[index].action = &setMode;
        mode_rows[index].data = index;
        mode_list[index] = &mode_rows[index];

    }

    for (0..8) |index| {

        account_avatars[index] = gui.label("", .{

            .width = 30,
            .height = 30,

            .background = theme.selected,
            .radius = 15,

            .text_align = .center,

        });

        account_labels[index] = gui.label("", .{

            .grow = 1,

        });

        account_roles[index] = gui.label("", theme.caption);
        account_parts[index] = .{ &account_avatars[index], &account_labels[index], &account_roles[index] };

        account_rows[index] = gui.box(theme.item.with(.{

            .height = 44,

        }), &account_parts[index]);

        account_rows[index].action = &pickAccount;
        account_rows[index].data = index;
        account_list[index] = &account_rows[index];

    }

    picture_field.style = picture_field.style.with(.{

        .width = 340,

    });

    window = gui.Window.open(&root, .{

        .title = "Settings",
        .application = .settings,

        .width = 720,
        .height = 480,

    }) catch api.exit(3);

    show(.display);

    while (true) {

        const event = window.next(500) orelse continue;

        if (event.kind == .close) window.quit();

    }

}

fn pick(tab: *gui.Node) void {

    show(@enumFromInt(tab.data));

}

fn show(section: Section) void {

    for (pages, 0..) |page, index| page.hidden = index != @intFromEnum(section);
    for (&tabs, 0..) |*tab, index| tab.selected = index == @intFromEnum(section);

    switch (section) {

        .display => describeDisplay(""),
        .accounts => loadAccounts(),
        .appearance => {

        },

    }

    content.offset = 0;
    dialog.close();
    window.refresh();

}

fn describeDisplay(problem: []const u8) void {

    const size = screen.size() catch api.display.Area{};

    const adapter = screen.adapter() catch api.display.Adapter{};

    display_note.content.label = if (problem.len != 0) problem else std.fmt.bufPrint(&display_note_bytes, "{d} x {d} on {s}, {s}.", .{ size.width, size.height, adapter.name(), adapter.rendering() }) catch "";

    for (modes, 0..) |mode, index| mode_rows[index].selected = mode[0] == size.width and mode[1] == size.height;

    window.refresh();

}

fn setMode(row: *gui.Node) void {

    const mode = modes[row.data];

    screen.mode(mode[0], mode[1]) catch |err| return describeDisplay(switch (err) {

        error.Denied => "Only administrators can change the display mode.",
        error.Invalid => "This screen cannot show that mode.",
        else => "The display service is unavailable.",

    });

    describeDisplay("");

}

/// Saves the wallpaper choice, empty for granite, in the `desktop` config and asks the desktop to show it.
fn wallpaper(choice: []const u8) void {

    preferences.open(user, "desktop");
    if (!preferences.set("wallpaper", choice)) return note(error.Invalid);
    preferences.save() catch |err| return note(err);

    _ = api.call(session, protocol.pack(.reload, 0)) catch {

    };
    appearance_status.content.label = "Wallpaper changed.";
    window.refresh();

}

fn useGranite(_: *gui.Node) void {

    wallpaper("");

}

fn usePicture(_: *gui.Node) void {

    const choice = picture_text.text();

    if (!catalog.picture(choice)) {

        picture_field.invalid = true;
        appearance_status.content.label = "Choose a .png file.";
        return window.refresh();

    }

    wallpaper(choice);

}

fn note(err: api.ServiceError) void {

    appearance_status.content.label = if (err == error.Denied) "Permission denied." else "Could not save the choice.";
    window.refresh();

}

fn loadAccounts() void {

    account_count = 0;

    while (account_count < account_names.len) {

        const account = (accounts.list(@intCast(account_count)) catch break) orelse break;
        const length = @min(account.name.len, 32);

        @memcpy(account_names[account_count][0..length], account.name[0..length]);
        account_lengths[account_count] = length;
        account_admins[account_count] = account.identity.admin;
        account_count += 1;

    }

    account_selected = @min(account_selected, account_count -| 1);

    for (0..8) |index| {

        account_rows[index].hidden = index >= account_count;
        account_rows[index].selected = index == account_selected;
        if (index >= account_count) continue;

        account_initials[index] = .{std.ascii.toUpper(account_names[index][0])};
        account_avatars[index].content.label = &account_initials[index];
        account_labels[index].content.label = account_names[index][0..account_lengths[index]];
        account_roles[index].content.label = if (account_admins[index]) "Administrator" else "Standard";

    }

    window.refresh();

}

fn pickAccount(row: *gui.Node) void {

    account_selected = row.data;
    loadAccounts();

}

fn selectedName() []const u8 {

    return account_names[account_selected][0..account_lengths[account_selected]];

}

fn toggleAdministrator(_: *gui.Node) void {

    administrator.selected = !administrator.selected;
    window.refresh();

}

fn addAccount(_: *gui.Node) void {

    pending = .name;
    dialog.edit.secret = false;
    dialog.ask(&window, if (administrator.selected) "New administrator's name" else "New account's name", "", "Next", &advance);

}

fn removeAccount(_: *gui.Node) void {

    if (account_count == 0) return;

    var message: [80]u8 = undefined;

    dialog.edit.secret = false;
    dialog.check(&window, std.fmt.bufPrint(&message, "Remove {s}?", .{selectedName()}) catch "Remove it?", "Their files stay in their home folder.", "Remove", &applyRemove);

}

fn applyRemove(_: []const u8) void {

    accounts.remove(selectedName()) catch |err| return say(switch (err) {

        error.Busy => "You can't remove the account you're using.",
        error.Denied => "Only administrators can remove accounts.",
        else => "Could not remove that account.",

    });

    say("Account removed.");
    loadAccounts();

}

fn changePassword(_: *gui.Node) void {

    if (account_count == 0) return;

    const own = std.mem.eql(u8, selectedName(), user);

    pending = if (own) .current else .replacement;
    draft_secret_length = 0;
    dialog.edit.secret = true;
    dialog.ask(&window, if (own) "Current password" else "New password", "", "Next", &advance);

}

/// Steps through the account prompts, which ask one field at a time.
fn advance(value: []const u8) void {

    switch (pending) {

        .name => {

            if (value.len == 0 or value.len > draft_name.len) return dialog.refuse("Names need 1 to 32 characters.");

            @memcpy(draft_name[0..value.len], value);
            draft_length = value.len;
            pending = .password;
            dialog.edit.secret = true;
            dialog.ask(&window, "Their password", "", "Create", &advance);

        },
        .password => {

            accounts.create(draft_name[0..draft_length], value, administrator.selected) catch |err| {

                pending = .none;
                dialog.edit.secret = false;

                return say(switch (err) {

                    error.Exists => "That name is taken.",
                    error.Denied => "Only administrators can add accounts.",
                    else => "Could not add that account.",

                });

            };

            pending = .none;
            dialog.edit.secret = false;
            say("Account added.");
            loadAccounts();

        },
        .current => {

            @memcpy(draft_secret[0..@min(value.len, draft_secret.len)], value[0..@min(value.len, draft_secret.len)]);
            draft_secret_length = @min(value.len, draft_secret.len);
            pending = .replacement;
            dialog.ask(&window, "New password", "", "Change", &advance);

        },
        .replacement => {

            defer std.crypto.secureZero(u8, &draft_secret);

            pending = .none;
            dialog.edit.secret = false;
            if (value.len == 0) return say("Passwords can't be empty.");

            accounts.password(selectedName(), value, draft_secret[0..draft_secret_length]) catch |err| return say(if (err == error.Denied) "That password was wrong, or you may not change it." else "Could not change the password.");
            say("Password changed.");

        },
        .none => {

        },

    }

}

fn say(message: []const u8) void {

    accounts_status.content.label = message;
    window.refresh();

}
