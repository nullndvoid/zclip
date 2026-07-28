// Copyright 2024, Dylibso, Inc. 2026, nullndvoid
//
// Redistribution and use in source and binary forms, with or without modification,
// are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice, this
//    list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// 3. Neither the name of the copyright holder nor the names of its contributors
//    may be used to endorse or promote products derived from this software without
//    specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
// ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
// ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
// ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

//! Represents a date and time with timezone offset
//!
//! This code was originally taken from https://github.com/dylibso/datetime-zig/
//! and adapted for my use case.
//!
//! I will paste the LICENSE in the header.

const std = @import("std");
const Io = std.Io;

const DateTime = @This();

/// Calendar year (e.g., 2023)
year: u16,
/// Month of the year (1-12)
month: u8,
/// Day of the month (1-31)
day: u8,
/// Hour of the day (0-23)
hour: u8,
/// Minute of the hour (0-59)
minute: u8,
/// Second of the minute (0-60, allowing for leap seconds)
second: u8,
/// Milliseconds (0-999)
millisecond: u16,
/// Timezone offset in minutes from UTC
offset: i16,

fn getOffsetSign(offset: i16) u8 {
    return if (offset < 0) '-' else '+';
}

/// Creates a DateTime from Unix timestamp in milliseconds
/// Note: This function assumes UTC (offset 0)
// largely constructed from https://www.aolium.com/karlseguin/cf03dee6-90e1-85ac-8442-cf9e6c11602a
pub fn fromMillis(ms: i64) DateTime {
    const ts: u64 = @intCast(@divTrunc(ms, 1000));
    const SECONDS_PER_DAY = std.time.s_per_day;
    const DAYS_PER_YEAR = 365;
    const DAYS_IN_4YEARS = 1461;
    const DAYS_IN_100YEARS = 36524;
    const DAYS_IN_400YEARS = 146097;
    const DAYS_BEFORE_EPOCH = 719468;

    const seconds_since_midnight: u64 = @rem(ts, SECONDS_PER_DAY);
    var day_n: u64 = DAYS_BEFORE_EPOCH + ts / SECONDS_PER_DAY;
    var temp: u64 = 0;

    temp = 4 * (day_n + DAYS_IN_100YEARS + 1) / DAYS_IN_400YEARS - 1;
    var year: u16 = @intCast(100 * temp);
    day_n -= DAYS_IN_100YEARS * temp + temp / 4;

    temp = 4 * (day_n + DAYS_PER_YEAR + 1) / DAYS_IN_4YEARS - 1;
    year += @intCast(temp);
    day_n -= DAYS_PER_YEAR * temp + temp / 4;

    var month: u8 = @intCast((5 * day_n + 2) / 153);
    const day: u8 = @intCast(day_n - (@as(u64, @intCast(month)) * 153 + 2) / 5 + 1);

    month += 3;
    if (month > 12) {
        month -= 12;
        year += 1;
    }

    return DateTime{ .year = year, .month = month, .day = day, .hour = @intCast(seconds_since_midnight / 3600), .minute = @intCast(seconds_since_midnight % 3600 / 60), .second = @intCast(seconds_since_midnight % 60), .millisecond = @intCast(@rem(ms, 1000)), .offset = 0 };
}

/// Converts the DateTime to an RFC 3339 formatted string
/// Returns an allocated string that must be freed by the caller
pub fn format(self: DateTime, writer: *Io.Writer) Io.Writer.Error!void {
    // Write the date and time components
    try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        self.year,        self.month,  self.day,
        self.hour,        self.minute, self.second,
        self.millisecond,
    });

    // Write the timezone offset
    if (self.offset == 0) {
        _ = try writer.write("Z");
    } else {
        const abs_offset = @abs(self.offset);
        const offset_hours = @divFloor(abs_offset, 60);
        const offset_minutes = @mod(abs_offset, 60);
        try writer.print("{c}{d:0>2}:{d:0>2}", .{
            getOffsetSign(self.offset),
            offset_hours,
            offset_minutes,
        });
    }
}
