const std = @import("std");

const epoch = std.time.epoch;

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
