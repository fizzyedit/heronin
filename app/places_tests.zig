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
    names.answers[0].name = null;
    names.busy = true;
    client.done(&names, error.Io);
    client.step(&names, &photos, &.{}, transport, "");
    try std.testing.expectEqual(@as(usize, 1), requests);
}
