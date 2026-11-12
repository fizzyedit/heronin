const std = @import("std");
const tiles = @import("tiles.zig");
const expect = std.testing.expect;
const strings = std.testing.expectEqualStrings;
const io = std.testing.io;
const Fake = struct {
    calls: usize = 0,
    url: []const u8 = "",
    status: std.http.Status = .ok,
    fail: bool = false,
    fn fetch(ctx: ?*anyopaque, _: std.Io, a: std.mem.Allocator, url: []const u8) !tiles.Upstream {
        const self: *Fake = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.url = try a.dupe(u8, url);
        if (self.fail) return error.WriteFailed;
        return .{ .status = self.status, .body = "PNG" };
    }
    fn cache(self: *Fake, a: std.mem.Allocator, tmp: *std.testing.TmpDir) !tiles.Tiles {
        return .{ .io = io, .dir = try std.fs.path.join(a, &.{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path, "tiles" }), .fetch = .{ .ctx = self, .fetchFn = fetch } };
    }
};
test "tile parse exact decimal paths and bounds" {
    try expect(tiles.parse("/api/tile/3/7/0.png") != null);
    try expect(tiles.parse("/api/tile/17/131071/131071.png") != null);
    for ([_][]const u8{ "2/0/0.png", "18/0/0.png", "3/8/0.png", "3/0/8.png", "3/0/0", "3/0/0/0.png", "3/-1/0.png", "3/a/0.png", "3/../0.png" }) |suffix| {
        var buf: [80]u8 = undefined;
        try expect(tiles.parse(try std.fmt.bufPrint(&buf, "/api/tile/{s}", .{suffix})) == null);
    }
}
test "tile cache miss hit and thirty day expiry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fake: Fake = .{};
    var cache = try fake.cache(a, &tmp);
    const tile = tiles.parse("/api/tile/12/655/1430.png").?;
    const now = std.Io.Clock.real.now(io).toSeconds();
    try strings("PNG", (try cache.get(a, tile, now)).png);
    try strings("https://tile.openstreetmap.org/12/655/1430.png", fake.url);
    try strings("PNG", try tmp.dir.readFileAlloc(io, "tiles/12/655/1430.png", a, .limited(256 * 1024)));
    fake.fail = true;
    try strings("PNG", (try cache.get(a, tile, now)).png);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try expect(try cache.get(a, tile, (try tmp.dir.statFile(io, "tiles/12/655/1430.png", .{})).mtime.toSeconds() + 30 * std.time.s_per_day) == .unavailable);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
}
test "tile missing and failed fetch are never stored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fake: Fake = .{ .status = .not_found };
    var cache = try fake.cache(a, &tmp);
    const tile = tiles.parse("/api/tile/12/655/1430.png").?;
    try expect(try cache.get(a, tile, 0) == .missing);
    try expect(try cache.get(a, tile, 0) == .missing);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    fake.fail = true;
    try expect(try cache.get(a, tile, 0) == .unavailable);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "tiles/12/655/1430.png", .{}));
}
test "tile route PNG headers invalid method and unconfigured cache" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fake: Fake = .{};
    var cache = try fake.cache(a, &tmp);
    const raws = [_][]const u8{ "GET /heronin/api/tile/12/655/1430.png", "GET /heronin/api/tile/18/0/0.png", "POST /heronin/api/tile/3/0/0.png", "GET /heronin/api/tile/3/0/0.png" };
    for (raws, [_][]const u8{ "200", "400", "405", "503" }, 0..) |raw, code, i| {
        var reader = std.Io.Reader.fixed(try std.fmt.allocPrint(a, "{s} HTTP/1.1\r\nContent-Length: 0\r\n\r\n", .{raw}));
        var writer: std.Io.Writer.Allocating = .init(a);
        var http = std.http.Server.init(&reader, &writer.writer);
        var request = try http.receiveHead();
        var tagger: @import("fake_tagger.zig").Fake = .{};
        try @import("main.zig").serve(&request, a, tagger.tagger(), null, 0.85, 0, .{}, null, null, if (i == 3) null else &cache);
        try expect(std.mem.startsWith(u8, writer.written()[9..], code));
        if (i == 0) {
            try expect(std.mem.indexOf(u8, writer.written(), "content-type: image/png") != null);
            try expect(std.mem.indexOf(u8, writer.written(), "cache-control: private, max-age=604800") != null);
            try expect(std.mem.endsWith(u8, writer.written(), "PNG"));
        }
    }
}
