test {
    _ = @import("app_session_tests.zig");
    _ = @import("drive_link_tests.zig");
    _ = @import("sign_in_tests.zig");
    _ = @import("views/agent.zig");
    _ = @import("tag_tests.zig");
    _ = @import("import_tests.zig");
    _ = @import("store_tests.zig");
    _ = @import("drive_store_tests.zig");
    _ = @import("drive_props_tests.zig");
    _ = @import("library_tests.zig");
}
const std = @import("std");
const http = @import("core").vfs.http;
const settings = @import("agent_settings.zig");
const t = std.testing;
var sent: http.Request = undefined;
var done: http.DoneFn = undefined;
fn request(_: *anyopaque, _: std.mem.Allocator, req: http.Request, cb: http.DoneFn, _: ?*anyopaque) @import("core").vfs.Error!http.Job {
    sent = req;
    done = cb;
    return .{ .id = 1 };
}
fn reply(status: u16, body: []const u8) !void {
    done(null, .{ .status = status, .body = try t.allocator.dupe(u8, body) });
}
fn nothing(_: *anyopaque) void {}
fn cancel(_: *anyopaque, _: http.Job) void {}
test "agent settings load, save the fields with an empty key, zero the key once saved" {
    var dummy: u8 = 0;
    settings.allocator = t.allocator;
    defer settings.deinit();
    const s = &settings.state;
    settings.load(.{ .ptr = &dummy, .vtable = &.{ .request = request, .cancel = cancel, .pump = nothing } }, "http://127.0.0.1:8790");
    try t.expectEqualStrings("http://127.0.0.1:8790/heronin/api/agent", sent.url);
    try reply(200, "{\"address\":\"https://agent.example.invalid\",\"wrap\":false,\"model\":\"m\",\"has_key\":true}");
    try t.expectEqualStrings("https://agent.example.invalid", settings.text(&s.address));
    try t.expect(s.connected and s.has_key);
    s.has_key = false;
    settings.save();
    try t.expectEqualStrings("{\"address\":\"https://agent.example.invalid\",\"key\":\"\",\"wrap\":false,\"model\":\"m\"}", sent.body);
    try reply(204, "");
    try t.expect(s.saved == .saved and !s.has_key);
    @memcpy(s.key[0..2], "k1");
    settings.save();
    try t.expect(std.mem.indexOf(u8, sent.body, "\"key\":\"k1\"") != null);
    try reply(500, "{}");
    try t.expect(s.saved == .failed);
    settings.save();
    try reply(204, "");
    try t.expect(s.saved == .saved and s.has_key and std.mem.allEqual(u8, &s.key, 0));
}
