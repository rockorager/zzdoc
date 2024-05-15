const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const s_per_day = std.time.s_per_day;
const days_per_era = 365 * 400 + 97;

pub fn now() Date {
    const ts = std.time.timestamp();
    const days = daysSinceEpoch(ts);
    return civilFromDays(days);
}

pub const Date = struct {
    year: i32,
    month: Month,
    day: u5, // 1-31
};

pub const Month = enum(u4) {
    jan = 1,
    feb,
    mar,
    apr,
    may,
    jun,
    jul,
    aug,
    sep,
    oct,
    nov,
    dec,
};

pub fn daysSinceEpoch(timestamp: i64) i64 {
    return @divTrunc(timestamp, s_per_day);
}

/// return the civil date from the number of days since the epoch
/// This is an implementation of Howard Hinnant's algorithm
/// https://howardhinnant.github.io/date_algorithms.html#civil_from_days
pub fn civilFromDays(days: i64) Date {
    // shift epoch from 1970-01-01 to 0000-03-01
    const z = days + 719468;

    // Compute era
    const era = if (z >= 0)
        @divFloor(z, days_per_era)
    else
        @divFloor(z - days_per_era - 1, days_per_era);

    const doe: u32 = @intCast(z - era * days_per_era); // [0, days_per_era-1]
    const yoe: u32 = @intCast(
        @divFloor(
            doe -
                @divFloor(doe, 1460) +
                @divFloor(doe, 36524) -
                @divFloor(doe, 146096),
            365,
        ),
    ); // [0, 399]
    const y: i32 = @intCast(yoe + era * 400);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0, 365]
    const mp = @divFloor(5 * doy + 2, 153); // [0, 11]
    const d = doy - @divFloor(153 * mp + 2, 5) + 1; // [1, 31]
    const m = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    return .{
        .year = if (m <= 2) y + 1 else y,
        .month = @enumFromInt(m),
        .day = @truncate(d),
    };
}
