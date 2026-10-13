//! HTTP/1.1 requests over the net service, with HTTPS through `tls.zig` trusting the certificate authorities the net service
//! keeps; the TLS session runs in the calling app, apart from every other app's.

const std = @import("std");

const api = @import("root.zig");
const Tls = @import("tls.zig");

const net = api.net;
const Bundle = std.crypto.Certificate.Bundle;

pub const HttpError = net.NetError || error{ Malformed, Unsupported, Redirects, Untrusted, Broken };

pub const Method = std.http.Method;
pub const Header = std.http.Header;

/// An `http://` or `https://` address, split into the parts a request needs.
pub const Url = struct {

    secure: bool,
    host: []const u8,
    port: u16,

    /// The path and query, never empty.
    target: []const u8,

    pub fn parse(text: []const u8) ?Url {

        const secure = std.ascii.startsWithIgnoreCase(text, "https://");
        if (!secure and !std.ascii.startsWithIgnoreCase(text, "http://")) return null;

        const rest = text[if (secure) 8 else 7 ..];
        const split = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        const authority = rest[0..split];
        const colon = std.mem.lastIndexOfScalar(u8, authority, ':');
        const host = authority[0 .. colon orelse authority.len];

        if (host.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return null;

        const target = rest[split..];
        const fragment = std.mem.indexOfScalar(u8, target, '#') orelse target.len;

        return .{

            .secure = secure,
            .host = host,
            .port = if (colon) |at| std.fmt.parseInt(u16, authority[at + 1 ..], 10) catch return null else if (secure) 443 else 80,
            .target = if (fragment == 0 or target[0] != '/') "/" else target[0..fragment],

        };

    }

};

/// What to ask of an address: GET with no headers and no body unless told otherwise.
pub const Request = struct {

    method: Method = .GET,

    /// Sent after our own; one naming `Accept` or `User-Agent` replaces ours, and one naming `Host`, `Connection`,
    /// `Content-Length`, or an encoding is left out, as the request sets those itself.
    headers: []const Header = &.{},

    body: []const u8 = "",

};

/// Trusted roots, read from the net service on first use and kept for the life of the app.
var bundle: ?Bundle = null;

/// Fetches `url` as `send` does with a plain GET.
pub fn get(allocator: std.mem.Allocator, url: []const u8, sink: *std.Io.Writer) HttpError!u16 {

    return send(allocator, url, .{}, sink, null);

}

/// Sends `request` to `url`, following up to five redirects, and writes the final response's body to `sink` and, when given,
/// its status line and headers to `head`; returns its status. `allocator` must outlive the app, which keeps the trusted roots.
pub fn send(allocator: std.mem.Allocator, url: []const u8, request: Request, sink: *std.Io.Writer, head: ?*std.Io.Writer) HttpError!u16 {

    var location: [2048]u8 = undefined;
    var current = url;
    var asked = request;

    for (0..6) |_| {

        if (current.len > location.len) return error.Malformed;

        // A redirect's address lives in the response it came in, so it moves to `location` first.
        std.mem.copyForwards(u8, location[0..current.len], current);
        current = location[0..current.len];

        const parsed = Url.parse(current) orelse return error.Malformed;
        const next = try fetch(allocator, parsed, asked, sink, head, &location);

        switch (next) {

            .status => |code| return code,
            .moved => |moved| {

                current = location[0..moved.length];

                // As browsers do, a 303, or a 301 or 302 after a POST, asks again with GET and no body.
                if (moved.code == 303 or (moved.code <= 302 and asked.method == .POST)) asked = .{

                    .headers = asked.headers,

                };

            },

        }

    }

    return error.Redirects;

}

/// Why a request failed, as a short lowercase phrase to follow a name or a colon.
pub fn reason(err: HttpError) []const u8 {

    return switch (err) {

        error.Offline => "network unavailable",
        error.Refused => "connection refused",
        error.Timeout => "timed out",
        error.Cancelled => "cancelled",
        error.Missing => "not found",
        error.Denied => "permission denied",
        error.Full, error.Exhausted => "out of connections or memory",
        error.Untrusted => "certificate not trusted",
        error.Malformed, error.Unsupported => "unexpected address or response",
        error.Redirects => "too many redirects",
        error.Broken => "connection broken",
        error.Invalid => "invalid argument",
        else => "network service unavailable",

    };

}

const Outcome = union(enum) {

    status: u16,

    /// Redirected with `code`, to the address now in the first `length` bytes of the location buffer.
    moved: struct {

        code: u16,
        length: usize,

    },

};

fn fetch(allocator: std.mem.Allocator, url: Url, request: Request, sink: *std.Io.Writer, head: ?*std.Io.Writer, location: *[2048]u8) HttpError!Outcome {

    const address = try net.resolve(url.host);
    const socket = try net.Socket.connect(.tcp, address, url.port);

    defer socket.close();

    // TLS reads whole records, so both directions buffer at least one.
    const buffers = allocator.alloc(u8, 4 * Tls.min_buffer_len) catch return error.Exhausted;

    defer allocator.free(buffers);

    var stream = socket.stream(buffers[0..Tls.min_buffer_len], buffers[Tls.min_buffer_len..][0..Tls.min_buffer_len]);
    var input = &stream.reader;
    var output = &stream.writer;
    var session: Tls = undefined;

    if (url.secure) {

        session = Tls.init(input, output, .{

            .host = .{ .explicit = url.host },
            .ca = .{ .bundle = try trust(allocator) },
            .read_buffer = buffers[2 * Tls.min_buffer_len ..][0..Tls.min_buffer_len],
            .write_buffer = buffers[3 * Tls.min_buffer_len ..],
            .now = @intCast(net.utc()),
            .random = api.random,

        }) catch |err| return switch (err) {

            error.TlsCertificateNotVerified, error.CertificateHostMismatch, error.CertificateIssuerMismatch, error.CertificateExpired, error.CertificateNotYetValid, error.CertificateSignatureInvalid => error.Untrusted,
            else => if (stream.failure) |failure| failure else error.Broken,

        };

        input = &session.reader;
        output = &session.writer;

    }

    ask(output, url, request) catch return stream.failure orelse error.Broken;
    if (url.secure) stream.writer.flush() catch return stream.failure orelse error.Broken;

    var reader = std.http.Reader{

        .in = input,
        .interface = undefined,
        .state = .ready,
        .max_head_len = 16 * 1024,

    };

    const bytes = reader.receiveHead() catch return stream.failure orelse error.Malformed;
    const parsed = std.http.Client.Response.Head.parse(bytes) catch return error.Malformed;
    const code = @intFromEnum(parsed.status);

    if (code >= 300 and code < 400 and code != 304) {

        const moved = parsed.location orelse return .{ .status = code };

        return .{

            .moved = .{

                .code = code,
                .length = try resolve(url, moved, location),

            },

        };

    }

    if (head) |out| out.writeAll(std.mem.trimRight(u8, bytes, "\r\n")) catch return error.Broken;
    if (request.method == .HEAD) return .{ .status = code };

    var transfer: [64]u8 = undefined;
    const body = reader.bodyReader(&transfer, parsed.transfer_encoding, parsed.content_length);

    _ = body.streamRemaining(sink) catch return stream.failure orelse error.Broken;

    return .{ .status = code };

}

/// Writes `request` for `url`: its line, our headers and the caller's, and its body.
fn ask(output: *std.Io.Writer, url: Url, request: Request) std.Io.Writer.Error!void {

    try output.print("{s} {s} HTTP/1.1\r\nHost: {s}\r\n", .{ @tagName(request.method), url.target, url.host });
    if (!named(request.headers, "user-agent")) try output.writeAll("User-Agent: GraniteOS/3\r\n");
    if (!named(request.headers, "accept")) try output.writeAll("Accept: */*\r\n");
    try output.writeAll("Accept-Encoding: identity\r\nConnection: close\r\n");

    for (request.headers) |header| {

        if (ours(header.name)) continue;
        try output.print("{s}: {s}\r\n", .{ header.name, header.value });

    }

    if (request.body.len != 0 or request.method.requestHasBody()) try output.print("Content-Length: {d}\r\n", .{request.body.len});

    try output.writeAll("\r\n");
    try output.writeAll(request.body);
    try output.flush();

}

fn named(headers: []const Header, name: []const u8) bool {

    for (headers) |header| {

        if (std.ascii.eqlIgnoreCase(header.name, name)) return true;

    }

    return false;

}

/// Whether the request sets header `name` itself, whatever the caller says.
fn ours(name: []const u8) bool {

    for ([_][]const u8{ "host", "connection", "content-length", "transfer-encoding", "accept-encoding" }) |kept| {

        if (std.ascii.eqlIgnoreCase(name, kept)) return true;

    }

    return false;

}

/// Writes where redirect `moved` leads from `url` into `out`, returning its length.
fn resolve(url: Url, moved: []const u8, out: *[2048]u8) HttpError!usize {

    if (Url.parse(moved) != null) {

        if (moved.len > out.len) return error.Malformed;
        std.mem.copyForwards(u8, out[0..moved.len], moved);

        return moved.len;

    }

    // A path on the same server: absolute, or relative to the current one's folder.
    const folder = url.target[0 .. (std.mem.lastIndexOfScalar(u8, url.target, '/') orelse 0) + 1];
    const base = if (moved.len != 0 and moved[0] == '/') "" else folder;

    // `moved` lives in the response, not in `out`, so the two never overlap.
    const text = std.fmt.bufPrint(out, "{s}://{s}:{d}{s}{s}", .{ if (url.secure) "https" else "http", url.host, url.port, base, moved }) catch return error.Malformed;

    return text.len;

}

/// The trusted roots, parsed from the PEM the net service hands out.
fn trust(allocator: std.mem.Allocator) HttpError!Bundle {

    if (bundle) |kept| return kept;

    const pem = try net.roots(allocator);

    defer allocator.free(pem);

    const decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");
    const now: i64 = @intCast(net.utc());
    const begin = "-----BEGIN CERTIFICATE-----";
    const end = "-----END CERTIFICATE-----";

    var result = Bundle{};
    var at: usize = 0;

    while (std.mem.indexOfPos(u8, pem, at, begin)) |found| {

        const start = found + begin.len;
        const stop = std.mem.indexOfPos(u8, pem, start, end) orelse break;
        const encoded = pem[start..stop];
        const decoded: u32 = @intCast(result.bytes.items.len);

        at = stop + end.len;

        result.bytes.ensureUnusedCapacity(allocator, encoded.len) catch return error.Exhausted;
        result.bytes.items.len += decoder.decode(result.bytes.unusedCapacitySlice(), encoded) catch continue;

        // A root that will not parse is left out rather than failing the rest; expired ones are left out anyway.
        result.parseCert(allocator, decoded, now) catch {

            result.bytes.items.len = decoded;

        };

    }

    bundle = result;

    return result;

}
