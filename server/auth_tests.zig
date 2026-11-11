const std = @import("std");
const server = @import("main.zig");
const auth = @import("auth.zig");
const google = @import("google.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const expect = std.testing.expect;
const equal = std.testing.expectEqualStrings;
const tag_body = "{\"md5\":\"00000000000000000000000000000000\",\"image\":\"\"," ++
    "\"agent\":\"ours\",\"auto_accept\":true}";
const Fixture = struct {
    arena: std.heap.ArenaAllocator = .init(a),
    tmp: std.testing.TmpDir = undefined,
    random: std.Random.DefaultPrng = .init(42),
    sign_in: auth.Auth = undefined,
    mode: enum { ok, denied, audience, unverified, expired, malformed, issuer, exchange, no_refresh } = .ok,
    calls: usize = 0,
    tags: usize = 0,
    refreshes: usize = 0,
    revokes: usize = 0,
    trouble: enum { none, invalid, unavailable, revoke } = .none,
    cookie: []const u8 = "",
    fn init(self: *Fixture) !void {
        self.tmp = std.testing.tmpDir(.{});
        self.sign_in = .{ .gpa = a, .io = io, .data = try std.fs.path.join(self.arena.allocator(), &.{ std.testing.TmpDir.parent_dir_path, &self.tmp.sub_path }), .random = self.random.random(), .google = .{ .ctx = self, .exchangeFn = exchange, .refreshFn = refresh, .revokeFn = revoke }, .config = .{ .id = "test-id", .secret = "", .public_url = "https://example.invalid/heronin", .allow = &.{"bird@example.invalid"} } };
    }
    fn deinit(self: *Fixture) void {
        self.sign_in.deinit();
        self.tmp.cleanup();
        self.arena.deinit();
    }
    fn exchange(ctx: *anyopaque, alloc: std.mem.Allocator, code: []const u8, verifier: []const u8, redirect: []const u8) !google.Tokens {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        try equal("test code", code);
        try std.testing.expectEqual(@as(usize, 43), verifier.len);
        try equal("https://example.invalid/heronin/api/oauth/callback", redirect);
        if (self.mode == .exchange) return error.Unavailable;
        const json = try std.json.Stringify.valueAlloc(alloc, .{ .iss = if (self.mode == .issuer) "wrong" else "accounts.google.com", .aud = if (self.mode == .audience) "wrong" else "test-id", .email = if (self.mode == .denied) "other@example.invalid" else "Bird@Example.invalid", .email_verified = self.mode != .unverified, .exp = @as(i64, if (self.mode == .expired) 99 else 9000000) }, .{});
        const encoded = try alloc.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(json.len));
        const jwt = try std.fmt.allocPrint(alloc, "header.{s}.signature", .{std.base64.url_safe_no_pad.Encoder.encode(encoded, json)});
        return .{ .access_token = "short", .expires_in = 3600, .refresh_token = if (self.mode == .no_refresh) null else "refresh", .id_token = if (self.mode == .malformed) "broken" else jwt };
    }
    fn tag(ctx: *anyopaque, alloc: std.mem.Allocator, input: @import("tagger.zig").Request) !@import("tagger.zig").Answer {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        self.tags += 1;
        var fake: @import("fake_tagger.zig").Fake = .{};
        return fake.tagger().tag(alloc, input);
    }
    fn refresh(ctx: *anyopaque, _: std.mem.Allocator, _: []const u8) !google.Fresh {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        self.refreshes += 1;
        if (self.trouble == .invalid) return error.InvalidGrant;
        if (self.trouble == .unavailable) return error.Unavailable;
        return .{ .access_token = "access", .expires_in = 3600 };
    }
    fn revoke(ctx: *anyopaque, _: std.mem.Allocator, _: []const u8) !void {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        self.revokes += 1;
        if (self.trouble == .revoke) return error.Unavailable;
    }
    fn request(
        self: *Fixture,
        method: []const u8,
        target: []const u8,
        now: i64,
        body: []const u8,
    ) ![]const u8 {
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const raw = try std.fmt.allocPrint(alloc, "{s} {s} HTTP/1.1\r\nHost: localhost\r\nCookie: {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{ method, target, self.cookie, body.len, body });
        var reader = std.Io.Reader.fixed(raw);
        var writer: std.Io.Writer.Allocating = .init(alloc);
        var http = std.http.Server.init(&reader, &writer.writer);
        var r = try http.receiveHead();
        try server.handleAuth(&r, alloc, .{ .ctx = self, .tagFn = tag }, 0.85, now, .{}, &self.sign_in);
        return self.arena.allocator().dupe(u8, writer.written());
    }
    fn callback(self: *Fixture, state: []const u8, now: i64) ![]const u8 {
        const target = try std.fmt.allocPrint(
            self.arena.allocator(),
            "/api/oauth/callback?code=test%20code&state={s}",
            .{state},
        );
        return self.request("GET", target, now, tag_body);
    }
    fn claim(self: *Fixture, verifier: []const u8, now: i64) ![]const u8 {
        const body = try std.json.Stringify.valueAlloc(
            self.arena.allocator(),
            .{ .verifier = verifier },
            .{},
        );
        return self.request("POST", "/api/app-session", now, body);
    }
    fn appLogin(self: *Fixture, verifier: []const u8) ![]const u8 {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(verifier, &hash, .{});
        const target = try std.fmt.allocPrint(
            self.arena.allocator(),
            "/api/login?app={s}",
            .{std.fmt.bytesToHex(hash, .lower)},
        );
        try status(try self.request("GET", target, 100, tag_body), "302");
        return self.callback(&self.sign_in.states.items[0].key, 100);
    }
    fn login(self: *Fixture) ![32]u8 {
        _ = try self.request("GET", "/api/login", 100, tag_body);
        return self.sign_in.states.items[self.sign_in.states.items.len - 1].key;
    }
};
fn status(response: []const u8, code: []const u8) !void {
    try equal(code, response[9..12]);
}
fn header(response: []const u8, name: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, response, name).? + name.len;
    return response[start .. start + std.mem.indexOf(u8, response[start..], "\r\n").?];
}
test "unconfigured login is 503 and tag remains public; auth routes require GET in both path forms" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.sign_in.config = null;
    for ([_][]const u8{ "/api/login", "/heronin/api/login" }) |path| {
        const response = try f.request("GET", path, 100, tag_body);
        try status(response, "503");
        try equal("application/json", header(response, "content-type: "));
        try expect(std.mem.endsWith(u8, response, "{\"error\":\"sign-in not configured\"}"));
        try status(try f.request("POST", path, 100, tag_body), "405");
    }
    try status(try f.request("POST", "/api/tag", 100, tag_body), "200");
    try status(try f.request("POST", "/heronin/api/oauth/callback", 100, tag_body), "405");
}
test "login redirects with encoded scope offline consent state and matching S256 challenge" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const response = try f.request("GET", "/heronin/api/login", 100, tag_body);
    try status(response, "302");
    const location = header(response, "location: ");
    const kept = f.sign_in.states.items[0];
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&kept.verifier, &digest, .{});
    var buf: [43]u8 = undefined;
    for ([_][]const u8{ "state=", &kept.key, "code_challenge_method=S256", "scope=openid%20email%20https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive", "access_type=offline", "prompt=consent", "response_type=code", std.base64.url_safe_no_pad.Encoder.encode(&buf, &digest) }) |needle| try expect(std.mem.indexOf(u8, location, needle) != null);
}
test "callback stores private refresh token and session survives request arena; cookie tampering and expiry fail" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const state = try f.login();
    const response = try f.callback(&state, 100);
    try status(response, "302");
    try equal("https://example.invalid/heronin/oauth-callback.html?signed_in=1", header(response, "location: "));
    const cookie = header(response, "set-cookie: ");
    for ([_][]const u8{ "heronin_session=", "HttpOnly", "Secure", "SameSite=Lax", "Path=/heronin/", "Max-Age=2592000" }) |part| try expect(std.mem.indexOf(u8, cookie, part) != null);
    try equal("Bird@Example.invalid", f.sign_in.session(cookie, 101).?);
    const changed = try f.arena.allocator().dupe(u8, cookie);
    changed[16] = if (changed[16] == '0') '1' else '0';
    try expect(f.sign_in.session(changed, 101) == null);
    try expect(f.sign_in.session(cookie, 2592100) == null);
    try expect(f.sign_in.session(null, 100) == null);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("bird@example.invalid", &hash, .{});
    const name = try std.fs.path.join(f.arena.allocator(), &.{ "tokens", &std.fmt.bytesToHex(hash, .lower) });
    try equal("refresh", try f.tmp.dir.readFileAlloc(io, name, f.arena.allocator(), .limited(100)));
    if (@import("builtin").os.tag != .windows) {
        try std.testing.expectEqual(@as(u32, 0o600), (try f.tmp.dir.statFile(io, name, .{})).permissions.toMode() & 0o777);
        try std.testing.expectEqual(@as(u32, 0o700), (try f.tmp.dir.statFile(io, "tokens", .{})).permissions.toMode() & 0o777);
    }
    try status(try f.callback(&state, 100), "400");
    try std.testing.expectEqual(@as(usize, 1), f.calls);
    _ = try f.callback(&(try f.login()), 101);
    try equal("refresh", try f.tmp.dir.readFileAlloc(io, name, f.arena.allocator(), .limited(100)));
}
test "unknown expired missing code cancelled and oldest of 17 states are rejected" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try status(try f.callback("unknown", 100), "400");
    const expired = try f.login();
    try status(try f.callback(&expired, 700), "400");
    const missing = try f.login();
    const target = try std.fmt.allocPrint(
        f.arena.allocator(),
        "/api/oauth/callback?state={s}",
        .{missing},
    );
    try status(try f.request("GET", target, 100, tag_body), "400");
    const cancelled = "/heronin/api/oauth/callback?error=access_denied";
    try status(try f.request("GET", cancelled, 100, tag_body), "403");
    const oldest = try f.login();
    for (0..16) |_| {
        _ = try f.login();
    }
    try std.testing.expectEqual(@as(usize, 16), f.sign_in.states.items.len);
    try status(try f.callback(&oldest, 100), "400");
    try std.testing.expectEqual(@as(usize, 0), f.calls);
}
test "disallowed email audience unverified expired malformed and issuer claims create neither token nor session; exchange error is 502" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    for ([_]@TypeOf(f.mode){ .denied, .audience, .unverified, .expired, .malformed, .issuer, .exchange }) |mode| {
        f.mode = mode;
        const state = try f.login();
        try status(try f.callback(&state, 100), if (mode == .exchange) "502" else "403");
        try std.testing.expectEqual(@as(usize, 0), f.sign_in.sessions.items.len);
        try std.testing.expectError(error.FileNotFound, f.tmp.dir.openDir(io, "tokens", .{}));
        try status(try f.callback(&state, 100), "400");
    }
}
test "sessions capped at 32 and missing refresh token writes no file" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.mode = .no_refresh;
    const first = try f.callback(&(try f.login()), 100);
    const cookie = header(first, "set-cookie: ");
    for (0..32) |_| {
        _ = try f.callback(&(try f.login()), 100);
    }
    try std.testing.expectEqual(@as(usize, 32), f.sign_in.sessions.items.len);
    try expect(f.sign_in.session(cookie, 101) == null);
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.openDir(io, "tokens", .{}));
}
test "formBody percent encodes values" {
    const body = try google.formBody(a, &.{ .{ "code", "a b&c" }, .{ "other", "+=/" } });
    defer a.free(body);
    try equal("code=a%20b%26c&other=%2B%3D%2F", body);
}

