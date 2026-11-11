const std = @import("std");
const model = @import("model");
const props = @import("drive_props.zig");
const t = std.testing;

test "Drive labels round trip shown tag and guesses independently of favorite" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tags = [_]model.Tag{
        .{
            .species = "norcar",
            .confidence = 0.81234,
            .source = .yours,
            .accepted = .person,
            .at = 123,
            .model = "test-model",
            .box = .{ .x = 0.12345, .y = 0.2, .w = 0.3, .h = 0.4 },
            .detail = "adult",
            .note = "crest",
        },
        .{
            .species = "blujay",
            .confidence = 0.12345,
            .source = .ours,
            .accepted = .auto,
            .at = 123,
            .model = "test-model",
        },
        .{
            .species = "amerob",
            .confidence = 0.06421,
            .source = .person,
            .accepted = .rejected,
            .at = 123,
            .model = "test-model",
        },
    };
    const text = try props.encodeTags(a, &tags, .review);
    const decoded = props.decode(a, text);
    try t.expectEqual(model.Photo.State.review, decoded.state.?);
    try t.expectEqual(tags.len, decoded.tags.len);
    for (tags, decoded.tags) |expected, actual| {
        try t.expectEqualStrings(expected.species, actual.species);
        try t.expectApproxEqAbs(expected.confidence, actual.confidence, 0.0005);
        try t.expectEqual(expected.source, actual.source);
        try t.expectEqual(expected.accepted, actual.accepted);
        try t.expectEqual(expected.at, actual.at);
        try t.expectEqualStrings(expected.model, actual.model);
        try t.expectEqualDeep(expected.detail, actual.detail);
        try t.expectEqualDeep(expected.note, actual.note);
        if (expected.box) |b| {
            const got = actual.box.?;
            try t.expectApproxEqAbs(b.x, got.x, 0.0005);
            try t.expectApproxEqAbs(b.y, got.y, 0.0005);
            try t.expectApproxEqAbs(b.w, got.w, 0.0005);
            try t.expectApproxEqAbs(b.h, got.h, 0.0005);
        } else try t.expect(actual.box == null);
    }
    try t.expect(std.mem.indexOf(u8, text, "\"alt3\":null") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"alt4\":null") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"fav\"") == null);
    const obj = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
    var it = obj.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == .string) {
            try t.expect(entry.value_ptr.string.len <= 124 - entry.key_ptr.len);
        }
    }
}

test "Drive labels empty tags and favorite patches" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try props.encodeTags(a, &.{}, .new);
    try t.expect(std.mem.indexOf(u8, text, "\"sp\":null") != null);
    const empty = props.decode(a, text);
    try t.expectEqual(@as(usize, 0), empty.tags.len);
    try t.expectEqual(model.Photo.State.new, empty.state.?);
    try t.expectEqualStrings("{\"fav\":\"1\"}", props.encodeFavorite(true));
    try t.expectEqualStrings("{\"fav\":null}", props.encodeFavorite(false));
    const favorite = props.decode(a, props.encodeFavorite(true));
    try t.expect(favorite.favorite);
    try t.expectEqual(@as(usize, 0), favorite.tags.len);
    try t.expect(!props.decode(a, props.encodeFavorite(false)).favorite);
}

test "Drive label strings are cut at UTF-8 boundaries" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long_model = try a.alloc(u8, 100);
    @memset(long_model, 'm');
    const pieces = try a.alloc([]const u8, 100);
    @memset(pieces, "é");
    const long_note = try std.mem.join(a, "", pieces);
    const tags = [_]model.Tag{.{
        .species = "norcar",
        .confidence = 0,
        .source = .ours,
        .accepted = .auto,
        .at = 0,
        .model = long_model,
        .note = long_note,
        .detail = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaé",
    }};
    const decoded = props.decode(a, try props.encodeTags(a, &tags, .review));
    try t.expectEqual(@as(usize, 110), decoded.tags[0].note.?.len);
    try t.expect(std.unicode.utf8ValidateSlice(decoded.tags[0].note.?));
    try t.expectEqual(@as(usize, 64), decoded.tags[0].model.len);
    try t.expectEqual(@as(usize, 39), decoded.tags[0].detail.?.len);
}

test "Drive label malformed values default without errors" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "[]" }) |text| {
        const decoded = props.decode(a, text);
        try t.expectEqual(@as(usize, 0), decoded.tags.len);
        try t.expect(decoded.state == null);
        try t.expect(!decoded.favorite);
    }
    const decoded = props.decode(a, "{\"sp\":\"norcar\",\"cf\":\"x\",\"alt1\":\"bad\"}");
    try t.expectEqual(@as(usize, 1), decoded.tags.len);
    try t.expectEqualStrings("norcar", decoded.tags[0].species);
    try t.expectEqual(@as(f32, 0), decoded.tags[0].confidence);
    try t.expectEqual(model.Tag.Source.ours, decoded.tags[0].source);
    try t.expectEqual(model.Tag.Accepted.auto, decoded.tags[0].accepted);
    try t.expectEqual(@as(i64, 0), decoded.tags[0].at);
    try t.expectEqualStrings("", decoded.tags[0].model);
}
