const std = @import("std");
const logic = @import("library_logic.zig");
const FakeStore = @import("fake_store.zig").FakeStore;
const expectEqualStrings = std.testing.expectEqualStrings;
test "local day labels and midnight boundaries" {
    var buf: [40]u8 = undefined;
    // 2026-11-09 07:42 UTC; local offset +02:00 in the midnight cases.
    const today: i64 = 1794210120;
    try expectEqualStrings("Today, 7:42", logic.dayLabel(&buf, today, today, 0));
    try expectEqualStrings("Yesterday", logic.dayLabel(&buf, today - 86400, today, 0));
    try expectEqualStrings("Oct 30", logic.dayLabel(&buf, today - 10 * 86400, today, 0));
    try expectEqualStrings("Dec 30", logic.dayLabel(&buf, -86401, 0, 0));
    const midnight = @divFloor(today + 7200, 86400) * 86400 - 7200;
    try expectEqualStrings("Yesterday", logic.dayLabel(&buf, midnight - 300, midnight + 600, 7200));
    try expectEqualStrings("Today, 0:05", logic.dayLabel(&buf, midnight + 300, midnight + 600, 7200));
}
test "all status words" {
    inline for (.{ .new, .tagging, .tagged, .review, .failed, .skipped }, .{ "Waiting", "Working", "Tagged", "Review", "Failed", "Other" }) |state, word| try expectEqualStrings(word, logic.statusWord(state));
}
test "fixture titles and filter counts" {
    var fake = try FakeStore.init(std.testing.allocator);
    defer fake.deinit();
    var counts: [4]usize = @splat(0);
    for (fake.items) |item| {
        inline for (.{ .all, .tagged, .review, .favorites }, 0..) |filter, i| {
            if (logic.matches(item, filter)) counts[i] += 1;
        }
        switch (item.photo.state) {
            .tagged => try expectEqualStrings(@import("model").species.find(item.tags[0].species).?.common, logic.tileTitle(item)),
            .review => try expectEqualStrings("Needs a look", logic.tileTitle(item)),
            .skipped => try expectEqualStrings("Not a bird", logic.tileTitle(item)),
            else => {},
        }
    }
    try std.testing.expectEqualSlices(usize, &.{ 60, 10, 10, 12 }, &counts);
}
test "shortest column and leftmost ties" {
    var columns = [_]f32{ 0, 0 };
    var out: [5]usize = undefined;
    logic.placeTiles(&.{ 3, 1, 1, 1, 2 }, &columns, &out);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 1, 1, 0 }, &out);
    columns = .{ 0, 0 };
    logic.placeTiles(&.{ 2, 2, 2, 2 }, &columns, out[0..4]);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 0, 1 }, out[0..4]);
}
