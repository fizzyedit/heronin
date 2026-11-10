const std = @import("std");
const model = @import("model");
const api = @import("store.zig");
const FakeStore = @import("fake_store.zig").FakeStore;
const expect = std.testing.expect;
const eq = std.testing.expectEqual;
fn Reply(comptime T: type) type {
    return struct {
        result: ?api.Error!T = null,
        fn done(ctx: ?*anyopaque, result: api.Error!T) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.result = result;
        }
    };
}
test "deferred pages cover the exact generated fixture and places" {
    var fake = try FakeStore.init(std.testing.allocator);
    defer fake.deinit();
    const store = fake.store();
    var saved: Reply([]const model.Place) = .{};
    store.places(&saved, @TypeOf(saved).done);
    try expect(saved.result == null);
    store.pump();
    const places = try saved.result.?;
    try eq(@as(usize, 2), places.len);
    try std.testing.expectEqualStrings("Backyard", places[0].name);
    try std.testing.expectEqualStrings("Marsh trail", places[1].name);
    var counts: [6]usize = @splat(0);
    var favorites: usize = 0;
    var missing: usize = 0;
    var species: [12]bool = @splat(false);
    var washes: [6]bool = @splat(false);
    var seen: [60]bool = @splat(false);
    var total: usize = 0;
    var after: ?[]const u8 = null;
    var previous: i64 = std.math.maxInt(i64);
    for (0..3) |page| {
        var reply: Reply([]const api.Item) = .{};
        store.list(after, 25, &reply, @TypeOf(reply).done);
        try expect(reply.result == null);
        store.pump();
        const items = try reply.result.?;
        try eq(@as(usize, if (page < 2) 25 else 10), items.len);
        for (items) |item| {
            const p = item.photo;
            const i: usize = p.md5.bytes[0];
            try expect(!seen[i]);
            seen[i] = true;
            try expect(p.taken_at.? <= previous);
            previous = p.taken_at.?;
            var buf: [20]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "fake-{d:0>2}.jpg", .{i}), p.name);
            try std.testing.expectEqualStrings(p.name[0..7], p.id);
            try eq(@as([16]u8, @splat(@intCast(i))), p.md5.bytes);
            try eq(@as(u64, 2_000_000 + i * 1000), p.bytes);
            try eq(@as(i64, 1_793_000_000 - @as(i64, @intCast(i * 9 / 60)) * 86_400 - @as(i64, @intCast(i % 7)) * 2_400), p.taken_at.?);
            try eq(i % 2 == 0, p.camera != null);
            if (p.camera) |camera| try std.testing.expectEqualStrings("Fake Camera", camera);
            try eq(@as(u32, if (i % 3 == 0) 4000 else 3000), p.w);
            try eq(@as(u32, if (i % 3 == 1) 4000 else 3000), p.h);
            try eq(([_]model.Photo.State{ .tagged, .review, .tagging, .new, .failed, .skipped })[i % 6], p.state);
            counts[@backingInt(p.state)] += 1;
            try eq(i % 5 == 0, p.favorite);
            if (p.favorite) favorites += 1;
            try expect(p.fix == null);
            try eq(i % 4 == 3, p.place == null);
            if (p.place) |point| {
                const offset = @as(f64, @floatFromInt(i % 10)) * 0.0003;
                const marsh_lat: f64 = 60.0105;
                const origin_lat: f64 = 0.0105;
                const east_lon: f64 = 179.9995;
                const west_lon: f64 = -179.9995;
                try eq((if (i % 3 == 1) marsh_lat else origin_lat) + offset, point.lat);
                try eq(switch (i % 3) {
                    0 => 0.0105 + offset,
                    1 => -29.9895 + offset,
                    else => if (i % 2 == 0) east_lon else west_lon,
                }, point.lon);
                try std.testing.expectEqualStrings(([_][]const u8{ "Backyard", "Marsh trail", "Unnamed place" })[i % 3], @import("library_logic.zig").placeText(.{ .lat = point.lat, .lon = point.lon, .src = .photo }, places, null).?);
            } else missing += 1;
            try eq(@as(usize, if (i % 6 == 0) 1 else if (i % 6 == 1) 3 else 0), item.tags.len);
            for (item.tags, 0..) |tag, j| {
                const index = (i + j) % 12;
                species[index] = true;
                try std.testing.expectEqualStrings(model.species.table[index].code, tag.species);
                try eq(@as(f32, if (item.tags.len == 1) 0.92 else ([_]f32{ 0.62, 0.21, 0.09 })[j]), tag.confidence);
                try eq(model.Tag.Source.ours, tag.source);
                try eq(model.Tag.Accepted.auto, tag.accepted);
                try eq(p.taken_at.? + 60, tag.at);
                try std.testing.expectEqualStrings("fake", tag.model);
                try eq(i % 2 == 0, tag.box != null);
                if (tag.box) |box| try eq(model.Box{ .x = 0.3, .y = 0.25, .w = 0.4, .h = 0.5 }, box);
                try eq(i % 4 == 0, tag.detail != null);
                if (tag.detail) |detail| try std.testing.expectEqualStrings("adult male", detail);
                try eq(i % 3 == 0, tag.note != null);
                if (tag.note) |note| try std.testing.expectEqualStrings("Crest, red bill and black face matched.", note);
            }
            var thumb: Reply(api.Thumbnail) = .{};
            store.thumbnail(p.id, 100, &thumb, @TypeOf(thumb).done);
            try expect(thumb.result == null);
            store.pump();
            const wash = (try thumb.result.?).wash;
            try eq(@as(u8, @intCast(i % 6)), wash);
            washes[wash] = true;
        }
        total += items.len;
        after = items[items.len - 1].photo.id;
    }
    try eq(@as(usize, 60), total);
    try eq(@as([6]usize, @splat(10)), counts);
    try eq(@as(usize, 12), favorites);
    try eq(@as(usize, 15), missing);
    try eq(@as(usize, 12), model.species.table.len);
    try eq([_]bool{ true, true, true, true, false, false, true, true, true, true, false, false }, species);
    try eq(@as([6]bool, @splat(true)), washes);
    var end: Reply([]const api.Item) = .{};
    store.list(after, 25, &end, @TypeOf(end).done);
    store.pump();
    try eq(@as(usize, 0), (try end.result.?).len);
}
test "mutations, errors, and FIFO delivery" {
    var fake = try FakeStore.init(std.testing.allocator);
    defer fake.deinit();
    const store = fake.store();
    var first: Reply(void) = .{};
    var second: Reply(void) = .{};
    store.setFavorite("fake-01", true, &first, @TypeOf(first).done);
    var tags = [_]model.Tag{.{ .species = "osprey", .confidence = 1, .source = .person, .accepted = .person, .at = 42, .model = "" }};
    store.setTags("fake-01", &tags, .tagged, &second, @TypeOf(second).done);
    try expect(first.result == null and second.result == null);
    store.pump();
    try first.result.?;
    try second.result.?;
    tags[0].species = "changed";
    var reply: Reply([]const api.Item) = .{};
    store.list(null, 60, &reply, @TypeOf(reply).done);
    store.pump();
    for (try reply.result.?) |item| if (std.mem.eql(u8, item.photo.id, "fake-01")) {
        try expect(item.photo.favorite);
        try eq(model.Photo.State.tagged, item.photo.state);
        try std.testing.expectEqualStrings("osprey", item.tags[0].species);
    };
    var bad: Reply(void) = .{};
    store.setTags("missing", &.{}, .tagged, &bad, @TypeOf(bad).done);
    try expect(bad.result == null);
    store.pump();
    try std.testing.expectError(error.NotFound, bad.result.?);
    bad = .{};
    store.setFavorite("missing", false, &bad, @TypeOf(bad).done);
    store.pump();
    try std.testing.expectError(error.NotFound, bad.result.?);
    reply = .{};
    store.list("missing", 1, &reply, @TypeOf(reply).done);
    store.pump();
    try std.testing.expectError(error.NotFound, reply.result.?);
    var thumb: Reply(api.Thumbnail) = .{};
    store.thumbnail("missing", 1, &thumb, @TypeOf(thumb).done);
    store.pump();
    try std.testing.expectError(error.NotFound, thumb.result.?);
    var imported: Reply(api.Imported) = .{};
    store.importFile("a.jpg", "bytes", &imported, @TypeOf(imported).done);
    try expect(imported.result == null);
    store.pump();
    const first_import = try imported.result.?;
    try expect(first_import.new);
    var listed: Reply([]const api.Item) = .{};
    store.list(null, 1, &listed, @TypeOf(listed).done);
    store.pump();
    try std.testing.expectEqualStrings(first_import.photo.id, (try listed.result.?)[0].photo.id);
    try std.testing.expectEqualStrings("a.jpg", (try listed.result.?)[0].photo.name);
    imported = .{};
    store.importFile("another.jpg", "bytes", &imported, @TypeOf(imported).done);
    store.pump();
    try expect(!(try imported.result.?).new);
    try std.testing.expectEqualStrings(first_import.photo.id, (try imported.result.?).photo.id);
    const Order = struct {
        count: usize = 0,
        fn done(ctx: ?*anyopaque, result: api.Error!api.Thumbnail) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const thumbnail = result catch unreachable;
            std.debug.assert(thumbnail.wash == self.count);
            self.count += 1;
        }
    };
    var order: Order = .{};
    store.thumbnail("fake-00", 1, &order, Order.done);
    store.thumbnail("fake-01", 1, &order, Order.done);
    try eq(@as(usize, 0), order.count);
    store.pump();
    try eq(@as(usize, 2), order.count);
}

test "callbacks can enqueue answers for the next pump" {
    var fake = try FakeStore.init(std.testing.allocator);
    defer fake.deinit();
    const Chain = struct {
        store: api.Store,
        count: usize = 0,
        fn done(ctx: ?*anyopaque, result: api.Error!api.Thumbnail) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            _ = result catch unreachable;
            self.count += 1;
            if (self.count < 3) self.store.thumbnail("fake-00", 1, self, done);
        }
    };
    var chain: Chain = .{ .store = fake.store() };
    chain.store.thumbnail("fake-00", 1, &chain, Chain.done);
    for (1..4) |n| {
        chain.store.pump();
        try eq(n, chain.count);
    }
}
