const std = @import("std");
const session = @import("app_session.zig");
const http = @import("core").vfs.http;
const t = std.testing;
const aa: [64]u8 = @splat('a');
const zz: [64]u8 = @splat('0');
var req: http.Request = undefined;
var headers: [8]http.Header = undefined;
var cookie_value: [80]u8 = undefined;
var url: [256]u8 = undefined;
var body: [128]u8 = undefined;
var cb: http.DoneFn = undefined;
var ctx: ?*anyopaque = null;
var calls: usize = 0;
var cancelled = false;
var pumped = false;
fn request(
    _: *anyopaque,
    _: std.mem.Allocator,
    r: http.Request,
    done: http.DoneFn,
    context: ?*anyopaque,
) @import("core").vfs.Error!http.Job {
    req = r;
    @memcpy(headers[0..r.headers.len], r.headers);
    req.headers = headers[0..r.headers.len];
    if (r.headers.len > 1) {
        @memcpy(cookie_value[0..r.headers[1].value.len], r.headers[1].value);
        headers[1].value = cookie_value[0..r.headers[1].value.len];
    }
    @memcpy(url[0..r.url.len], r.url);
    req.url = url[0..r.url.len];
    @memcpy(body[0..r.body.len], r.body);
    req.body = body[0..r.body.len];
    cb, ctx = .{ done, context };
    calls += 1;
    return .{ .id = 1 };
}
fn cancel(_: *anyopaque, _: http.Job) void {
    cancelled = true;
}
fn pump(_: *anyopaque) void {
    pumped = true;
}
fn answer(status: u16, value: []const u8) !void {
    cb(ctx, .{ .status = status, .body = try t.allocator.dupe(u8, value) });
}
fn transport(dummy: *u8) http.Transport {
    return .{ .ptr = dummy, .vtable = &.{ .request = request, .cancel = cancel, .pump = pump } };
}
fn ignore(_: ?*anyopaque, _: @import("core").vfs.Error!http.Response) void {}
test "cookie forwards headers cancel and pump and limits caller headers" {
    var dummy: u8 = 0;
    var c: session.Cookied = .{ .inner = transport(&dummy) };
    const tr = c.transport();
    const content = http.Header{ .name = "Content-Type", .value = "application/json" };
    const r: http.Request = .{ .method = .POST, .url = "", .headers = &.{content} };
    const job = try tr.request(t.allocator, r, ignore, null);
    try t.expectEqual(@as(usize, 1), req.headers.len);
    try t.expectEqualStrings(content.value, req.headers[0].value);
    c.value = @splat('a');
    _ = try tr.request(t.allocator, r, ignore, null);
    try t.expectEqualStrings("Content-Type", req.headers[0].name);
    try t.expectEqualStrings("Cookie", req.headers[1].name);
    try t.expectEqualStrings("heronin_session=" ++ aa, req.headers[1].value);
    try t.expectError(error.Io, tr.request(t.allocator, .{
        .method = .GET,
        .url = "",
        .headers = &(@as([8]http.Header, @splat(content))),
    }, ignore, null));
    tr.cancel(job);
    tr.pump();
    try t.expect(cancelled and pumped);
}
test "claim hashes verifier polls and accepts session" {
    var claim: session.Claim = .{};
    const login = try claim.begin(@splat(0), t.allocator, "http://example.invalid/");
    defer t.allocator.free(login);
    try t.expectEqualStrings(&zz, &claim.verifier);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&zz, &hash, .{});
    try t.expectEqualStrings(
        "http://example.invalid/heronin/api/login?app=" ++ std.fmt.bytesToHex(hash, .lower),
        login,
    );
    var dummy: u8 = 0;
    calls = 0;
    claim.step(0, transport(&dummy), "");
    try t.expectEqual(@as(usize, 0), calls);
    claim.step(2000, transport(&dummy), "");
    try t.expectEqual(.POST, req.method);
    try t.expectEqualStrings("/heronin/api/app-session", req.url);
    try t.expectEqualStrings("{\"verifier\":\"" ++ zz ++ "\"}", req.body);
    claim.step(4000, transport(&dummy), "");
    try t.expectEqual(@as(usize, 1), calls);
    try answer(404, "");
    claim.step(4000, transport(&dummy), "");
    try t.expectEqual(@as(usize, 2), calls);
    try answer(200, "{\"session\":\"" ++ aa ++ "\"}");
    try t.expectEqual(.done, claim.state);
    try t.expectEqualStrings(&aa, &claim.session.?);
}
test "claim stops after answered attempts and rejects short session" {
    var claim: session.Claim = .{};
    const login = try claim.begin(@splat(0), t.allocator, "");
    defer t.allocator.free(login);
    var dummy: u8 = 0;
    for (0..150) |i| {
        claim.step(@as(i128, i + 1) * 2000, transport(&dummy), "");
        try answer(404, "");
    }
    try t.expectEqual(.failed, claim.state);
    claim.state = .waiting;
    claim.step(400000, transport(&dummy), "");
    try answer(200, "{\"session\":\"short\"}");
    try t.expectEqual(.failed, claim.state);
}
test "claim keeps polling after transport errors and other statuses" {
    var claim: session.Claim = .{};
    const login = try claim.begin(@splat(0), t.allocator, "");
    defer t.allocator.free(login);
    var dummy: u8 = 0;
    claim.step(2000, transport(&dummy), "");
    cb(ctx, error.Io);
    try t.expectEqual(.waiting, claim.state);
    claim.step(4000, transport(&dummy), "");
    try answer(503, "");
    try t.expectEqual(.waiting, claim.state);
}
