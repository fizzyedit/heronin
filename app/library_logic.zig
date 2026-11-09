const std = @import("std");
const model = @import("model");
const Item = @import("store.zig").Item;
pub const Filter = enum { all, tagged, review, favorites };
pub fn dayLabel(buf: []u8, at: i64, now: i64, tz_offset_s: i32) []const u8 {
    const local = at + tz_offset_s;
    const day = @divFloor(local, 86400);
    const today = @divFloor(now + tz_offset_s, 86400);
    if (day == today) return std.fmt.bufPrint(buf, "Today, {d}:{d:0>2}", .{ @as(u32, @intCast(@divFloor(@mod(local, 86400), 3600))), @as(u32, @intCast(@divFloor(@mod(local, 3600), 60))) }) catch unreachable;
    if (day == today - 1) return "Yesterday";
    const date = std.time.epoch.EpochSeconds{ .secs = @intCast(@mod(local, 146097 * 86400)) };
    const md = date.getEpochDay().calculateYearDay().calculateMonthDay();
    return std.fmt.bufPrint(buf, "{s} {d}", .{ ([_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" })[@backingInt(md.month) - 1], md.day_index + 1 }) catch unreachable;
}
pub fn statusWord(state: model.Photo.State) []const u8 {
    return ([_][]const u8{ "Waiting", "Working", "Tagged", "Review", "Failed", "Other" })[@backingInt(state)];
}
pub fn tileTitle(item: Item) []const u8 {
    return switch (item.photo.state) {
        .tagged => if (item.tags.len > 0) common(item.tags[0]) else "Tagged",
        .review => "Needs a look",
        .skipped => "Not a bird",
        else => statusWord(item.photo.state),
    };
}
pub fn common(tag: model.Tag) []const u8 {
    return if (model.species.find(tag.species)) |s| s.common else tag.species;
}
pub fn matches(item: Item, filter: Filter) bool {
    return switch (filter) {
        .all => true,
        .tagged => item.photo.state == .tagged,
        .review => item.photo.state == .review,
        .favorites => item.photo.favorite,
    };
}
pub fn placeTiles(heights: []const f32, columns: []f32, out: []usize) void {
    for (heights, out) |height, *column| {
        var shortest: usize = 0;
        for (columns, 0..) |value, i| if (value < columns[shortest]) {
            shortest = i;
        };
        column.* = shortest;
        columns[shortest] += height;
    }
}

pub fn placeText(located: ?model.places.Located, saved: []const model.Place) ?[]const u8 {
    const point = located orelse return null;
    return if (model.places.namedPlace(point, saved)) |place| place.name else "Unnamed place";
}
