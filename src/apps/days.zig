//! Calendar days: moving between them, ISO week numbers, and US federal holidays, shared by Calendar and the quick settings.

const std = @import("std");

const api = @import("api");

const time = api.time;

pub const Day = struct {

    year: u16,
    month: u8,
    day: u8,

    pub fn today() Day {

        const date = api.Date.init(api.clock());

        return .{

            .year = date.year,
            .month = date.month,
            .day = date.day,

        };

    }

    /// Days since Monday.
    pub fn weekday(self: Day) u8 {

        return (time.weekday(self.year, self.month, self.day) + 6) % 7;

    }

    /// The day `count` days later, or earlier when negative.
    pub fn add(self: Day, count: i32) Day {

        var result = self;
        var left = count;

        while (left > 0) : (left -= 1) {

            result.day += 1;
            if (result.day <= time.length(result.year, result.month)) continue;

            result.day = 1;
            result = result.shift(1);

        }

        while (left < 0) : (left += 1) {

            if (result.day > 1) {

                result.day -= 1;
                continue;

            }

            result = result.shift(-1);
            result.day = time.length(result.year, result.month);

        }

        return result;

    }

    /// The same day `count` months later, or earlier, kept within the month.
    pub fn shift(self: Day, count: i32) Day {

        const months = @as(i32, self.year) * 12 + self.month - 1 + count;
        const year: u16 = @intCast(std.math.clamp(@divFloor(months, 12), 1970, 9999));
        const month: u8 = @intCast(@mod(months, 12) + 1);

        return .{

            .year = year,
            .month = month,
            .day = @min(self.day, time.length(year, month)),

        };

    }

    /// Days since the start of the year, counting from 1.
    pub fn ordinal(self: Day) u16 {

        var total: u16 = self.day;

        for (1..self.month) |month| total += time.length(self.year, @intCast(month));

        return total;

    }

    /// The ISO 8601 week: weeks start on Monday, and the first holds the year's first Thursday.
    pub fn week(self: Day) u8 {

        const number = @divFloor(@as(i32, self.ordinal()) - self.weekday() + 9, 7);

        if (number < 1) return weeks(self.year - 1);
        if (number > weeks(self.year)) return 1;

        return @intCast(number);

    }

    pub fn same(self: Day, other: Day) bool {

        return std.meta.eql(self, other);

    }

};

/// Weeks in ISO year `year`: 53 when it starts on a Thursday, or on a Wednesday in a leap year.
fn weeks(year: u16) u8 {

    const first = (time.weekday(year, 1, 1) + 6) % 7;
    const leap = time.length(year, 2) == 29;

    return if (first == 3 or (first == 2 and leap)) 53 else 52;

}

/// The US federal holiday on `day`, if any.
pub fn holiday(day: Day) ?[]const u8 {

    const nth = (day.day - 1) / 7 + 1;
    const last = day.day + 7 > time.length(day.year, day.month);
    const weekday = day.weekday();

    return switch (day.month) {

        1 => if (day.day == 1) "New Year's Day" else if (weekday == 0 and nth == 3) "Martin Luther King Jr. Day" else null,
        2 => if (weekday == 0 and nth == 3) "Washington's Birthday" else null,
        5 => if (weekday == 0 and last) "Memorial Day" else null,
        6 => if (day.day == 19) "Juneteenth" else null,
        7 => if (day.day == 4) "Independence Day" else null,
        9 => if (weekday == 0 and nth == 1) "Labor Day" else null,
        10 => if (weekday == 0 and nth == 2) "Columbus Day" else null,
        11 => if (day.day == 11) "Veterans Day" else if (weekday == 3 and nth == 4) "Thanksgiving Day" else null,
        12 => if (day.day == 25) "Christmas Day" else null,
        else => null,

    };

}

/// "1" to "53", for days and weeks.
pub const numerals = blk: {

    var list: [54][]const u8 = undefined;

    @setEvalBranchQuota(20000);
    for (&list, 0..) |*entry, number| entry.* = std.fmt.comptimePrint("{d}", .{number});

    break :blk list;

};
