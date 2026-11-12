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
fn noTokenEvent(_: *anyopaque, event: @import("fizzy_sdk").Host.events.Event) void {
    std.testing.expect(std.mem.indexOf(u8, event.payload, "tok-1") == null) catch unreachable;
}
test "token response reaches only the drive command arguments" {
    const sdk = @import("fizzy_sdk");
    const drive = @import("drive_link.zig");
    var host = sdk.Host.init(std.testing.allocator);
    defer host.deinit();
    var files = core.FileTable.init(std.testing.allocator, std.testing.io);
    defer files.deinit();
    host.files = &files;
    var mem = try core.vfs.Mem.init(std.testing.allocator);
    defer mem.deinit();
    defer drive.link.deinit();
    drive.link.host = &host;
    var stub: @import("drive_link_tests.zig").Stub = .{ .host = &host, .mem = &mem };
    defer stub.deinit();
    var plugin: sdk.Plugin = undefined;
    try stub.register(&plugin);
    try host.subscribe(.{ .event = "*", .owner = &plugin, .handler = noTokenEvent });
    sign.account = .{ .arena = .init(std.testing.allocator) };
    defer sign.account.deinit();
    var dummy: u8 = 0;
    const transport: http.Transport = .{ .ptr = &dummy, .vtable = &.{ .request = request, .cancel = cancel, .pump = pump } };
    sign.check(transport, "");
    try answer(200, "{\"access_token\":\"tok-1\",\"expires_in\":3600,\"email\":\"a@example.invalid\"}");
    try std.testing.expect(std.mem.indexOf(u8, stub.seen.?, "tok-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.seen.?, "3600") != null);
    host.deliverEvents();
    try std.testing.expectEqualStrings("a@example.invalid", sign.account.email.?);
    drive.link.retry = true;
    const before = count;
    sign.step();
    sign.step();
    try std.testing.expectEqual(before + 1, count);
    try answer(200, "{\"access_token\":\"tok-1\",\"expires_in\":3600,\"email\":\"a@example.invalid\"}");
    sign.signOut();
    drive.link.token_due = true;
    sign.step();
    try std.testing.expectEqual(.signed_in, sign.account.state);
    try answer(204, "");
    try std.testing.expectEqual(.absent, drive.link.state);
    try std.testing.expect(!stub.mounted);
    sign.lost();
    host.deliverEvents();
}
fn openURL(_: @import("dvui").OpenURLOptions) bool {
    return false;
}
var seen_cookie: [80]u8 = undefined;
var seen_cookie_len: usize = 0;
fn cookieRequest(
    ptr: *anyopaque,
    a: std.mem.Allocator,
    r: http.Request,
    cb: http.DoneFn,
    ctx: ?*anyopaque,
) core.vfs.Error!http.Job {
    if (r.headers.len > 0) {
        seen_cookie_len = r.headers[r.headers.len - 1].value.len;
        @memcpy(seen_cookie[0..seen_cookie_len], r.headers[r.headers.len - 1].value);
    }
    return request(ptr, a, r, cb, ctx);
}
test "native claim installs cookie token check carries it and logout clears it" {
    const session = @import("app_session.zig");
    const t = std.testing;
    sign.account = .{ .arena = .init(t.allocator) };
    defer sign.account.deinit();
    @import("dvui").io = std.testing.io;
    sign.open_url = openURL;
    defer sign.open_url = @import("dvui").openURL;
    var dummy: u8 = 0;
    session.cookie = .{ .inner = .{
        .ptr = &dummy,
        .vtable = &.{ .request = cookieRequest, .cancel = cancel, .pump = pump },
    } };
    defer session.cookie.value = null;
    sign.check(session.cookie.transport(), "http://127.0.0.1:1");
    try answer(401, "");
    sign.session_changed = false;
    sign.open();
    try t.expectEqual(.opening, sign.account.state);
    try t.expectEqual(.waiting, sign.claim.state);
    sign.claim.state = .done;
    sign.claim.session = @splat('a');
    sign.step();
    try t.expectEqual(sign.claim.session, session.cookie.value);
    try t.expect(sign.session_changed);
    const expected: [64]u8 = @splat('a');
    try t.expectEqualStrings("heronin_session=" ++ expected, seen_cookie[0..seen_cookie_len]);
    try answer(502, "");
    sign.session_changed = false;
    sign.signOut();
    try answer(204, "");
    try t.expect(session.cookie.value == null and sign.session_changed);
    session.cookie.value = @splat('a');
    sign.session_changed = false;
    sign.check(session.cookie.transport(), "http://127.0.0.1:1");
    try answer(401, "");
    try t.expect(session.cookie.value == null and sign.session_changed);
}
