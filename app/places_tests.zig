const std = @import("std");
const model = @import("model");
const client = @import("places_client.zig");
const core = @import("core");
const http = core.vfs.http;
var requests: usize = 0;
var pending_url: []const u8 = "";
fn request(_: *anyopaque, _: std.mem.Allocator, req: http.Request, _: http.DoneFn, _: ?*anyopaque) core.vfs.Error!http.Job {
    tryCheck(req.method == .GET and std.mem.endsWith(u8, req.url, "?lat=0.000&lon=0.000"));
    pending_url = req.url;
    requests += 1;
    return .{ .id = 1 };
}
fn tryCheck(ok: bool) void {
    std.testing.expect(ok) catch unreachable;
}
fn cancel(_: *anyopaque, _: http.Job) void {}
fn pump(_: *anyopaque) void {}
test "places dedupe saved coverage errors distance and owned request lifetime" {
    var names: client.Names = .{};
    defer names.deinit();
    var dummy: u8 = 0;
    const transport: http.Transport = .{ .ptr = &dummy, .vtable = &.{ .request = request, .cancel = cancel, .pump = pump } };
    var photos = [_]model.Photo{
        .{ .id = "b", .md5 = .{ .bytes = @splat(0) }, .name = "b", .w = 1, .h = 1, .bytes = 1, .place = .{ .lat = 0.00045, .lon = 0 } },
        .{ .id = "a", .md5 = .{ .bytes = @splat(0) }, .name = "a", .w = 1, .h = 1, .bytes = 1, .taken_at = 1, .place = .{ .lat = 0, .lon = 0 } },
    };
    requests = 0;
    client.step(&names, &photos, &.{.{ .id = 1, .name = "Saved", .lat = 0, .lon = 0 }}, transport, "");
    try std.testing.expectEqual(@as(usize, 0), requests);
    client.step(&names, &photos, &.{}, transport, "");
    client.step(&names, &photos, &.{}, transport, "");
    try std.testing.expectEqual(@as(usize, 1), requests);
    try std.testing.expectEqualStrings("/heronin/api/place?lat=0.000&lon=0.000", pending_url);
    const body = try names.arena.allocator().dupe(u8, "{\"name\":\"Sea Mount\"}");
    client.done(&names, .{ .status = 200, .body = body });
    client.step(&names, &photos, &.{}, transport, "");
    try std.testing.expectEqual(@as(usize, 1), requests);
    try std.testing.expectEqualStrings("Sea Mount", client.near(&names, .{ .lat = @as(f64, 0.00045), .lon = @as(f64, 0) }).?);
    try std.testing.expect(client.near(&names, .{ .lat = @as(f64, 0.002), .lon = @as(f64, 0) }) == null);
    names.answers.items[0].name = null;
    names.busy = true;
    client.done(&names, error.Io);
    client.step(&names, &photos, &.{}, transport, "");
    try std.testing.expectEqual(@as(usize, 1), requests);
    const sign = @import("sign_in.zig");
    defer sign.account.deinit();
    sign.account.state = .signed_in;
    client.done(&names, .{ .status = 401, .body = try names.arena.allocator().dupe(u8, "{}") });
    try std.testing.expectEqual(.signed_out, sign.account.state);
    try std.testing.expectEqual(@as(usize, 0), names.answers.items.len);
    client.step(&names, &photos, &.{}, transport, "");
    try std.testing.expectEqual(@as(usize, 2), requests);
    try std.testing.expectEqualStrings("/heronin/api/place?lat=0.000&lon=0.000", pending_url);
}

test "places answers grow within budget and unchanged scans are skipped" {
    const Fake = struct {
        fn ask(ptr: *anyopaque, _: std.mem.Allocator, _: http.Request, _: http.DoneFn, _: ?*anyopaque) core.vfs.Error!http.Job {
            const count: *usize = @ptrCast(@alignCast(ptr));
            count.* += 1;
            return .{ .id = 1 };
        }
    };
    var names: client.Names = .{};
    defer names.deinit();
    var count: usize = 0;
    const transport: http.Transport = .{ .ptr = &count, .vtable = &.{ .request = Fake.ask, .cancel = cancel, .pump = pump } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var photos: [200]model.Photo = undefined;
    for (&photos, 0..) |*photo, i| {
        photo.* = .{ .id = try std.fmt.allocPrint(arena.allocator(), "p{d}", .{i}), .md5 = .{ .bytes = @splat(0) }, .name = "", .w = 4, .h = 3, .bytes = 1, .place = .{ .lat = @as(f64, @floatFromInt(i / 20)) * 0.009, .lon = @as(f64, @floatFromInt(i % 20)) * 0.009 } };
    }
    const body = try names.arena.allocator().dupe(u8, "{\"name\":\"X\"}");
    for (photos) |_| {
        client.step(&names, &photos, &.{}, transport, "");
        client.done(&names, .{ .status = 200, .body = body });
    }
    try std.testing.expectEqual(@as(usize, 200), names.answers.items.len);
    std.debug.print("places arena capacity: {d} bytes\n", .{names.arena.queryCapacity()});
    try std.testing.expect(names.arena.queryCapacity() < 128 * 1024);
    client.step(&names, &photos, &.{}, transport, "");
    client.step(&names, &photos, &.{}, transport, "");
    try std.testing.expectEqual(@as(usize, 200), count);
    try std.testing.expectEqual(@as(usize, 0), names.scanned.?.saved_len);
    const saved = [_]model.Place{.{ .id = 1, .name = "Saved", .lat = 0, .lon = 0 }};
    client.step(&names, &photos, &saved, transport, "");
    try std.testing.expectEqual(@as(usize, 1), names.scanned.?.saved_len);
    const copy = try arena.allocator().dupe(model.Photo, &photos);
    client.step(&names, copy, &saved, transport, "");
    try std.testing.expect(names.scanned.?.photos == copy.ptr);
    try std.testing.expect(names.scanned.?.photos != photos[0..].ptr);
    try std.testing.expectEqual(@as(usize, 200), count);
}
