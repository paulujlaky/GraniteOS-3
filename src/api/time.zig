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

    /// Midnight on `day` of `month` of `year`.
    pub fn on(year: u16, month: u8, day: u8) Date {

        return .{

            .year = year,

            .month = month,
            .day = day,

            .hour = 0,
            .minute = 0,
            .second = 0,

            .weekday = weekday(year, month, day),

        };

    }

    /// The hour on a 12-hour clock, from 1 to 12.
    pub fn twelve(self: Date) u8 {

        return if (self.hour % 12 == 0) 12 else self.hour % 12;

    }

    pub fn half(self: Date) []const u8 {

        return if (self.hour < 12) "AM" else "PM";

    }

    /// The time such as `3:07 PM`, or `3:07:09 PM` with `seconds`.
    pub fn clock(self: Date, out: []u8, seconds: bool) []const u8 {

        if (seconds) return std.fmt.bufPrint(out, "{d}:{d:0>2}:{d:0>2} {s}", .{ self.twelve(), self.minute, self.second, self.half() }) catch "";

        return std.fmt.bufPrint(out, "{d}:{d:0>2} {s}", .{ self.twelve(), self.minute, self.half() }) catch "";

    }

    /// The date such as `Mon, Oct 12`.
    pub fn short(self: Date, out: []u8) []const u8 {

        return std.fmt.bufPrint(out, "{s}, {s} {d}", .{ days[self.weekday][0..3], months[self.month - 1][0..3], self.day }) catch "";

    }

    /// The date such as `Monday, October 12, 2026`, or `Monday, October 12` without the `year`.
    pub fn long(self: Date, out: []u8, year: bool) []const u8 {

        if (!year) return std.fmt.bufPrint(out, "{s}, {s} {d}", .{ days[self.weekday], months[self.month - 1], self.day }) catch "";

        return std.fmt.bufPrint(out, "{s}, {s} {d}, {d}", .{ days[self.weekday], months[self.month - 1], self.day, self.year }) catch "";

    }

};
