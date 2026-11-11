const std = @import("std");
const sign = @import("sign_in.zig");
const core = @import("core");
const http = core.vfs.http;
var allocator: std.mem.Allocator = undefined;
var callback: http.DoneFn = undefined;
var context: ?*anyopaque = null;
var req: http.Request = undefined;
var count: usize = 0;
fn request(_: *anyopaque, a: std.mem.Allocator, r: http.Request, cb: http.DoneFn, ctx: ?*anyopaque) core.vfs.Error!http.Job {
    allocator = a;
    req = r;
    callback = cb;
    context = ctx;
    count += 1;
    return .{ .id = count };
}
fn cancel(_: *anyopaque, _: http.Job) void {}
fn pump(_: *anyopaque) void {}
fn answer(status: u16, body: []const u8) !void {
    callback(context, .{ .status = status, .body = try allocator.dupe(u8, body) });
}
test "web account checks popup logout and session loss" {
    sign.account = .{ .arena = .init(std.testing.allocator) };
    defer sign.account.deinit();
    var dummy: u8 = 0;
    const transport: http.Transport = .{ .ptr = &dummy, .vtable = &.{ .request = request, .cancel = cancel, .pump = pump } };
    sign.check(transport, "");
    try std.testing.expectEqual(.GET, req.method);
    try std.testing.expect(std.mem.endsWith(u8, req.url, "/heronin/api/token"));
    try answer(200, "{\"access_token\":\"x\",\"expires_in\":3600,\"email\":\"bird@example.invalid\"}");
    try std.testing.expectEqual(.signed_in, sign.account.state);
    try std.testing.expectEqualStrings("bird@example.invalid", sign.account.email.?);
    sign.check(transport, "");
    try answer(502, "{}");
    try std.testing.expectEqual(.signed_in, sign.account.state);
    try std.testing.expectEqualStrings("bird@example.invalid", sign.account.email.?);
    sign.signOut();
    try std.testing.expectEqual(.POST, req.method);
    try std.testing.expect(std.mem.endsWith(u8, req.url, "/heronin/api/logout"));
    try std.testing.expectEqual(@as(usize, 0), req.body.len);
    try answer(500, "{}");
    try std.testing.expectEqual(.signed_in, sign.account.state);
    try std.testing.expectEqual(.sign_out, sign.account.failed);
    sign.signOut();
    try answer(204, "");
    try std.testing.expectEqual(.signed_out, sign.account.state);
    try std.testing.expect(sign.account.email == null);
    for ([_]u16{ 401, 503 }) |status| {
        sign.check(transport, "");
        try answer(status, "{}");
        try std.testing.expectEqual(@as(@TypeOf(sign.account.state), if (status == 401) .signed_out else .off), sign.account.state);
    }
    sign.check(transport, "");
    callback(context, error.Io);
    try std.testing.expectEqual(.off, sign.account.state);
    try std.testing.expect(sign.ready());
    sign.lost();
    try std.testing.expectEqual(.off, sign.account.state);
    sign.account.state = .signed_in;
    try std.testing.expect(sign.ready());
    sign.lost();
    try std.testing.expect(!sign.ready());
    try std.testing.expectEqual(.signed_out, sign.account.state);
    sign.opened(null, null);
    try std.testing.expectEqual(.signed_out, sign.account.state);
    try std.testing.expectEqual(.popup, sign.account.failed);
    const before = count;
    sign.opened(null, try sign.account.arena.allocator().dupe(u8, "?signed_in=1"));
    try std.testing.expectEqual(.checking, sign.account.state);
    try std.testing.expectEqual(before + 1, count);
    try std.testing.expectEqual(.GET, req.method);
}
