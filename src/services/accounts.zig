const std = @import("std");

const api = @import("api");

const protocol = api.protocol;
const bcrypt = std.crypto.pwhash.bcrypt;
pub const panic = api.panic;

const database = "/system/accounts";
const first_user = 1000;
const name_limit = 32;
const password_limit = 128;

const cost = bcrypt.Params{

    .rounds_log = 10,
    .silently_truncate_password = false,

};

const admin = 1;
const removed = 2;

// Removed accounts stay as tombstones so their user numbers are never handed out again.
const Record = extern struct {

    user: u32,
    flags: u8,
    length: u8,
    name: [name_limit]u8,

    salt: [16]u8,
    hash: [23]u8,
    reserved: u8,

};

const Found = struct {

    index: u64,
    record: Record,

};

comptime {

    if (@sizeOf(Record) != 80) @compileError("Account layout");

}

var files = api.Files{

};

var input: [512]u8 = undefined;

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .service);
    if (!api.permits(.accounts) or api.permits(.ports) or api.permits(.management) or api.permits(.dma)) api.exit(2);

    while (true) {

        const message = api.receive(true) catch continue;

        api.reply(message, handle(message)) catch {

        };

        std.crypto.secureZero(u8, &input);

    }

}

fn handle(message: api.Request) u64 {

    const operation = protocol.operation(message.second);

    switch (operation) {

        .hello => return protocol.version,
        .crash => return if (message.first == api.raw(.owner, 0, 0, 0).first) fault() else protocol.invalid,
        .login, .logout, .create, .remove, .password, .list => {

        },
        else => return protocol.invalid,

    }

    @memset(&input, 0);
    api.fetch(message, 0, input[0..@min(message.fourth, input.len)]) catch return protocol.invalid;

    return serve(message, operation) catch |err| switch (err) {

        error.Missing => protocol.missing,
        error.Exists => protocol.exists,
        error.Full => protocol.full,
        error.Busy => protocol.busy,
        error.Denied => protocol.denied,
        else => protocol.invalid,

    };

}

fn serve(message: api.Request, operation: protocol.Operation) !u64 {

    const caller = api.sender(message);
    var fields = std.mem.splitScalar(u8, &input, 0);
    const name = fields.next().?;
    const secret = fields.next() orelse "";
    const current = fields.next() orelse "";

    switch (operation) {

        .login => {

            const found = try find(name);
            const record = if (found) |entry| entry.record else std.mem.zeroes(Record);

            // A missing account still costs one hash, so timing never reveals which names exist.
            if (!matches(record, secret) or found == null) return error.Denied;

            const identity = api.abi.Identity{

                .user = record.user,
                .admin = record.flags & admin != 0,

            };

            try assign(message, identity);

            return @bitCast(identity);

        },
        .logout => {

            try assign(message, api.abi.nobody);
            return 0;

        },
        .create => return create(caller, name, secret, protocol.value(message.second) != 0),
        .remove => {

            if (!caller.admin) return error.Denied;

            var found = try find(name) orelse return error.Missing;

            if (found.record.user == caller.user) return error.Busy;
            found.record.flags |= removed;
            try save(found);

            return 0;

        },
        .password => {

            var found = try find(name) orelse return error.Missing;

            if (found.record.user == caller.user) {

                if (!matches(found.record, current)) return error.Denied;

            } else if (!caller.admin) {

                return error.Denied;

            }

            try seal(&found.record, secret);
            try save(found);

            return 0;

        },
        .list => {

            var record: Record = undefined;
            var index: u64 = 0;
            var live: u64 = 0;

            while (try load(index, &record)) : (index += 1) {

                if (record.flags & removed != 0) continue;

                if (live == protocol.value(message.second)) {

                    try api.store(message, 0, record.name[0..record.length]);

                    return @bitCast(api.abi.Identity{

                        .user = record.user,
                        .admin = record.flags & admin != 0,

                    });

                }

                live += 1;

            }

            return error.Missing;

        },
        else => return error.Invalid,

    }

}

// The first account is always an administrator, and anyone at the console may create it.
fn create(caller: api.abi.Identity, name: []const u8, password: []const u8, privileged: bool) !u64 {

    try valid(name);

    var record: Record = undefined;
    var index: u64 = 0;
    var next: u32 = first_user;
    var claimed = false;

    while (try load(index, &record)) : (index += 1) {

        next = @max(next, record.user + 1);
        if (record.flags & removed != 0) continue;

        claimed = true;
        if (std.mem.eql(u8, record.name[0..record.length], name)) return error.Exists;

    }

    if (claimed and !caller.admin) return error.Denied;
    if (!claimed) try prepare();

    var home: [6 + name_limit]u8 = undefined;
    const path = std.fmt.bufPrint(&home, "/home/{s}", .{name}) catch unreachable;

    try files.directory(path);
    try files.change(path, 0o700, next);

    record = std.mem.zeroes(Record);
    record.user = next;
    record.flags = if (privileged or !claimed) admin else 0;
    record.length = @intCast(name.len);
    @memcpy(record.name[0..name.len], name);
    try seal(&record, password);

    try save(.{

        .index = index,
        .record = record,

    });

    return next;

}

fn prepare() !void {

    for ([_][]const u8{ "/system", "/home" }) |path| {

        files.directory(path) catch |err| if (err != error.Exists) return err;

    }

    try files.change("/system", 0o700, null);

    // Tombstones alone mean the database exists; creating it again would truncate them.
    var record: Record = undefined;
    if (try load(0, &record)) return;

    try files.create(database);
    try files.change(database, 0o600, null);

}

fn find(name: []const u8) !?Found {

    var record: Record = undefined;
    var index: u64 = 0;

    while (try load(index, &record)) : (index += 1) {

        if (record.flags & removed == 0 and std.mem.eql(u8, record.name[0..record.length], name)) return .{

            .index = index,
            .record = record,

        };

    }

    return null;

}

// Reads record `index`; false past the end, or before the database exists.
fn load(index: u64, record: *Record) !bool {

    // ponytail: one request per record; read in blocks if accounts reach the thousands.
    const bytes = files.read(database, @intCast(index * @sizeOf(Record)), database.len + 1 + @sizeOf(Record)) catch |err| {

        return if (err == error.Missing) false else err;

    };

    if (bytes.len < @sizeOf(Record)) return false;

    record.* = std.mem.bytesToValue(Record, bytes[0..@sizeOf(Record)]);
    if (record.length > name_limit) return error.Invalid;

    return true;

}

fn save(found: Found) !void {

    try files.write(database, @intCast(found.index * @sizeOf(Record)), std.mem.asBytes(&found.record));

}

fn seal(record: *Record, password: []const u8) !void {

    if (password.len == 0 or password.len > password_limit) return error.Invalid;

    api.random(&record.salt);
    record.hash = bcrypt.bcrypt(password, record.salt, cost);

}

fn matches(record: Record, password: []const u8) bool {

    const hash = bcrypt.bcrypt(password, record.salt, cost);

    return password.len != 0 and std.crypto.timing_safe.eql([23]u8, hash, record.hash);

}

fn assign(message: api.Request, identity: api.abi.Identity) !void {

    _ = try api.checked(api.raw(.assign, message.first, message.third, @bitCast(identity)));

}

fn valid(name: []const u8) !void {

    if (name.len == 0 or name.len > name_limit or name[0] < 'a' or name[0] > 'z') return error.Invalid;

    for (name) |byte| {

        if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '_' and byte != '-') return error.Invalid;

    }

}

fn fault() noreturn {

    asm volatile ("ud2");
    api.exit(1);

}
