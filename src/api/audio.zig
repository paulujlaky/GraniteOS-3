//! Sound from an app's side: streams of samples the audio service mixes to the speakers, the system volume, and the short
//! sounds the system plays.

const std = @import("std");

const api = @import("root.zig");

const protocol = api.protocol;

/// How a stream's samples are stored, each channel's interleaved frame after frame.
pub const Encoding = enum(u8) {

    s16,
    f32,
    _,

    pub fn size(self: Encoding) usize {

        return switch (self) {

            .s16 => 2,
            .f32 => 4,
            _ => 0,

        };

    }

    pub fn Sample(comptime self: Encoding) type {

        return switch (self) {

            .s16 => i16,
            .f32 => f32,
            _ => unreachable,

        };

    }

};

/// What a stream plays: mono or stereo frames at any rate the service can resample, from 8 to 192 kHz.
pub const Format = struct {

    rate: u32 = 48000,
    channels: u8 = 2,
    encoding: Encoding = .s16,

    pub fn valid(self: Format) bool {

        return self.rate >= 8000 and self.rate <= 192000 and self.channels >= 1 and self.channels <= 2 and self.encoding.size() != 0;

    }

    pub fn frame(self: Format) usize {

        return self.channels * self.encoding.size();

    }

};

/// The start of a stream's shared memory, written by both sides; its samples follow at `Header.data`.
pub const Header = extern struct {

    /// Frames the app has written and the service has taken, ever; the ring holds those between.
    written: u64 = 0,
    taken: u64 = 0,

    /// The frame the speakers are playing, as near as the service can tell.
    played: u64 = 0,

    /// Frames before this one are dropped unplayed, as when a player seeks.
    discard: u64 = 0,

    rate: u32,
    capacity: u32,
    channels: u8,
    encoding: Encoding,
    paused: bool = false,

    /// The stream's own volume in percent, under the system's.
    volume: u8 = 100,

    /// Times the stream ran dry while playing.
    underruns: u32 = 0,

    /// Where samples start, past the header.
    pub const data = 64;

};

comptime {

    std.debug.assert(@sizeOf(Header) <= Header.data);

}

/// The system's short sounds.
pub const Sound = enum(u8) {

    /// Signing in.
    login,

    /// A notification arriving.
    notice,

    /// Something refused, such as a wrong password.
    alert,

    /// The volume changing, played at the new level.
    level,

    /// A screenshot taken.
    capture,
    _,

};

/// The output and its settings, as the audio service reports them.
pub const Status = extern struct {

    /// The controller's PCI vendor id, with its device id in the upper half.
    device: u32 = 0,

    /// The codec's vendor id, with its device id in the lower half.
    codec: u32 = 0,

    /// Output pins driven, such as line out and headphones.
    outputs: u8 = 0,

    volume: u8 = 0,
    muted: bool = false,

    /// Whether the system's short sounds play.
    sounds: bool = true,

    streams: u32 = 0,
    rate: u32 = 0,

    /// Frames between a stream's samples being taken and reaching the speakers.
    latency: u32 = 0,

    /// Times the device ran out of mixed sound.
    underruns: u32 = 0,

    /// What people call the controller, such as `Intel HD Audio`.
    pub fn adapter(self: Status) []const u8 {

        return switch (self.device) {

            0x197715ad => "VMware HD Audio",
            0x293e8086 => "Intel ICH9 HD Audio",
            0xa3488086 => "Intel 300 Series HD Audio",
            0xa2f08086 => "Intel 200 Series HD Audio",
            0xa1708086 => "Intel 100 Series HD Audio",
            else => if (self.device & 0xffff == 0x8086) "Intel HD Audio" else "HD Audio",

        };

    }

    /// What people call the codec, such as `Realtek ALC892`, written into `bytes`.
    pub fn chip(self: Status, bytes: []u8) []const u8 {

        const model = self.codec & 0xffff;

        return switch (self.codec >> 16) {

            0x10ec => std.fmt.bufPrint(bytes, "Realtek ALC{x}", .{model}) catch "Realtek",
            0x8086 => "Intel display audio",
            0x15ad => "VMware virtual codec",
            0x1013 => "Cirrus Logic",
            0x14f1 => "Conexant",
            0x111d, 0x8384 => "IDT",
            0 => "No codec",
            else => std.fmt.bufPrint(bytes, "Codec {x:0>8}", .{self.codec}) catch "Codec",

        };

    }

};

/// Sent in `wait` to ask for every written frame to be played, rather than for room.
const draining: u56 = 1 << 32;

var endpoint: u64 = 0;

pub fn status() api.ServiceError!Status {

    var result = Status{};

    _ = try request(.info, 0, std.mem.asBytes(&result));

    return result;

}

/// Sets the system volume in percent, as any signed-in user may; the choice outlasts restarts.
pub fn volume(percent: u8) api.ServiceError!void {

    _ = try request(.change, @min(percent, 100), &.{});

}

/// Silences every stream, or lets them play again at the volume they had.
pub fn mute(on: bool) api.ServiceError!void {

    _ = try request(.change, @as(u56, 1) << 8 | @intFromBool(on), &.{});

}

/// Lets the system's short sounds play, or keeps them quiet.
pub fn sounds(on: bool) api.ServiceError!void {

    _ = try request(.enable, @intFromBool(on), &.{});

}

/// Plays one of the system's short sounds, unless they are turned off.
pub fn play(sound: Sound) api.ServiceError!void {

    _ = try request(.chime, @intFromEnum(sound), &.{});

}

