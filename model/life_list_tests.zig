const std = @import("std");
const m = @import("model");
const life = m.life_list;
const expect = std.testing.expect;
fn photo(id: []const u8, at: ?i64) m.Photo {
    return .{ .id = id, .name = id, .md5 = .{ .bytes = @splat(0) }, .w = 1, .h = 1, .bytes = 1, .taken_at = at, .place = .{ .lat = 0, .lon = 0 }, .state = .tagged };
}
fn tag(code: []const u8, confidence: f32) m.Tag {
    return .{ .species = code, .confidence = confidence, .accepted = .auto, .source = .ours, .at = 0, .model = "fake" };
}
test "life list counts accepted known primary tags and orders first, best and missing species" {
    var photos = [_]m.Photo{ photo("b", 100), photo("a", 200), photo("c", null), photo("d", 50), photo("e", 0), photo("f", 0) };
    var ts = [_][1]m.Tag{ .{tag("grbher3", 0.8)}, .{tag("grbher3", 0.9)}, .{tag("grbher3", 0.9)}, .{tag("greegr", 1)}, .{tag("blujay", 1)}, .{tag("unknown", 1)} };
    var tags: [6][]const m.Tag = undefined;
    for (&ts, &tags) |*t, *out| out.* = t;
    photos[4].state = .review;
    ts[3][0].accepted = .rejected;
    ts[1][0].accepted = .person;
    const entries = try life.build(std.testing.allocator, &photos, &tags);
    defer std.testing.allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(@as(u32, 3), entries[0].count);
    try std.testing.expectEqualStrings("b", entries[0].first);
    try std.testing.expectEqualStrings("a", entries[0].best);
    var missing: [12]m.Species = undefined;
    const rest = life.notYet(entries, &missing);
    for (rest, 1..) |s, i| try std.testing.expectEqualStrings(m.species.table[i].code, s.code);
    try expect(life.counted(photos[0], &.{}) == null);
    ts[3][0].accepted = .auto;
    const with_egret = try life.build(std.testing.allocator, &photos, &tags);
    defer std.testing.allocator.free(with_egret);
    try std.testing.expectEqual(@as(usize, 2), with_egret.len);
    try std.testing.expectEqualStrings("grbher3", with_egret[0].species.code);
    try std.testing.expectEqualStrings("greegr", with_egret[1].species.code);
    ts[3][0].accepted = .rejected;
    ts[0][0].accepted = .rejected;
    photos[1].state = .review;
    photos[2].state = .review;
    const empty = try life.build(std.testing.allocator, &photos, &tags);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 12), life.notYet(empty, &missing).len);
    photos[0] = photo("b", null);
    photos[1] = photo("a", null);
    ts[0][0].accepted = .auto;
    const nulls = try life.build(std.testing.allocator, &photos, &tags);
    defer std.testing.allocator.free(nulls);
    try std.testing.expectEqualStrings("a", nulls[0].first);
    try expect(nulls[0].first_at == null);
    photos[0].taken_at = 200;
    photos[1].taken_at = 200;
    ts[0][0].confidence = 0.9;
    const ties = try life.build(std.testing.allocator, &photos, &tags);
    defer std.testing.allocator.free(ties);
    try std.testing.expectEqualStrings("a", ties[0].first);
    try std.testing.expectEqualStrings("a", ties[0].best);
}
test "new week includes its boundary, excludes future dates and sorts newest with table ties" {
    var entries = [_]life.Entry{
        .{ .species = m.species.table[0], .first_at = 100, .first = "a", .best = "a", .count = 1 },
        .{ .species = m.species.table[1], .first_at = 200, .first = "b", .best = "b", .count = 1 },
        .{ .species = m.species.table[2], .first_at = 200, .first = "c", .best = "c", .count = 1 },
    };
    var buf: [12]usize = undefined;
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 0 }, life.newThisWeek(&entries, 100 + 7 * 86400, &buf));
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, life.newThisWeek(&entries, 101 + 7 * 86400, &buf));
    try std.testing.expectEqualSlices(usize, &.{0}, life.newThisWeek(&entries, 100, &buf));
    entries[0].first_at = null;
    try expect(life.newThisWeek(&entries, 100, &buf).len == 0);
}
test "species name matching uses ASCII word prefixes" {
    for ([_][]const u8{ "great blue", "blue", " BLUE ", "" }) |q| try expect(m.species.matches("Great Blue Heron", q));
    try expect(m.species.matches("Red-winged Blackbird", "winged"));
    try expect(m.species.matches("Ardea alba", "ardea"));
    try expect(!m.species.matches("Great Blue Heron", "eron"));
}
