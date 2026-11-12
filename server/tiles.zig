const std = @import("std");
pub const Tile = struct { z: u5, x: u32, y: u32 };
pub fn parse(path: []const u8) ?Tile {
    if (!std.mem.startsWith(u8, path, "/api/tile/") or !std.mem.endsWith(u8, path, ".png")) return null;
    var parts = std.mem.splitScalar(u8, path[10 .. path.len - 4], '/');
    var values: [3]u32 = undefined;
    for (&values) |*value| {
        const part = parts.next() orelse return null;
        if (part.len == 0) return null;
        for (part) |c| if (!std.ascii.isDigit(c)) return null;
        value.* = std.fmt.parseInt(u32, part, 10) catch return null;
    }
    if (parts.next() != null or values[0] < 3 or values[0] > 17) return null;
    const z: u5 = @intCast(values[0]);
    if (values[1] >= @as(u32, 1) << z or values[2] >= @as(u32, 1) << z) return null;
    return .{ .z = z, .x = values[1], .y = values[2] };
}
pub const Answer = union(enum) { png: []const u8, missing, unavailable };
pub const Upstream = struct { status: std.http.Status, body: []const u8 };
pub const Fetch = struct { ctx: ?*anyopaque, fetchFn: *const fn (?*anyopaque, std.Io, std.mem.Allocator, []const u8) anyerror!Upstream };
pub const Tiles = struct {
    io: std.Io,
    dir: []const u8,
    fetch: Fetch = .{ .ctx = null, .fetchFn = real },
    pub fn get(self: *Tiles, a: std.mem.Allocator, tile: Tile, now: i64) !Answer {
        const path = try std.fmt.allocPrint(a, "{s}/{d}/{d}/{d}.png", .{ self.dir, tile.z, tile.x, tile.y });
        const cwd = std.Io.Dir.cwd();
        const stat = cwd.statFile(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (stat) |s| if (@as(i128, now) - s.mtime.toSeconds() < 30 * std.time.s_per_day) return .{ .png = try cwd.readFileAlloc(self.io, path, a, .limited(256 * 1024)) };
        const url = try std.fmt.allocPrint(a, "https://tile.openstreetmap.org/{d}/{d}/{d}.png", .{ tile.z, tile.x, tile.y });
        const upstream = self.fetch.fetchFn(self.fetch.ctx, self.io, a, url) catch return .unavailable;
        if (upstream.status == .not_found) return .missing;
        if (upstream.status != .ok) return .unavailable;
        try cwd.createDirPath(self.io, std.fs.path.dirname(path).?);
        var file = try cwd.createFileAtomic(self.io, path, .{ .replace = true });
        defer file.deinit(self.io);
        try file.file.writeStreamingAll(self.io, upstream.body);
        try file.replace(self.io);
        return .{ .png = upstream.body };
    }
};
fn real(_: ?*anyopaque, io: std.Io, a: std.mem.Allocator, url: []const u8) !Upstream {
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    var body = std.Io.Writer.fixed(try a.alloc(u8, 256 * 1024));
    const result = try client.fetch(.{ .location = .{ .url = url }, .redirect_behavior = .not_allowed, .headers = .{ .user_agent = .{ .override = "Heronin/0.1 (+https://github.com/fizzyedit/heronin)" } }, .response_writer = &body });
    return .{ .status = result.status, .body = body.buffered() };
}
