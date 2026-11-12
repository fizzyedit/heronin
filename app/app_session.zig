const std = @import("std");
const http = @import("core").vfs.http;
const A = std.mem.Allocator;
const E = @import("core").vfs.Error;
pub var cookie: Cookied = undefined;
pub fn hex(value: []const u8) ?[64]u8 {
    if (value.len != 64) return null;
    for (value) |c| if (!std.ascii.isHex(c)) return null;
    return value[0..64].*;
}
pub const Cookied = struct {
    inner: http.Transport,
    value: ?[64]u8 = null,
    pub fn transport(self: *Cookied) http.Transport {
        return .{ .ptr = self, .vtable = &.{ .request = request, .cancel = cancel, .pump = pump } };
    }
    fn request(p: *anyopaque, a: A, r: http.Request, cb: http.DoneFn, c: ?*anyopaque) E!http.Job {
        const self: *Cookied = @ptrCast(@alignCast(p));
        if (r.headers.len > 7) return error.Io;
        var hs: [8]http.Header = undefined;
        @memcpy(hs[0..r.headers.len], r.headers);
        const v = "heronin_session=" ++ (self.value orelse @as([64]u8, @splat(0)));
        var copy = r;
        if (self.value != null) hs[r.headers.len] = .{ .name = "Cookie", .value = v };
        copy.headers = hs[0 .. r.headers.len + @intFromBool(self.value != null)];
        return self.inner.request(a, copy, cb, c);
    }
    fn cancel(ptr: *anyopaque, job: http.Job) void {
        @as(*Cookied, @ptrCast(@alignCast(ptr))).inner.cancel(job);
    }
    fn pump(ptr: *anyopaque) void {
        @as(*Cookied, @ptrCast(@alignCast(ptr))).inner.pump();
    }
};
pub const Claim = struct {
    verifier: [64]u8 = undefined,
    session: ?[64]u8 = null,
    state: enum { waiting, done, failed } = .waiting,
    next_ms: i128 = 2000,
    tries: u8 = 0,
    job: ?http.Job = null,
    a: A = undefined,
    pub fn begin(self: *Claim, random: [32]u8, a: A, base: []const u8) ![]const u8 {
        self.* = .{ .verifier = std.fmt.bytesToHex(random, .lower), .a = a };
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&self.verifier, &hash, .{});
        const path = "login?app=" ++ std.fmt.bytesToHex(hash, .lower);
        return @import("tag_queue.zig").serverUrl(a, base, path);
    }
    pub fn step(self: *Claim, now_ms: i128, tr: http.Transport, base: []const u8) void {
        if (self.state != .waiting or self.job != null or now_ms < self.next_ms) return;
        self.next_ms = now_ms +| 2000;
        self.tries +|= 1;
        const url = @import("tag_queue.zig").serverUrl(self.a, base, "app-session") catch return;
        defer self.a.free(url);
        const json = "{\"verifier\":\"" ++ self.verifier ++ "\"}";
        const h = &.{http.Header{ .name = "Content-Type", .value = "application/json" }};
        const req: http.Request = .{ .method = .POST, .url = url, .body = json, .headers = h };
        self.job = tr.request(self.a, req, answered, self) catch return answered(self, error.Io);
    }
    fn answered(ctx: ?*anyopaque, result: E!http.Response) void {
        const self: *Claim = @ptrCast(@alignCast(ctx.?));
        self.job = null;
        self.state = if (self.tries >= 150) .failed else .waiting;
        const response = result catch return;
        defer response.deinit(self.a);
        if (response.status != 200) return;
        self.state = .failed;
        const Reply = struct { session: []const u8 };
        const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
        const parsed = std.json.parseFromSlice(Reply, self.a, response.body, options) catch return;
        defer parsed.deinit();
        self.session = hex(parsed.value.session);
        if (self.session != null) self.state = .done;
    }
};
