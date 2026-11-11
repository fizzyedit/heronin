const std = @import("std");
const vfs = @import("core").vfs;
const model = @import("model");
const api = @import("store.zig");
const DriveStore = @import("drive_store.zig").DriveStore;
const t = std.testing;
var now: i64 = 1794355200;
fn clock() i64 {
    return now;
}
fn Sink(comptime T: type) type {
    return struct {
        result: ?api.Error!T = null,
        fn done(ctx: ?*anyopaque, result: api.Error!T) void {
            const s: *@This() = @ptrCast(@alignCast(ctx.?));
            s.result = result;
        }
        fn get(s: *@This(), store: api.Store) !T {
            for (0..100) |_| {
                if (s.result) |r| return r;
                store.pump();
            }
            return error.Timeout;
        }
    };
}
fn wrote(_: ?*anyopaque, result: vfs.Result(void)) void {
    result.get() catch @panic("fixture write failed");
}
fn write(mem: *vfs.Mem, path: []const u8, bytes: []const u8) !void {
    _ = try mem.fs().writeFile(path, bytes, .{}, wrote, null);
    mem.fs().pump();
}
fn listing(s: api.Store, after: ?[]const u8, limit: u32) ![]const api.Item {
    var sink: Sink([]const api.Item) = .{};
    s.list(after, limit, &sink, @TypeOf(sink).done);
    try t.expect(sink.result == null);
    return sink.get(s);
}
fn import(s: api.Store, bytes: []const u8) !api.Imported {
    var sink: Sink(api.Imported) = .{};
    s.importFile("IMG_0001.jpg", bytes, &sink, @TypeOf(sink).done);
    return sink.get(s);
}
fn places(s: api.Store) ![]const model.Place {
    var sink: Sink([]const model.Place) = .{};
    s.places(&sink, @TypeOf(sink).done);
    return sink.get(s);
}
fn save(s: api.Store, values: []const model.Place) ![]const model.Place {
    var sink: Sink([]const model.Place) = .{};
    s.savePlaces(values, &sink, @TypeOf(sink).done);
    return sink.get(s);
}
test "Drive folder lists only images, sorts by time then id, and pages" {
    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    try mem.putDir("/Heronin");
    try mem.putDir("/Heronin/2025");
    try mem.putDir("/Heronin/misc");
    try mem.put("/Heronin/IMG_0002.jpg", "ab");
    try mem.put("/Heronin/2025/IMG_0001.JPG", "a");
    try mem.put("/Heronin/2025/notes.txt", "note");
    try mem.put("/Heronin/misc/IMG_0003.png", "ignored");
    var drive = try DriveStore.init(t.allocator, mem.fs(), "/Heronin", clock);
    defer drive.deinit();
    const s = drive.store();
    const first = try listing(s, null, 100);
    try t.expectEqual(@as(usize, 2), first.len);
    try t.expectEqualStrings("2025/IMG_0001.JPG", first[0].photo.id);
    try t.expectEqualStrings("IMG_0002.jpg", first[1].photo.id);
    try t.expect(first[0].photo.taken_at == null and first[1].photo.taken_at == null);
    try t.expectEqual(@as(u64, 2), first[1].photo.bytes);
    try t.expectEqual(@as(u32, 4), first[0].photo.w);
    try t.expectError(error.NotFound, listing(s, "unknown", 1));
    try mem.put("/Heronin/IMG_0000.webp", "a");
    try write(&mem, "/Heronin/IMG_0000.webp", "abc");
    // A fresh store reads the external writer's change; imports invalidate an existing cache.
    var fresh = try DriveStore.init(t.allocator, mem.fs(), "/Heronin", clock);
    defer fresh.deinit();
    const timed = try listing(fresh.store(), null, 100);
    try t.expectEqualStrings("IMG_0000.webp", timed[0].photo.id);
    try t.expectEqual(@as(?i64, 0), timed[0].photo.taken_at);
    const page = try listing(fresh.store(), "IMG_0000.webp", 1);
    try t.expectEqualStrings("2025/IMG_0001.JPG", page[0].photo.id);
    try t.expectEqual(@as(usize, 0), (try listing(s, null, 0)).len);
}
test "Drive imports create folders, reuse same size and rename collisions; bytes are copied" {
    now = 1794355200;
    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    var drive = try DriveStore.init(t.allocator, mem.fs(), "/Heronin", clock);
    defer drive.deinit();
    const s = drive.store();
    try t.expectEqual(@as(usize, 0), (try listing(s, null, 10)).len);
    var bytes = [_]u8{ 1, 2 };
    var sink: Sink(api.Imported) = .{};
    s.importFile("IMG_0001.jpg", &bytes, &sink, @TypeOf(sink).done);
    @memset(&bytes, 9);
    const added = try sink.get(s);
    try t.expect(added.new);
    try t.expectEqualStrings("2026/IMG_0001.jpg", added.photo.id);
    try t.expectEqualSlices(u8, &.{ 1, 2 }, mem.nodes.get("/Heronin/2026/IMG_0001.jpg").?.bytes);
    try t.expect(!(try import(s, "ab")).new);
    const collision = try import(s, "abc");
    try t.expect(collision.new);
    try t.expectEqualStrings("2026/IMG_0001 (2).jpg", collision.photo.id);
    try t.expectEqual(@as(usize, 2), (try listing(s, null, 20)).len);
    var unsupported: Sink(void) = .{};
    s.setTags("x", &.{}, .new, &unsupported, @TypeOf(unsupported).done);
    try t.expectError(error.Unsupported, unsupported.get(s));
}
test "Drive places round trip and retry a stale timestamp once" {
    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    try mem.putDir("/Heronin");
    var drive = try DriveStore.init(t.allocator, mem.fs(), "/Heronin", clock);
    defer drive.deinit();
    const s = drive.store();
    try t.expectEqual(@as(usize, 0), (try places(s)).len);
    const values = [_]model.Place{.{ .id = 1, .name = "Test place", .lat = 0, .lon = 0 }};
    try t.expectEqualStrings("Test place", (try save(s, &values))[0].name);
    const first_stamp = drive.cache.modified;
    var consecutive: Sink([]const model.Place) = .{};
    s.savePlaces(&values, &consecutive, @TypeOf(consecutive).done);
    for (0..3) |_| s.pump();
    try t.expect(consecutive.result != null); // No conflict read/retry between write and stat.
    try t.expectEqualStrings("Test place", (try consecutive.result.?)[0].name);
    try t.expect(drive.cache.modified.? > first_stamp.?);
    try t.expectEqual(@as(f64, 0), (try places(s))[0].lat);
    try write(&mem, "/Heronin/places.json", "[]");
    try t.expectEqualStrings("Test place", (try save(s, &values))[0].name);
    try t.expectEqualStrings("Test place", (try places(s))[0].name);
    const parsed = try std.json.parseFromSlice([]model.Place, t.allocator, mem.nodes.get("/Heronin/places.json").?.bytes, .{});
    defer parsed.deinit();
    try t.expectEqualStrings("Test place", parsed.value[0].name);
}
test "Drive clock crosses UTC year boundary and rejects extreme numbers" {
    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    var drive = try DriveStore.init(t.allocator, mem.fs(), "/Heronin", clock);
    defer drive.deinit();
    const s = drive.store();
    now = 1798761599;
    try t.expectEqualStrings("2026/IMG_0001.jpg", (try import(s, "a")).photo.id);
    now += 1;
    try t.expectEqualStrings("2027/IMG_0001.jpg", (try import(s, "a")).photo.id);
    now = -1;
    try t.expectError(error.Io, import(s, "a"));
    now = std.math.maxInt(i64);
    try t.expectError(error.Io, import(s, "a"));
    try write(&mem, "/Heronin/places.json", "[{\"id\":1,\"name\":\"Test\",\"lat\":1e300,\"lon\":0}]");
    try t.expectError(error.Io, places(s));
}

test "Drive pump delivers every queued thumbnail" {
    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    var drive = try DriveStore.init(t.allocator, mem.fs(), "/Heronin", clock);
    defer drive.deinit();
    const s = drive.store();
    var sinks = [_]Sink(api.Thumbnail){ .{}, .{}, .{} };
    for (&sinks) |*sink| s.thumbnail("IMG_0001.jpg", 100, sink, Sink(api.Thumbnail).done);
    s.pump();
    for (sinks) |sink| {
        try t.expect(sink.result != null);
        try t.expect((try sink.result.?).wash < 6);
    }
}
