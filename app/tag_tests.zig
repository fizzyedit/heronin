const std = @import("std");
const testing = std.testing;
const model = @import("model");
const api = @import("store.zig");
const tags = @import("tag_queue.zig");
const FakeStore = @import("fake_store.zig").FakeStore;
var calls: usize = 0;
var last: tags.wire.Request = undefined;
var fail = false;
const guesses = [_]model.Tag{
    .{ .species = "norcar", .confidence = 0.7, .source = .ours, .accepted = .auto, .at = 1, .model = "fake", .box = .{ .x = 0.2, .y = 0.3, .w = 0.4, .h = 0.5 }, .detail = "adult", .note = "Matched crest" },
    .{ .species = "blujay", .confidence = 0.2, .source = .ours, .accepted = .auto, .at = 1, .model = "fake" },
};
fn post(q: *tags.TagQueue, request: tags.wire.Request) void {
    calls += 1;
    last = request;
    if (fail) q.answer(error.Io) else q.answer(.{ .state = .review, .tags = &guesses });
}
fn hold(_: *tags.TagQueue, request: tags.wire.Request) void {
    calls += 1;
    last = request;
}
fn reset(f: *FakeStore) void {
    calls = 0;
    fail = false;
    for (f.items) |*item| item.photo.state = .skipped;
}
fn tick(q: *tags.TagQueue, f: *FakeStore) void {
    q.step(f.store(), post);
    f.store().pump();
    f.store().pump();
}
test "auto off sends nothing" {
    var f = try FakeStore.init(testing.allocator);
    defer f.deinit();
    reset(&f);
    f.items[0].photo.state = .new;
    const settings: tags.Settings = .{};
    var q: tags.TagQueue = .{ .settings = &settings, .items = f.items };
    defer q.deinit();
    tick(&q, &f);
    try testing.expectEqual(@as(usize, 0), calls);
}
test "oldest dated first then id with undated last; one at a time" {
    var f = try FakeStore.init(testing.allocator);
    defer f.deinit();
    reset(&f);
    for (f.items[0..5]) |*item| item.photo.state = .new;
    f.items[0].photo.taken_at = null;
    f.items[4].photo.taken_at = null;
    f.items[1].photo.taken_at = 20;
    f.items[2].photo.taken_at = 10;
    f.items[3].photo.taken_at = 10;
    const settings: tags.Settings = .{ .auto = true };
    var q: tags.TagQueue = .{ .settings = &settings, .items = f.items };
    defer q.deinit();
    const first: usize = if (std.mem.lessThan(u8, f.items[2].photo.id, f.items[3].photo.id)) 2 else 3;
    const second: usize = if (first == 2) 3 else 2;
    try testing.expectEqualStrings(f.items[first].photo.id, q.next(f.items).?);
    q.step(f.store(), hold);
    try testing.expectEqual(model.Photo.State.tagging, f.items[first].photo.state);
    f.store().pump();
    q.step(f.store(), hold);
    try testing.expectEqual(@as(usize, 1), calls);
    q.answer(.{ .state = .review, .tags = &guesses });
    f.store().pump();
    try testing.expectEqualStrings(f.items[second].photo.id, q.next(f.items).?);
    tick(&q, &f);
    try testing.expectEqualStrings(f.items[1].photo.id, q.next(f.items).?);
    tick(&q, &f);
    const undated_first: usize = if (std.mem.lessThan(u8, f.items[0].photo.id, f.items[4].photo.id)) 0 else 4;
    const undated_second: usize = if (undated_first == 0) 4 else 0;
    try testing.expectEqualStrings(f.items[undated_first].photo.id, q.next(f.items).?);
    tick(&q, &f);
    try testing.expectEqualStrings(f.items[undated_second].photo.id, q.next(f.items).?);
    tick(&q, &f);
    try testing.expect(q.next(f.items) == null);
}
test "Tag this alone with auto off; review preserves both tags and metadata" {
    var f = try FakeStore.init(testing.allocator);
    defer f.deinit();
    reset(&f);
    f.items[0].photo.state = .new;
    f.items[1].photo.state = .failed;
    const settings: tags.Settings = .{};
    var q: tags.TagQueue = .{ .settings = &settings, .items = f.items, .asked = f.items[1].photo.id };
    defer q.deinit();
    tick(&q, &f);
    try testing.expectEqual(@as(usize, 1), calls);
    try testing.expectEqual(model.Photo.State.review, f.items[1].photo.state);
    try testing.expectEqualDeep(@as([]const model.Tag, &guesses), f.items[1].tags);
    try testing.expectEqualStrings("", last.image);
    try testing.expect(last.auto_accept);
    tick(&q, &f);
    try testing.expectEqual(@as(usize, 1), calls);
}
test "third failure fails photo and continues with next" {
    var f = try FakeStore.init(testing.allocator);
    defer f.deinit();
    reset(&f);
    f.items[0].photo.state = .new;
    f.items[0].photo.taken_at = 1;
    f.items[1].photo.state = .new;
    f.items[1].photo.taken_at = 2;
    const settings: tags.Settings = .{ .auto = true };
    var q: tags.TagQueue = .{ .settings = &settings, .items = f.items };
    defer q.deinit();
    fail = true;
    for (0..3) |_| tick(&q, &f);
    try testing.expectEqual(model.Photo.State.failed, f.items[0].photo.state);
    try testing.expectEqual(@as(usize, 0), f.items[0].tags.len);
    fail = false;
    tick(&q, &f);
    try testing.expectEqual(model.Photo.State.review, f.items[1].photo.state);
}
test "place is optional and rounded; ask below off requests review" {
    var f = try FakeStore.init(testing.allocator);
    defer f.deinit();
    reset(&f);
    f.items[0].photo.place = .{ .lat = 60.126, .lon = -29.874 };
    var settings: tags.Settings = .{ .use_place = false, .ask_below = false };
    var q: tags.TagQueue = .{ .settings = &settings, .items = f.items, .asked = f.items[0].photo.id };
    defer q.deinit();
    tick(&q, &f);
    try testing.expect(last.place == null);
    try testing.expect(!last.auto_accept);
    settings.use_place = true;
    q.asked = f.items[0].photo.id;
    tick(&q, &f);
    try testing.expectEqual(@as(f64, 60.13), last.place.?.lat);
    try testing.expectEqual(@as(f64, -29.87), last.place.?.lon);
}
test "native default and override form transport URLs" {
    const default = try tags.endpoint(testing.allocator, null);
    defer testing.allocator.free(default);
    const override = try tags.endpoint(testing.allocator, "http://localhost:9000/");
    defer testing.allocator.free(override);
    const a = try std.Uri.parse(default);
    const b = try std.Uri.parse(override);
    try testing.expectEqualStrings("127.0.0.1", a.host.?.percent_encoded);
    try testing.expectEqual(@as(?u16, 8787), a.port);
    try testing.expectEqualStrings("localhost", b.host.?.percent_encoded);
    try testing.expectEqual(@as(?u16, 9000), b.port);
    try testing.expectEqualStrings("/heronin/api/tag", b.path.percent_encoded);
}
test "encoded thumbnail bytes are base64 in the request" {
    var f = try FakeStore.init(testing.allocator);
    defer f.deinit();
    reset(&f);
    const settings: tags.Settings = .{};
    var q: tags.TagQueue = .{ .settings = &settings, .items = f.items, .asked = f.items[0].photo.id };
    defer q.deinit();
    const original = f.store();
    var vtable = original.vtable.*;
    vtable.thumbnail = struct {
        fn thumbnail(_: *anyopaque, _: []const u8, px: u32, ctx: ?*anyopaque, done: api.Done(api.Thumbnail)) void {
            testing.expectEqual(@as(u32, 1024), px) catch unreachable;
            done(ctx, .{ .encoded = "preview" });
        }
    }.thumbnail;
    const store: api.Store = .{ .ptr = original.ptr, .vtable = &vtable };
    q.step(store, post);
    f.store().pump();
    try testing.expectEqualStrings("cHJldmlldw==", last.image);
}
