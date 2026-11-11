const std = @import("std");
const vfs = @import("core").vfs;
const api = @import("store.zig");
const model = @import("model");
const DriveStore = @import("drive_store.zig").DriveStore;
const t = std.testing;
fn Sink(comptime T: type) type {
    return struct {
        calls: usize = 0,
        result: api.Error!T = error.Io,
        fn done(ctx: ?*anyopaque, result: api.Error!T) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            self.result = result;
        }
    };
}
const List = Sink([]const api.Item);
fn seed(mem: *vfs.Mem) !void {
    try mem.putDir("/Heronin");
    try mem.putDir("/Heronin/2025");
    try mem.putDir("/Heronin/misc");
    try mem.put("/Heronin/IMG_0002.jpg", "ab");
    try mem.put("/Heronin/2025/IMG_0001.JPG", "abc");
    try mem.put("/Heronin/2025/notes.txt", "notes");
    try mem.put("/Heronin/misc/IMG_0003.jpg", "ignored");
}
test "folder listing takes two pumps, pages copied cursors and caches without Fs calls" {
    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    try seed(&mem);
    var drive = try DriveStore.init(t.allocator, mem.fs(), "/Heronin");
    defer drive.deinit();
    const store = drive.store();
    var list: List = .{};
    store.list(null, std.math.maxInt(u32), &list, List.done);
    try t.expectEqual(0, list.calls);
    store.pump();
    try t.expectEqual(0, list.calls);
    store.pump();
    try t.expectEqual(1, list.calls);
    const items = try list.result;
    try t.expectEqual(2, items.len);
    try t.expectEqualStrings("2025/IMG_0001.JPG", items[0].photo.id);
    try t.expectEqualStrings("IMG_0002.jpg", items[1].photo.id);
    try t.expectEqualStrings("IMG_0001.JPG", items[0].photo.name);
    try t.expectEqual(@as(?i64, null), items[0].photo.taken_at);
    try t.expectEqual(@as(?i64, null), items[1].photo.taken_at);
    try t.expectEqual(3, items[0].photo.bytes);
    try t.expectEqual(4, items[0].photo.w);
    try t.expectEqual(3, items[0].photo.h);
    try t.expect(std.mem.allEqual(u8, &items[0].photo.md5.bytes, 0));
    try t.expectEqual(0, items[0].tags.len);
    var cursor = "2025/IMG_0001.JPG".*;
    store.list(&cursor, 1, &list, List.done);
    @memset(&cursor, 'x');
    try t.expect(!mem.busy());
    try t.expectEqual(1, list.calls);
    store.pump();
    try t.expectEqual(2, list.calls);
    try t.expectEqualStrings("IMG_0002.jpg", (try list.result)[0].photo.id);
    store.list("unknown", 1, &list, List.done);
    store.pump();
    try t.expectEqual(3, list.calls);
    try t.expectError(error.NotFound, list.result);
}
fn written(_: ?*anyopaque, result: vfs.Result(void)) void {
    result.get() catch unreachable;
}
test "writeFile time sorts ahead of missing time on the second pump" {
    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    try seed(&mem);
    _ = try mem.fs().writeFile("/Heronin/IMG_0002.jpg", "abcd", .{}, written, null);
    mem.fs().pump();
    var drive = try DriveStore.init(t.allocator, mem.fs(), "/Heronin");
    defer drive.deinit();
    var list: List = .{};
    const store = drive.store();
    store.list(null, 10, &list, List.done);
    store.pump();
    try t.expectEqual(0, list.calls);
    store.pump();
    try t.expectEqual(1, list.calls);
    try t.expectEqualStrings("IMG_0002.jpg", (try list.result)[0].photo.id);
    try t.expectEqual(@as(?i64, 0), (try list.result)[0].photo.taken_at);
}
test "missing root answers empty on first pump" {
    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    var drive = try DriveStore.init(t.allocator, mem.fs(), "/Heronin");
    defer drive.deinit();
    var list: List = .{};
    drive.store().list(null, 10, &list, List.done);
    try t.expectEqual(0, list.calls);
    drive.store().pump();
    try t.expectEqual(1, list.calls);
    try t.expectEqual(0, (try list.result).len);
}
test "thumbnail and all refusals bypass a listing on first pump" {
    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    try seed(&mem);
    var drive = try DriveStore.init(t.allocator, mem.fs(), "/Heronin");
    defer drive.deinit();
    const store = drive.store();
    var list: List = .{};
    var thumb: Sink(api.Thumbnail) = .{};
    var tags: Sink(void) = .{};
    var favorite: Sink(void) = .{};
    var imported: Sink(api.Imported) = .{};
    var places: Sink([]const model.Place) = .{};
    var saved: Sink([]const model.Place) = .{};
    store.list(null, 10, &list, List.done);
    store.thumbnail("IMG_0002.jpg", std.math.maxInt(u32), &thumb, @TypeOf(thumb).done);
    store.setTags("IMG_0002.jpg", &.{}, .new, &tags, @TypeOf(tags).done);
    store.setFavorite("IMG_0002.jpg", true, &favorite, @TypeOf(favorite).done);
    store.importFile("IMG_0004.jpg", "", &imported, @TypeOf(imported).done);
    store.places(&places, @TypeOf(places).done);
    store.savePlaces(&.{}, &saved, @TypeOf(saved).done);
    try t.expectEqual(0, thumb.calls);
    try t.expectEqual(0, tags.calls);
    store.pump();
    try t.expectEqual(0, list.calls);
    try t.expectEqual(1, thumb.calls);
    const wash = @as(u8, @truncate(std.hash.Wyhash.hash(0, "IMG_0002.jpg"))) % 6;
    try t.expectEqual(wash, (try thumb.result).wash);
    try t.expectEqual(1, tags.calls);
    try t.expectEqual(1, favorite.calls);
    try t.expectEqual(1, imported.calls);
    try t.expectEqual(1, places.calls);
    try t.expectEqual(1, saved.calls);
    try t.expectError(error.Unsupported, tags.result);
    try t.expectError(error.Unsupported, favorite.result);
    try t.expectError(error.Unsupported, imported.result);
    try t.expectError(error.Unsupported, places.result);
    try t.expectError(error.Unsupported, saved.result);
    store.pump();
    try t.expectEqual(1, list.calls);
}
test "Fs errors answer Io and the next list retries" {
    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    try mem.put("/Heronin", "not a directory");
    var drive = try DriveStore.init(t.allocator, mem.fs(), "/Heronin");
    defer drive.deinit();
    const store = drive.store();
    var list: List = .{};
    store.list(null, 10, &list, List.done);
    store.pump();
    try t.expectEqual(1, list.calls);
    try t.expectError(error.Io, list.result);
    _ = try mem.fs().remove("/Heronin", written, null);
    mem.fs().pump();
    try mem.putDir("/Heronin");
    store.list(null, 10, &list, List.done);
    store.pump();
    try t.expectEqual(2, list.calls);
    try t.expectEqual(0, (try list.result).len);
}
test "answers queued during delivery wait until next pump" {
    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    var drive = try DriveStore.init(t.allocator, mem.fs(), "/Heronin");
    defer drive.deinit();
    const Callback = struct {
        var calls: usize = 0;
        fn done(ctx: ?*anyopaque, _: api.Error!api.Thumbnail) void {
            const d: *DriveStore = @ptrCast(@alignCast(ctx.?));
            d.store().list(null, 1, null, ignore);
        }
        fn ignore(_: ?*anyopaque, _: api.Error![]const api.Item) void {
            calls += 1;
        }
    };
    drive.store().thumbnail("IMG_0001.jpg", 1, &drive, Callback.done);
    drive.store().pump();
    try t.expectEqual(0, Callback.calls);
    drive.store().pump();
    try t.expectEqual(1, Callback.calls);
}
