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
fn clock() i64 {
    return 1750000000;
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
    var drive = try DriveStore.init(t.allocator, mem.fs(), "/Heronin", clock);
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
    var drive = try DriveStore.init(t.allocator, mem.fs(), "/Heronin", clock);
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
    var drive = try DriveStore.init(t.allocator, mem.fs(), "/Heronin", clock);
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
    var drive = try DriveStore.init(t.allocator, mem.fs(), "/Heronin", clock);
    defer drive.deinit();
    const store = drive.store();
    var list: List = .{};
    var thumb: Sink(api.Thumbnail) = .{};
    var tags: Sink(void) = .{};
    var favorite: Sink(void) = .{};
    store.list(null, 10, &list, List.done);
    store.thumbnail("IMG_0002.jpg", std.math.maxInt(u32), &thumb, @TypeOf(thumb).done);
    store.setTags("IMG_0002.jpg", &.{}, .new, &tags, @TypeOf(tags).done);
    store.setFavorite("IMG_0002.jpg", true, &favorite, @TypeOf(favorite).done);
    try t.expectEqual(0, thumb.calls);
    try t.expectEqual(0, tags.calls);
    store.pump();
    try t.expectEqual(0, list.calls);
    try t.expectEqual(1, thumb.calls);
    const wash = @as(u8, @truncate(std.hash.Wyhash.hash(0, "IMG_0002.jpg"))) % 6;
    try t.expectEqual(wash, (try thumb.result).wash);
    try t.expectEqual(1, tags.calls);
    try t.expectEqual(1, favorite.calls);
    try t.expectError(error.Unsupported, tags.result);
    try t.expectError(error.Unsupported, favorite.result);
    store.pump();
    try t.expectEqual(1, list.calls);
}
test "Fs errors answer Io and the next list retries" {
    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    try mem.put("/Heronin", "not a directory");
    var drive = try DriveStore.init(t.allocator, mem.fs(), "/Heronin", clock);
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
    var drive = try DriveStore.init(t.allocator, mem.fs(), "/Heronin", clock);
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
test "imports copy inputs, create year, deduplicate and refresh listing" {
    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    var drive = try DriveStore.init(t.allocator, mem.fs(), "/Heronin", clock);
    defer drive.deinit();
    const store = drive.store();
    var imported: Sink(api.Imported) = .{};
    var name = "IMG_0001.jpg".*;
    var bytes = "bytes".*;
    store.importFile(&name, &bytes, &imported, @TypeOf(imported).done);
    @memset(&name, 'x');
    @memset(&bytes, 'x');
    for (0..4) |_| store.pump();
    try t.expectEqual(1, imported.calls);
    try t.expect((try imported.result).new);
    try t.expectEqualStrings("2025/IMG_0001.jpg", (try imported.result).photo.id);
    try t.expectEqual(5, (try imported.result).photo.bytes);
    _ = try mem.fs().writeFile("/Heronin/2025/IMG_0001.jpg", "bytes", .{}, written, null);
    mem.fs().pump();
    store.importFile("IMG_0001.jpg", "bytes", &imported, @TypeOf(imported).done);
    for (0..3) |_| store.pump();
    try t.expectEqual(2, imported.calls);
    try t.expect(!(try imported.result).new);
    try t.expectEqual(@as(?i64, 0), (try imported.result).photo.taken_at);
    var list: List = .{};
    store.list(null, 10, &list, List.done);
    for (0..2) |_| store.pump();
    try t.expectEqual(1, (try list.result).len);
    store.importFile("IMG_0001.jpg", "other bytes", &imported, @TypeOf(imported).done);
    for (0..5) |_| store.pump();
    try t.expectEqual(3, imported.calls);
    try t.expect((try imported.result).new);
    try t.expectEqualStrings("2025/IMG_0001 (2).jpg", (try imported.result).photo.id);
    try t.expectEqual(11, (try imported.result).photo.bytes);
    try t.expectEqual(@as(?i64, null), (try imported.result).photo.taken_at);
    store.list(null, 10, &list, List.done);
    for (0..2) |_| store.pump();
    try t.expectEqual(2, (try list.result).len);
}
test "places round trip, fresh stat and one conflict retry have exact pump counts" {
    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    try mem.putDir("/Heronin");
    var drive = try DriveStore.init(t.allocator, mem.fs(), "/Heronin", clock);
    defer drive.deinit();
    const store = drive.store();
    var places: Sink([]const model.Place) = .{};
    store.places(&places, @TypeOf(places).done);
    store.pump();
    try t.expectEqual(0, (try places.result).len);
    try t.expectEqual(@as(?i64, null), drive.places_ms);
    var name = "Test place".*;
    var values = [_]model.Place{.{ .id = 1, .name = &name, .lat = 0, .lon = 0 }};
    store.savePlaces(&values, &places, @TypeOf(places).done);
    @memset(&name, 'x');
    values[0].lat = 60;
    store.pump();
    try t.expectEqual(1, places.calls);
    store.pump();
    try t.expectEqual(2, places.calls);
    try t.expectEqualStrings("Test place", (try places.result)[0].name);
    try t.expectEqual(0, (try places.result)[0].lat);
    const saved = [_]model.Place{.{ .id = 2, .name = "Another place", .lat = 60, .lon = -30 }};
    store.savePlaces(&saved, &places, @TypeOf(places).done);
    store.pump();
    try t.expectEqual(2, places.calls);
    store.pump();
    try t.expectEqual(3, places.calls);
    store.places(&places, @TypeOf(places).done);
    store.pump();
    try t.expectEqual(4, places.calls);
    try t.expectEqualStrings(saved[0].name, (try places.result)[0].name);
    _ = try mem.fs().writeFile("/Heronin/places.json", "[]", .{}, written, null);
    mem.fs().pump();
    store.savePlaces(&saved, &places, @TypeOf(places).done);
    for (0..3) |_| {
        store.pump();
        try t.expectEqual(4, places.calls);
    }
    store.pump();
    try t.expectEqual(5, places.calls);
    store.places(&places, @TypeOf(places).done);
    store.pump();
    try t.expectEqual(6, places.calls);
    try t.expectEqualStrings(saved[0].name, (try places.result)[0].name);
}
test "unrepresentable clock years answer Io without integer traps" {
    const Clocks = struct {
        fn negative() i64 {
            return std.math.minInt(i64);
        }
        fn huge() i64 {
            return std.math.maxInt(i64);
        }
    };
    inline for (.{ Clocks.negative, Clocks.huge }) |now| {
        var mem = try vfs.Mem.init(t.allocator);
        defer mem.deinit();
        var drive = try DriveStore.init(t.allocator, mem.fs(), "/Heronin", now);
        defer drive.deinit();
        var imported: Sink(api.Imported) = .{};
        drive.store().importFile("IMG_0001.jpg", "bytes", &imported, @TypeOf(imported).done);
        drive.store().pump();
        try t.expectEqual(1, imported.calls);
        try t.expectError(error.Io, imported.result);
    }
}
test "import during listing safely refreshes lists queued from its callback" {
    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    try seed(&mem);
    var drive = try DriveStore.init(t.allocator, mem.fs(), "/Heronin", clock);
    defer drive.deinit();
    const Callback = struct {
        store: api.Store,
        list: List = .{},
        fn done(ctx: ?*anyopaque, _: api.Error!api.Imported) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.store.list(null, 10, &self.list, List.done);
        }
    };
    var callback: Callback = .{ .store = drive.store() };
    callback.store.importFile("IMG_0004.jpg", "bytes", &callback, Callback.done);
    for (0..2) |_| callback.store.pump();
    callback.store.list(null, 10, &callback.list, List.done);
    for (0..2) |_| callback.store.pump();
    try t.expectEqual(0, callback.list.calls);
    for (0..2) |_| callback.store.pump();
    try t.expectEqual(2, callback.list.calls);
    try t.expectEqualStrings("2025/IMG_0004.jpg", (try callback.list.result)[1].photo.id);
}
test "deinit with an import and a places save pending runs no callback" {
    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    var drive = try DriveStore.init(t.allocator, mem.fs(), "/Heronin", clock);
    var imported: Sink(api.Imported) = .{};
    var places: Sink([]const model.Place) = .{};
    drive.store().importFile("IMG_0001.jpg", "bytes", &imported, @TypeOf(imported).done);
    drive.store().savePlaces(&.{}, &places, @TypeOf(places).done);
    drive.deinit();
    mem.fs().pump();
    try t.expectEqual(0, imported.calls);
    try t.expectEqual(0, places.calls);
}
test "deinit while the listing reads runs no callback" {
    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    try seed(&mem);
    var drive = try DriveStore.init(t.allocator, mem.fs(), "/Heronin", clock);
    var list: List = .{};
    drive.store().list(null, 10, &list, List.done);
    drive.deinit();
    mem.fs().pump();
    try t.expectEqual(0, list.calls);
}
test "a places file deleted during a conflicting save is written again" {
    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    try mem.putDir("/Heronin");
    var drive = try DriveStore.init(t.allocator, mem.fs(), "/Heronin", clock);
    defer drive.deinit();
    const store = drive.store();
    var places: Sink([]const model.Place) = .{};
    store.places(&places, @TypeOf(places).done);
    store.pump();
    const initial = [_]model.Place{.{ .id = 1, .name = "Test place", .lat = 0, .lon = 0 }};
    store.savePlaces(&initial, &places, @TypeOf(places).done);
    store.pump();
    store.pump();
    try t.expectEqual(2, places.calls);
    _ = try mem.fs().remove("/Heronin/places.json", written, null);
    mem.fs().pump();
    const saved = [_]model.Place{.{ .id = 2, .name = "Another place", .lat = 60, .lon = -30 }};
    store.savePlaces(&saved, &places, @TypeOf(places).done);
    // Write, reread (NotFound), rewrite, stat: answers on the fourth pump.
    for (0..3) |_| {
        store.pump();
        try t.expectEqual(2, places.calls);
    }
    store.pump();
    try t.expectEqual(3, places.calls);
    try t.expectEqualDeep(&saved, try places.result);
    store.places(&places, @TypeOf(places).done);
    store.pump();
    try t.expectEqual(4, places.calls);
    try t.expectEqualDeep(&saved, try places.result);
}