/// Plays `sound` if it can, for callers that carry on silently without one, as on a computer with no audio.
pub fn cue(sound: Sound) void {

    play(sound) catch {

    };

}

/// A stream of samples the service plays as they come, from a ring in memory shared with it; written by one thread.
pub const Stream = struct {

    memory: api.Shared,
    header: *Header,
    format: Format,
    id: u64 = 0,

    /// Opens a stream holding up to `frames` frames of `format` unplayed; a quarter of a second suits most players.
    pub fn open(format: Format, frames: u32) api.ServiceError!Stream {

        if (!format.valid() or frames < 64) return error.Invalid;

        const bytes = Header.data + @as(usize, frames) * format.frame();
        const memory = try api.share(std.math.divCeil(usize, bytes, 4096) catch unreachable);
        const header: *Header = @ptrCast(memory.bytes.ptr);

        header.* = .{

            .rate = format.rate,
            .capacity = frames,
            .channels = format.channels,
            .encoding = format.encoding,

        };

        var result = Stream{

            .memory = memory,
            .header = header,
            .format = format,

        };

        result.connect() catch |err| {

            api.detach(memory.handle);
            return err;

        };

        return result;

    }

    /// Frames that fit without overwriting any unplayed.
    pub fn room(self: *const Stream) usize {

        const taken = @atomicLoad(u64, &self.header.taken, .acquire);

        return self.header.capacity - @as(usize, @intCast(self.header.written - taken));

    }

    /// Copies as many whole frames of `samples` as fit, of the stream's encoding's type; returns how many samples it took.
    pub fn write(self: *Stream, comptime Sample: type, samples: []const Sample) usize {

        std.debug.assert(@sizeOf(Sample) == self.format.encoding.size());

        const channels = self.format.channels;
        const count = @min(samples.len / channels, self.room());
        const ring = self.slots(Sample);
        const start: usize = @intCast(self.header.written % self.header.capacity);
        const first = @min(count, self.header.capacity - start);

        @memcpy(ring[start * channels ..][0 .. first * channels], samples[0 .. first * channels]);
        @memcpy(ring[0 .. (count - first) * channels], samples[first * channels ..][0 .. (count - first) * channels]);
        @atomicStore(u64, &self.header.written, self.header.written + count, .release);

        return count * channels;

    }

    /// Writes all of `samples`, waiting for room as the service plays what came before.
    pub fn send(self: *Stream, comptime Sample: type, samples: []const Sample) api.ServiceError!void {

        var done: usize = 0;

        while (true) {

            done += self.write(Sample, samples[done..]);
            if (samples.len - done < self.format.channels) return;

            try self.wait(false);

        }

    }

    /// Waits until half the ring has room, or with `drain` until everything written has played.
    pub fn wait(self: *Stream, drain: bool) api.ServiceError!void {

        while (true) {

            const result = try self.ask(.wait, @as(u56, @intCast(self.id)) | if (drain) draining else 0);

            if (result != protocol.empty) return;

        }

    }

    /// Holds the stream silent where it is, or plays on.
    pub fn pause(self: *Stream, on: bool) void {

        @atomicStore(bool, &self.header.paused, on, .release);

    }

    /// Sets the stream's own volume in percent.
    pub fn loudness(self: *Stream, percent: u8) void {

        @atomicStore(u8, &self.header.volume, @min(percent, 100), .release);

    }

    /// Drops every frame written but not yet played, as before playing from somewhere else.
    pub fn flush(self: *Stream) void {

        @atomicStore(u64, &self.header.discard, self.header.written, .release);

    }

    /// The frame the speakers are playing, counted from the stream's first.
    pub fn position(self: *const Stream) u64 {

        return @atomicLoad(u64, &self.header.played, .acquire);

    }

    pub fn close(self: *Stream) void {

        _ = self.ask(.close, @intCast(self.id)) catch {

        };

        api.detach(self.memory.handle);

    }

    /// The ring's samples, past the header.
    fn slots(self: *Stream, comptime Sample: type) []Sample {

        const bytes = self.memory.bytes[Header.data..][0 .. @as(usize, self.header.capacity) * self.format.frame()];

        return @alignCast(std.mem.bytesAsSlice(Sample, bytes));

    }

    /// Lends the ring to the service, looking it up afresh once if the one known has gone, and starts it playing.
    fn connect(self: *Stream) api.ServiceError!void {

        for (0..2) |_| {

            if (endpoint == 0) endpoint = try api.lookup(0, .audio);

            api.lend(self.memory.handle, endpoint) catch {

                endpoint = 0;
                continue;

            };

            self.id = try request(.connect, @intCast(self.memory.handle), &.{});

            return;

        }

        return error.Missing;

    }

    /// Sends a request about the stream, connecting it again once if the service restarted and forgot it.
    fn ask(self: *Stream, operation: protocol.Operation, value: u56) api.ServiceError!u64 {

        return request(operation, value, &.{}) catch |err| {

            if (err != error.Missing and err != error.Invalid) return err;

            try self.connect();

            return request(operation, value & ~@as(u56, 0xffffffff) | @as(u56, @intCast(self.id)), &.{});

        };

    }

};

fn request(operation: protocol.Operation, value: u56, window: []u8) api.ServiceError!u64 {

    return api.query(&endpoint, .audio, protocol.pack(operation, value), window);

}
