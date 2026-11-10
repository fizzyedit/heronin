const std = @import("std");
const testing = std.testing;
const model = @import("model");
const api = @import("store.zig");
const tags = @import("tag_queue.zig");
const FakeStore = @import("fake_store.zig").FakeStore;
var calls: usize = 0;
var last: tags.wire.Request = undefined;
var fail = false;
var image_copy: [64]u8 = undefined;
const guesses = [_]model.Tag{
    .{ .species = "norcar", .confidence = 0.7, .source = .ours, .accepted = .auto, .at = 1, .model = "fake", .box = .{ .x = 0.2, .y = 0.3, .w = 0.4, .h = 0.5 }, .detail = "adult", .note = "Matched crest" },
    .{ .species = "blujay", .confidence = 0.2, .source = .ours, .accepted = .auto, .at = 1, .model = "fake" },
};
fn post(q: *tags.TagQueue, request: tags.wire.Request) void {
    calls += 1;
    last = request;
    if (request.image.len <= image_copy.len) {
        @memcpy(image_copy[0..request.image.len], request.image);
        last.image = image_copy[0..request.image.len];
    }
    if (fail) return q.answer(error.Io);
    const reply = q.arena.allocator().dupe(model.Tag, &guesses) catch unreachable;
    for (reply) |*tag| {
        tag.species = q.arena.allocator().dupe(u8, tag.species) catch unreachable;
        tag.model = q.arena.allocator().dupe(u8, tag.model) catch unreachable;
        if (tag.detail) |s| tag.detail = q.arena.allocator().dupe(u8, s) catch unreachable;
        if (tag.note) |s| tag.note = q.arena.allocator().dupe(u8, s) catch unreachable;
    }
    q.answer(.{ .state = .review, .tags = reply });
}
fn hold(_: *tags.TagQueue, request: tags.wire.Request) void {
    calls += 1;
    last = request;
    if (request.image.len <= image_copy.len) {
        @memcpy(image_copy[0..request.image.len], request.image);
        last.image = image_copy[0..request.image.len];
    }
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
    q.items = try testing.allocator.dupe(api.Item, f.items);
    defer testing.allocator.free(q.items);
    const first: usize = if (std.mem.lessThan(u8, f.items[2].photo.id, f.items[3].photo.id)) 2 else 3;
    const second: usize = if (first == 2) 3 else 2;
    try testing.expectEqualStrings(f.items[first].photo.id, q.next(q.items).?);
    q.step(f.store(), hold);
    try testing.expectEqual(model.Photo.State.tagging, q.items[first].photo.state);
    try testing.expectEqual(model.Photo.State.new, f.items[first].photo.state);
    f.store().pump();
    q.step(f.store(), hold);
    try testing.expectEqual(@as(usize, 1), calls);
    q.answer(.{ .state = .review, .tags = &guesses });
    f.store().pump();
    try testing.expectEqualStrings(f.items[second].photo.id, q.next(q.items).?);
    tick(&q, &f);
    try testing.expectEqualStrings(f.items[1].photo.id, q.next(q.items).?);
    tick(&q, &f);
    const undated_first: usize = if (std.mem.lessThan(u8, f.items[0].photo.id, f.items[4].photo.id)) 0 else 4;
    const undated_second: usize = if (undated_first == 0) 4 else 0;
    try testing.expectEqualStrings(f.items[undated_first].photo.id, q.next(q.items).?);
    tick(&q, &f);
    try testing.expectEqualStrings(f.items[undated_second].photo.id, q.next(q.items).?);
    tick(&q, &f);
    try testing.expect(q.next(q.items) == null);
}
test "Tag this alone with auto off; review preserves both tags and metadata" {
    var f = try FakeStore.init(testing.allocator);
    defer f.deinit();
    reset(&f);
    f.items[0].photo.state = .new;
    f.items[1].photo.state = .failed;
    const settings: tags.Settings = .{};
    const items = try testing.allocator.dupe(api.Item, f.items);
    defer testing.allocator.free(items);
    var q: tags.TagQueue = .{ .settings = &settings, .items = items };
    q.ask(f.items[1].photo.id);
    defer q.deinit();
    tick(&q, &f);
    try testing.expectEqual(@as(usize, 1), calls);
    try testing.expectEqual(model.Photo.State.review, f.items[1].photo.state);
    try testing.expectEqualDeep(@as([]const model.Tag, &guesses), f.items[1].tags);
    try testing.expectEqualDeep(@as([]const model.Tag, &guesses), items[1].tags);
    try testing.expectEqual(@as(usize, 0), q.arena.queryCapacity());
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
    q.ask(f.items[0].photo.id);
    tick(&q, &f);
    try testing.expectEqual(model.Photo.State.new, f.items[0].photo.state);
    fail = false;
    tick(&q, &f);
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
    const default = try tags.serverUrl(testing.allocator, null, "tag");
    defer testing.allocator.free(default);
    const override = try tags.serverUrl(testing.allocator, "http://localhost:9000/", "tag");
    defer testing.allocator.free(override);
    const a = try std.Uri.parse(default);
    const b = try std.Uri.parse(override);
    try testing.expectEqualStrings("127.0.0.1", a.host.?.percent_encoded);
    try testing.expectEqual(@as(?u16, 8790), a.port);
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
test "asked id survives caller reuse and job memory is freed after saving" {
    var f = try FakeStore.init(testing.allocator);
    defer f.deinit();
    reset(&f);
    const id = try testing.allocator.dupe(u8, f.items[0].photo.id);
    defer testing.allocator.free(id);
    const settings: tags.Settings = .{};
    var q: tags.TagQueue = .{ .settings = &settings, .items = f.items };
    defer q.deinit();
    q.ask(id);
    @memset(id, 'x');
    fail = true;
    tick(&q, &f);
    try testing.expectEqualStrings(f.items[0].photo.id, q.next(f.items).?);
    try testing.expectEqual(@as(usize, 0), q.arena.queryCapacity());
    fail = false;
    tick(&q, &f);
    try testing.expect(q.asked == null);
    try testing.expectEqual(@as(usize, 0), q.arena.queryCapacity());
    try testing.expectEqualDeep(@as([]const model.Tag, &guesses), q.items[0].tags);
}
test "import during auto tagging reaches Library between jobs" {
    var ui = try @import("dvui").testing.init(.{});
    defer ui.deinit();
    var f = try FakeStore.init(testing.allocator);
    defer f.deinit();
    reset(&f);
    f.items[0].photo.state = .new;
    f.items[1].photo.state = .new;
    var state: @import("views/library.zig").State = .{};
    defer state.arena.deinit();
    const store = f.store();
    store.list(null, 60, &state, @import("views/library.zig").State.listed);
    store.pump();
    const settings: tags.Settings = .{ .auto = true };
    var q: tags.TagQueue = .{ .settings = &settings, .items = state.items, .tags_allocator = state.arena.allocator() };
    defer q.deinit();
    q.step(store, hold);
    store.pump();
    store.importFile("new-import.jpg", "new import bytes", &state, struct {
        fn imported(ctx: ?*anyopaque, result: api.Error!api.Imported) void {
            _ = result catch unreachable;
            const s: *@import("views/library.zig").State = @ptrCast(@alignCast(ctx.?));
            s.stale = true;
        }
    }.imported);
    store.pump();
    try testing.expect(state.stale);
    try testing.expect(!state.reloadBetweenJobs(store, q.busy != null, true));
    q.answer(.{ .state = .review, .tags = &guesses });
    store.pump();
    try testing.expect(q.busy == null);
    try testing.expect(q.next(state.items) != null);
    try testing.expect(state.reloadBetweenJobs(store, q.busy != null, true));
    q.items = state.items;
    store.pump();
    try testing.expectEqualStrings("new-import.jpg", state.items[0].photo.name);
    try testing.expectEqual(model.Photo.State.new, state.items[0].photo.state);
    q.items = state.items;
    q.tags_allocator = state.arena.allocator();
    try testing.expect(q.next(state.items) != null);
}
