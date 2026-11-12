const std = @import("std");
const http = @import("core").vfs.http;
const a = std.heap.page_allocator;
pub const Key = struct { z: u5, x: u32, y: u32 };
pub var cache: Cache = .{};
pub const Cache = struct {
    entries: [64]struct {
        key: ?Key = null,
        state: enum { loading, ready, failed } = .failed,
        png: []const u8 = &.{},
        url: []const u8 = &.{},
        used: u64 = 0,
        job: ?http.Job = null,
        owner: ?http.Transport = null,
    } = @splat(.{}),
    wanted: [16]Key = undefined,
    len: usize = 0,
    clock: u64 = 0,
    pub fn deinit(self: *Cache) void {
        for (&self.entries) |*entry| {
            if (entry.job) |job| entry.owner.?.cancel(job);
            a.free(entry.png);
            a.free(entry.url);
        }
        self.* = .{};
    }
};
pub fn get(key: Key) ?[]const u8 {
    for (&cache.entries) |*entry| if (std.meta.eql(entry.key, @as(?Key, key))) {
        cache.clock +%= 1;
        entry.used = cache.clock;
        return if (entry.state == .ready) entry.png else null;
    };
    for (cache.wanted[0..cache.len]) |wanted| if (std.meta.eql(wanted, key)) return null;
    if (cache.len < cache.wanted.len) {
        cache.wanted[cache.len] = key;
        cache.len += 1;
    }
    return null;
}
pub fn step(transport: http.Transport, base: ?[]const u8) void {
    defer cache.len = 0;
    for (cache.wanted[0..cache.len]) |key| {
        var active: usize = 0;
        var slot: ?usize = null;
        var present = false;
        for (cache.entries, 0..) |entry, i| {
            if (std.meta.eql(entry.key, @as(?Key, key))) present = true;
            if (entry.state == .loading) {
                active += 1;
            } else if (slot == null or entry.used < cache.entries[slot.?].used) slot = i;
        }
        if (present or active >= 2) continue;
        const entry = &cache.entries[slot orelse continue];
        a.free(entry.png);
        a.free(entry.url);
        cache.clock +%= 1;
        entry.* = .{ .key = key, .used = cache.clock, .owner = transport };
        var path: [64]u8 = undefined;
        const suffix = std.fmt.bufPrint(&path, "tile/{d}/{d}/{d}.png", .{ key.z, key.x, key.y }) catch continue;
        entry.url = @import("tag_queue.zig").serverUrl(a, base, suffix) catch continue;
        entry.state = .loading;
        entry.job = transport.request(a, .{ .method = .GET, .url = entry.url }, done, entry) catch {
            entry.state = .failed;
            continue;
        };
    }
}
fn done(ctx: ?*anyopaque, result: @import("core").vfs.Error!http.Response) void {
    const entry: *@typeInfo(@TypeOf(cache.entries)).array.child = @ptrCast(@alignCast(ctx.?));
    entry.job = null;
    entry.state = .failed;
    const response = result catch return;
    if (response.status == 200) {
        entry.png = response.body;
        entry.state = .ready;
    } else {
        response.deinit(a);
        if (response.status == 401) @import("sign_in.zig").lost();
    }
}
