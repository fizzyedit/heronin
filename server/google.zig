const std = @import("std");
pub const Tokens = struct { access_token: []const u8, expires_in: u32, refresh_token: ?[]const u8 = null, id_token: []const u8 };
pub const Fresh = struct { access_token: []const u8, expires_in: u32 };
pub const Google = struct {
    ctx: *anyopaque,
    refreshFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!Fresh,
    revokeFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!void,
    exchangeFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8, []const u8) anyerror!Tokens,
};
pub fn formBody(a: std.mem.Allocator, fields: []const [2][]const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    for (fields, 0..) |field, i| {
        if (i != 0) try out.writer.writeByte('&');
        try out.writer.print("{s}=", .{field[0]});
        for (field[1]) |c| {
            if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~", c) != null) try out.writer.writeByte(c) else try out.writer.print("%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice();
}
pub const Real = struct {
    io: std.Io,
    id: []const u8,
    secret: []const u8,
    pub fn google(self: *Real) Google {
        return .{ .ctx = self, .exchangeFn = exchange, .refreshFn = refresh, .revokeFn = revoke };
    }
    fn refresh(ctx: *anyopaque, a: std.mem.Allocator, token: []const u8) !Fresh {
        const self: *Real = @ptrCast(@alignCast(ctx));
        const body = try formBody(a, &.{ .{ "grant_type", "refresh_token" }, .{ "refresh_token", token }, .{ "client_id", self.id }, .{ "client_secret", self.secret } });
        return (try std.json.parseFromSlice(Fresh, a, try self.post(a, "https://oauth2.googleapis.com/token", body), .{ .allocate = .alloc_always, .ignore_unknown_fields = true })).value;
    }
    fn revoke(ctx: *anyopaque, a: std.mem.Allocator, token: []const u8) !void {
        const self: *Real = @ptrCast(@alignCast(ctx));
        _ = try self.post(a, "https://oauth2.googleapis.com/revoke", try formBody(a, &.{.{ "token", token }}));
    }
    fn post(self: *Real, a: std.mem.Allocator, url: []const u8, body: []const u8) ![]const u8 {
        var client: std.http.Client = .{ .allocator = a, .io = self.io };
        defer client.deinit();
        var response: std.Io.Writer.Allocating = .init(a);
        const result = try client.fetch(.{ .location = .{ .url = url }, .method = .POST, .payload = body, .redirect_behavior = .not_allowed, .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } }, .response_writer = &response.writer });
        if (result.status == .bad_request) {
            const parsed = std.json.parseFromSlice(struct { @"error": []const u8 }, a, response.written(), .{ .ignore_unknown_fields = true }) catch return error.Google;
            if (std.mem.eql(u8, parsed.value.@"error", "invalid_grant")) return error.InvalidGrant;
        }
        if (result.status != .ok) return error.Google;
        return response.toOwnedSlice();
    }
    fn exchange(ctx: *anyopaque, a: std.mem.Allocator, code: []const u8, verifier: []const u8, redirect: []const u8) !Tokens {
        const self: *Real = @ptrCast(@alignCast(ctx));
        var client: std.http.Client = .{ .allocator = a, .io = self.io };
        defer client.deinit();
        const body = try formBody(a, &.{ .{ "grant_type", "authorization_code" }, .{ "code", code }, .{ "code_verifier", verifier }, .{ "redirect_uri", redirect }, .{ "client_id", self.id }, .{ "client_secret", self.secret } });
        defer a.free(body);
        var response: std.Io.Writer.Allocating = .init(a);
        defer response.deinit();
        const result = try client.fetch(.{ .location = .{ .url = "https://oauth2.googleapis.com/token" }, .method = .POST, .payload = body, .redirect_behavior = .not_allowed, .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } }, .response_writer = &response.writer });
        if (result.status != .ok) return error.Exchange;
        return (try std.json.parseFromSlice(Tokens, a, response.written(), .{ .allocate = .alloc_always, .ignore_unknown_fields = true })).value;
    }
};