test "guard persistence token refresh errors and logout lifecycle" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try status(try f.request("POST", "/api/tag", 100, tag_body), "401");
    try std.testing.expectEqual(@as(usize, 0), f.tags);
    const first = try f.callback(&(try f.login()), 100);
    f.cookie = header(first, "set-cookie: ");
    try status(try f.request("POST", "/api/tag", 100, tag_body), "200");
    var loaded: auth.Auth = .{ .gpa = a, .io = io, .data = f.sign_in.data, .google = f.sign_in.google, .random = f.random.random() };
    defer loaded.deinit();
    try loaded.load(f.arena.allocator(), 101);
    try equal("Bird@Example.invalid", loaded.session(f.cookie, 101).?);
    const disk = try f.tmp.dir.readFileAlloc(io, "sessions", f.arena.allocator(), .limited(65536));
    try expect(std.mem.indexOf(u8, disk, f.cookie[16..80]) == null);
    if (@import("builtin").os.tag != .windows) try std.testing.expectEqual(@as(u32, 0o600), (try f.tmp.dir.statFile(io, "sessions", .{})).permissions.toMode() & 0o777);
    f.cookie = try std.fmt.allocPrint(f.arena.allocator(), "heronin_session=zz; {s}", .{f.cookie});
    const token = try f.request("GET", "/heronin/api/token", 100, tag_body);
    try status(token, "200");
    try equal("no-store", header(token, "cache-control: "));
    try status(try f.request("GET", "/api/token", 200, tag_body), "200");
    try std.testing.expectEqual(@as(usize, 1), f.refreshes);
    try status(try f.request("GET", "/api/token", 3600, tag_body), "200");
    try std.testing.expectEqual(@as(usize, 2), f.refreshes);
    f.trouble = .unavailable;
    try status(try f.request("GET", "/api/token", 7100, tag_body), "502");
    const token_path = "tokens/" ++ std.fmt.bytesToHex(blk: {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash("bird@example.invalid", &hash, .{});
        break :blk hash;
    }, .lower);
    f.trouble = .invalid;
    try status(try f.request("GET", "/api/token", 7100, tag_body), "401");
    try status(try f.request("GET", "/api/token", 7100, tag_body), "401");
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.openFile(io, token_path, .{}));
    const second = try f.callback(&(try f.login()), 100);
    f.sign_in.gpa.free(f.sign_in.sessions.items[1].email);
    f.sign_in.sessions.items[1].email = try a.dupe(u8, "bird@example.invalid");
    f.trouble = .none;
    try status(try f.request("GET", "/api/logout", 100, tag_body), "405");
    const logout = try f.request("POST", "/api/logout", 100, tag_body);
    try status(logout, "204");
    try expect(std.mem.indexOf(u8, logout, "Max-Age=0") != null);
    try std.testing.expectEqual(@as(usize, 0), f.revokes);
    try equal("refresh", try f.tmp.dir.readFileAlloc(io, token_path, f.arena.allocator(), .limited(100)));
    try status(try f.request("GET", "/api/token", 100, tag_body), "401");
    f.cookie = header(second, "set-cookie: ");
    try status(try f.request("GET", "/api/token", 100, tag_body), "200");
    f.trouble = .revoke;
    try status(try f.request("POST", "/heronin/api/logout", 100, tag_body), "204");
    try std.testing.expectEqual(@as(usize, 1), f.revokes);
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.openFile(io, token_path, .{}));
    f.cookie = header(try f.callback(&(try f.login()), 100), "set-cookie: ");
    f.trouble = .none;
    try status(try f.request("POST", "/api/logout", 100, tag_body), "204");
    try std.testing.expectEqual(@as(usize, 2), f.revokes);
}
test "load drops expired broken and earliest of 33 sessions" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var text: std.Io.Writer.Allocating = .init(f.arena.allocator());
    try text.writer.writeAll("broken\n0000 1 bird@example.invalid\n");
    for (0..34) |i| {
        var hash: [32]u8 = @splat(0);
        hash[0] = @intCast(i);
        try text.writer.print("{s} {d} bird@example.invalid\n", .{ std.fmt.bytesToHex(hash, .lower), if (i == 33) @as(usize, 1) else 200 + i });
    }
    var file = try f.tmp.dir.createFile(io, "sessions", .{});
    try file.writeStreamingAll(io, text.written());
    file.close(io);
    try f.sign_in.load(f.arena.allocator(), 100);
    try std.testing.expectEqual(@as(usize, 32), f.sign_in.sessions.items.len);
    for (f.sign_in.sessions.items) |s| try expect(s.expires >= 201);
    const saved = try f.tmp.dir.readFileAlloc(io, "sessions", f.arena.allocator(), .limited(65536));
    try expect(std.mem.indexOf(u8, saved, "broken") == null);
}

