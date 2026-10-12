const std = @import("std");

const epoch = std.time.epoch;

/// Weekday names from Sunday, and month names from January; slice `[0..3]` for short forms.
pub const days = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
pub const months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

/// Days in `month`, counted from 1, of `year`.
pub fn length(year: u16, month: u8) u8 {

    return epoch.getDaysInMonth(year, @enumFromInt(month));

}

/// Days since Sunday of the given date, by Sakamoto's method.
pub fn weekday(year: u16, month: u8, day: u8) u8 {

    const offsets = [_]u16{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    const y = if (month < 3) year - 1 else year;

    return @intCast((y + y / 4 - y / 100 + y / 400 + offsets[month - 1] + day) % 7);

}

/// Calendar fields of a moment given in seconds since 1970-01-01 00:00:00.
pub const Date = struct {

    year: u16,

    /// Both count from 1.
    month: u8,
    day: u8,

    hour: u8,
    minute: u8,
    second: u8,

    /// Days since Sunday.
    weekday: u8,

    pub fn init(seconds: u64) Date {

        const moment = epoch.EpochSeconds{

            .secs = seconds,

        };

        const day = moment.getEpochDay();
        const year = day.calculateYearDay();
        const date = year.calculateMonthDay();
        const time = moment.getDaySeconds();

        return .{

            .year = year.year,

            .month = date.month.numeric(),
            .day = @as(u8, date.day_index) + 1,

            .hour = time.getHoursIntoDay(),
            .minute = time.getMinutesIntoHour(),
            .second = time.getSecondsIntoMinute(),

            // 1970-01-01 was a Thursday.
            .weekday = @intCast((day.day + 4) % 7),

        };

    }

};
