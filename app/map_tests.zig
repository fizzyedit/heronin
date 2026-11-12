const std = @import("std");
const core = @import("core");
const http = core.vfs.http;
const map = @import("map_tiles.zig");
const t = std.testing;
var calls: usize = 0;
var callbacks: [2]http.DoneFn = undefined;
var contexts: [2]?*anyopaque = undefined;
var url: []const u8 = "";
var cancelled: usize = 0;
fn request(_: *anyopaque, _: std.mem.Allocator, req: http.Request, cb: http.DoneFn, ctx: ?*anyopaque) core.vfs.Error!http.Job {
    const i = calls % 2;
    callbacks[i] = cb;
    contexts[i] = ctx;
    if (calls == 0) url = req.url;
    calls += 1;
    return .{ .id = calls };
}
fn cancel(_: *anyopaque, _: http.Job) void {
    cancelled += 1;
}
fn pump(_: *anyopaque) void {}
fn reply(i: usize, status: u16) !void {
    callbacks[i](contexts[i], .{ .status = status, .body = try std.heap.page_allocator.dupe(u8, "png") });
}
var dummy: u8 = 0;
const transport: http.Transport = .{ .ptr = &dummy, .vtable = &.{ .request = request, .cancel = cancel, .pump = pump } };
fn key(x: u32) map.Key {
    return .{ .z = 12, .x = x, .y = 7 };
}
test "map limits requests retains PNG and failures and evicts oldest" {
    defer map.cache.deinit();
    calls = 0;
    _ = map.get(key(0));
    _ = map.get(key(1));
    _ = map.get(key(2));
    map.step(transport, "");
    try t.expectEqual(@as(usize, 2), calls);
    try t.expectEqualStrings("/heronin/api/tile/12/0/7.png", url);
    try reply(0, 200);
    try reply(1, 502);
    try t.expectEqualStrings("png", map.get(key(0)).?);
    try t.expect(map.get(key(1)) == null);
    map.step(transport, "");
    try t.expectEqual(@as(usize, 2), calls);
    try t.expectEqualStrings("/heronin/api/tile/12/0/7.png", url);
    for (2..72) |x| {
        _ = map.get(key(@intCast(x)));
        map.step(transport, "");
        try reply((calls - 1) % 2, 200);
    }
    try t.expectEqualStrings("png", map.get(key(71)).?);
    try t.expect(map.get(key(0)) == null);
    map.step(transport, "");
    callbacks[(calls - 1) % 2](contexts[(calls - 1) % 2], error.Io);
    const failed_calls = calls;
    try t.expect(map.get(key(0)) == null);
    map.step(transport, "");
    try t.expectEqual(failed_calls, calls);
}
test "map unauthorized signs out and deinit cancels loading jobs" {
    const sign = @import("sign_in.zig");
    defer sign.account.deinit();
    defer map.cache.deinit();
    calls = 0;
    cancelled = 0;
    sign.account.state = .signed_in;
    _ = map.get(key(0));
    map.step(transport, "");
    try reply(0, 401);
    try t.expectEqual(.signed_out, sign.account.state);
    for (map.cache.entries) |entry| try t.expect(entry.job == null);
    _ = map.get(key(1));
    map.step(transport, "");
    map.cache.deinit();
    try t.expectEqual(@as(usize, 1), cancelled);
}