const app_verifier = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
test "app callback claims once and its session passes the gate" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const response = try f.appLogin(app_verifier);
    try status(response, "200");
    try expect(std.mem.indexOf(u8, response, "Go back to Heronin") != null);
    try expect(std.mem.indexOf(u8, response, "set-cookie") == null);
    try expect(std.mem.indexOf(u8, response, "location:") == null);
    try equal("text/html; charset=utf-8", header(response, "content-type: "));
    try status(try f.claim("another verifier", 100), "404");
    const claimed = try f.claim(app_verifier, 100);
    try status(claimed, "200");
    const start = std.mem.indexOf(u8, claimed, "{\"session\":").?;
    const parsed = try std.json.parseFromSlice(
        struct { session: []const u8 },
        a,
        claimed[start..],
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 64), parsed.value.session.len);
    var raw: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&raw, parsed.value.session);
    f.cookie = try std.fmt.allocPrint(
        f.arena.allocator(),
        "heronin_session={s}",
        .{parsed.value.session},
    );
    try status(try f.request("GET", "/api/token", 100, tag_body), "200");
    try status(try f.claim(app_verifier, 100), "404");
}
test "app handoffs expire and reject future timestamps" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    _ = try f.appLogin(app_verifier);
    try status(try f.claim(app_verifier, 400), "404");
    _ = try f.appLogin(app_verifier);
    try status(try f.claim(app_verifier, std.math.minInt(i64)), "404");
    _ = try f.appLogin(app_verifier);
    try status(try f.claim(app_verifier, std.math.maxInt(i64)), "404");
}
test "bad app creates no state and fifth handoff drops first" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const non_hex = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz";
    for ([_][]const u8{ app_verifier[0..63], non_hex }) |app| {
        const target = try std.fmt.allocPrint(f.arena.allocator(), "/api/login?app={s}", .{app});
        try status(try f.request("GET", target, 100, tag_body), "400");
        try std.testing.expectEqual(@as(usize, 0), f.sign_in.states.items.len);
    }
    for ([_][]const u8{ app_verifier, "b", "c", "d", "e" }) |verifier| {
        _ = try f.appLogin(verifier);
    }
    try status(try f.claim(app_verifier, 100), "404");
    try status(try f.claim("e", 100), "200");
}
