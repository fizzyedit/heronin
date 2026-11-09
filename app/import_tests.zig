const std = @import("std");
const api = @import("store.zig");
const imports = @import("import_queue.zig");
const FakeStore = @import("fake_store.zig").FakeStore;
const eq = std.testing.expectEqual;
const a = std.testing.allocator;
fn add(q: *imports.Queue, names: []const []const u8) !void {
    var buffers: [11][]u8 = undefined;
    for (names, 0..) |name, i| buffers[i] = try a.dupe(u8, name);
    q.add(names, buffers[0..names.len]) catch |err| {
        for (buffers[0..names.len]) |buffer| a.free(buffer);
        return err;
    };
}
test "eleven files add none; queued buffers are released on deinit" {
    var q: imports.Queue = .{ .allocator = a };
    defer q.deinit();
    try std.testing.expectError(error.TooMany, add(&q, &(@as([11][]const u8, @splat("file")))));
    try eq(@as(usize, 0), q.rows.items.len);
    try add(&q, &.{ "a", "b" });
}
test "three imports are serial, deduplicated, and counted against listed states" {
    var fake = try FakeStore.init(a);
    defer fake.deinit();
    const store = fake.store();
    var q: imports.Queue = .{ .allocator = a };
    defer q.deinit();
    try add(&q, &.{ "a", "b", "c" });
    for (0..3) |i| {
        try eq(imports.State.queued, q.rows.items[i].state);
        q.step(store);
        try eq(imports.State.uploading, q.rows.items[i].state);
        q.step(store);
        for (q.rows.items[i + 1 ..]) |row| try eq(imports.State.queued, row.state);
        store.pump();
        try eq(imports.State.imported, q.rows.items[i].state);
        try std.testing.expectEqualStrings(q.rows.items[i].name, fake.items[0].photo.name);
    }
    try add(&q, &.{"a"});
    q.step(store);
    store.pump();
    try eq(imports.State.already_there, q.rows.items[3].state);
    try std.testing.expectEqualStrings(q.rows.items[0].photo_id.?, q.rows.items[3].photo_id.?);
    fake.items[0].photo.state = .skipped;
    fake.items[1].photo.state = .review;
    fake.items[2].photo.state = .tagged;
    const Listed = struct {
        items: []const api.Item = &.{},
        fn done(ctx: ?*anyopaque, result: api.Error![]const api.Item) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.items = result catch unreachable;
        }
    };
    var listed: Listed = .{};
    store.list(null, 100, &listed, Listed.done);
    store.pump();
    try eq(imports.Counts{ .total = 4, .finished = 4, .tagged = 2, .review = 1, .skipped = 1 }, imports.counts(q.rows.items, listed.items));
    try add(&q, &.{ "d", "e" });
    q.step(store);
    try eq(@as(usize, 4), imports.counts(q.rows.items, listed.items).finished);
    store.pump();
}
test "deferred error frees the buffer and allows the next import" {
    const Failing = struct {
        ctx: ?*anyopaque = null,
        done: ?api.Done(api.Imported) = null,
        fn importFile(ptr: *anyopaque, _: []const u8, _: []const u8, ctx: ?*anyopaque, done: api.Done(api.Imported)) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.ctx = ctx;
            self.done = done;
        }
        fn pump(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const done = self.done orelse return;
            self.done = null;
            done(self.ctx, error.Io);
        }
    };
    var fake = try FakeStore.init(a);
    defer fake.deinit();
    var failing: Failing = .{};
    var table = fake.store().vtable.*;
    table.importFile = Failing.importFile;
    table.pump = Failing.pump;
    const store: api.Store = .{ .ptr = &failing, .vtable = &table };
    var q: imports.Queue = .{ .allocator = a };
    defer q.deinit();
    try add(&q, &.{ "bad", "good" });
    q.step(store);
    store.pump();
    try eq(imports.State.failed, q.rows.items[0].state);
    try eq(error.Io, q.rows.items[0].err.?);
    q.step(fake.store());
    fake.store().pump();
    try eq(imports.State.imported, q.rows.items[1].state);
    try eq(@as(usize, 2), imports.counts(q.rows.items, fake.items).finished);
}

test "adding rows during upload keeps the callback attached to its row" {
    var fake = try FakeStore.init(a);
    defer fake.deinit();
    var q: imports.Queue = .{ .allocator = a };
    defer q.deinit();
    try add(&q, &.{"first"});
    q.step(fake.store());
    for (0..10) |_| try add(&q, &.{"later"});
    fake.store().pump();
    try eq(imports.State.imported, q.rows.items[0].state);
    for (q.rows.items[1..]) |row| try eq(imports.State.queued, row.state);
}
