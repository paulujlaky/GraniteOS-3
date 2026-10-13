//! HTTP/1.1 GET over the net service, with HTTPS through `tls.zig` trusting the certificate authorities the net service
//! keeps; the TLS session runs in the calling app, apart from every other app's.

const std = @import("std");

const api = @import("root.zig");
const Tls = @import("tls.zig");

const net = api.net;
const Bundle = std.crypto.Certificate.Bundle;

pub const HttpError = net.NetError || error{ Malformed, Unsupported, Redirects, Untrusted, Broken };

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

/// Trusted roots, read from the net service on first use and kept for the life of the app.
var bundle: ?Bundle = null;

/// Fetches `url`, following up to five redirects, and writes the final response's body to `sink`; returns its status.
pub fn get(allocator: std.mem.Allocator, url: []const u8, sink: *std.Io.Writer) HttpError!u16 {

    var location: [2048]u8 = undefined;
    var current = url;

    for (0..6) |_| {

        if (current.len > location.len) return error.Malformed;

        // A redirect's address lives in the response it came in, so it moves to `location` first.
        std.mem.copyForwards(u8, location[0..current.len], current);
        current = location[0..current.len];

        const parsed = Url.parse(current) orelse return error.Malformed;
        const next = try fetch(allocator, parsed, sink, &location);

        switch (next) {

            .status => |code| return code,
            .moved => |length| current = location[0..length],

        }

    }

    return error.Redirects;

}

const Outcome = union(enum) {

    status: u16,

    /// Redirected, to the address now in the first bytes of the location buffer.
    moved: usize,

};

fn fetch(allocator: std.mem.Allocator, url: Url, sink: *std.Io.Writer, location: *[2048]u8) HttpError!Outcome {

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

    output.print("GET {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: GraniteOS/3\r\nAccept: */*\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n", .{ url.target, url.host }) catch return stream.failure orelse error.Broken;
    output.flush() catch return stream.failure orelse error.Broken;
    if (url.secure) stream.writer.flush() catch return stream.failure orelse error.Broken;

    var reader = std.http.Reader{

        .in = input,
        .interface = undefined,
        .state = .ready,
        .max_head_len = 16 * 1024,

    };

    const head = std.http.Client.Response.Head.parse(reader.receiveHead() catch return stream.failure orelse error.Malformed) catch return error.Malformed;
    const code = @intFromEnum(head.status);

    if (code >= 300 and code < 400 and code != 304) {

        const moved = head.location orelse return .{ .status = code };

        return .{ .moved = try resolve(url, moved, location) };

    }

    var transfer: [64]u8 = undefined;
    const body = reader.bodyReader(&transfer, head.transfer_encoding, head.content_length);

    _ = body.streamRemaining(sink) catch return stream.failure orelse error.Broken;

    return .{ .status = code };

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
