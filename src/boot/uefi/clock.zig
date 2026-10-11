const std = @import("std");

const uefi = std.os.uefi;
const epoch = std.time.epoch;

/// Reads the firmware clock, whose fields are local time; zero when it fails.
pub fn capture(services: *const uefi.tables.RuntimeServices) u64 {

    const time, _ = services.getTime() catch return 0;

    return seconds(time) orelse 0;

}

/// Seconds since 1970-01-01 00:00:00; null for fields that name no moment between 1970 and 9999.
pub fn seconds(time: uefi.Time) ?u64 {

    if (time.year < 1970 or time.year > 9999 or time.month < 1 or time.month > 12 or time.hour > 23 or time.minute > 59 or time.second > 59) return null;
    if (time.day < 1 or time.day > epoch.getDaysInMonth(time.year, @enumFromInt(time.month))) return null;

    var days: u64 = time.day - 1;

    for (1970..time.year) |year| days += epoch.getDaysInYear(@intCast(year));
    for (1..time.month) |month| days += epoch.getDaysInMonth(time.year, @enumFromInt(month));

    return ((days * 24 + time.hour) * 60 + time.minute) * 60 + time.second;

}
