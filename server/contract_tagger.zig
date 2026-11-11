const std = @import("std");
const wire = @import("tagger.zig");
const refuse = @import("claude_tagger.zig").Claude.refuse;
pub const Contract = struct {
    io: std.Io,
    address: []const u8,
    key: []const u8 = "",
    post: Post = .{ .ctx = null, .postFn = send },
    pub const Reply = struct { status: u16, body: []const u8 };
    pub const Post = struct { ctx: ?*anyopaque, postFn: *const fn (?*anyopaque, *Contract, std.mem.Allocator, []const u8) anyerror!Reply };
    pub fn tagger(self: *Contract) wire.Tagger {
        return .{ .ctx = self, .tagFn = tag };
    }
    pub fn headers(self: *const Contract, allocator: std.mem.Allocator) ![]const std.http.Header {
        const all = [_]std.http.Header{ .{ .name = "content-type", .value = "application/json" }, .{ .name = "authorization", .value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.key}) } };
        return allocator.dupe(std.http.Header, all[0..if (self.key.len == 0) 1 else 2]);
    }
    pub fn body(allocator: std.mem.Allocator, r: wire.Request) ![]u8 {
        const place = if (r.place) |p| (if (@abs(p.lat) <= 90 and @abs(p.lon) <= 180) p else null) else null;
        return std.json.Stringify.valueAlloc(allocator, .{ .image = r.image, .taken_at = r.taken_at, .place = place }, .{});
    }
    fn tag(ctx: *anyopaque, allocator: std.mem.Allocator, request: wire.Request) !wire.Answer {
        const self: *Contract = @ptrCast(@alignCast(ctx));
        const reply = try self.post.postFn(self.post.ctx, self, allocator, try body(allocator, request));
        switch (reply.status) {
            200 => return std.json.parseFromSliceLeaky(wire.Answer, allocator, reply.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch refuse(error.BadAnswer, "agent answer unreadable"),
            401, 403 => return refuse(error.Unauthorized, "agent refused the key"),
            429, 500...599 => return refuse(error.Unavailable, "agent busy"),
            else => return refuse(error.BadAnswer, "agent answer unreadable"),
        }
    }
    fn send(_: ?*anyopaque, self: *Contract, allocator: std.mem.Allocator, payload: []const u8) !Reply {
        var client: std.http.Client = .{ .allocator = allocator, .io = self.io };
        defer client.deinit();
        var response = std.Io.Writer.fixed(try allocator.alloc(u8, 64 * 1024));
        const url = try std.fmt.allocPrint(allocator, "{s}/tag", .{std.mem.trimEnd(u8, self.address, "/")});
        const result = client.fetch(.{ .location = .{ .url = url }, .method = .POST, .payload = payload, .redirect_behavior = .not_allowed, .headers = .{ .content_type = .omit }, .extra_headers = try self.headers(allocator), .response_writer = &response }) catch |err|
            return refuse(if (err == error.WriteFailed) error.BadAnswer else err, "agent unreachable");
        return .{ .status = @backingInt(result.status), .body = response.buffered() };
    }
};
