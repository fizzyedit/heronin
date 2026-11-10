const std = @import("std");
pub const Tokens = struct { access_token: []const u8, expires_in: u32, refresh_token: ?[]const u8 = null, id_token: []const u8 };
pub const Google = struct {
    ctx: *anyopaque,
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
        return .{ .ctx = self, .exchangeFn = exchange };
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
