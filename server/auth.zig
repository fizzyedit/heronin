const std = @import("std");
const google = @import("google.zig");
pub const Config = struct { id: []const u8, secret: []const u8, public_url: []const u8, allow: []const []const u8 };
const State = struct { key: [32]u8, verifier: [43]u8, made_at: i64 };
pub const Action = enum { login, callback, token, logout };
const Cached = struct { key: [32]u8, token: []const u8, expires: i64 };
const Session = struct { hash: [32]u8, email: []const u8, expires: i64 };
pub const Auth = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    data: []const u8,
    config: ?Config = null,
    google: google.Google,
    random: std.Random,
    states: std.ArrayList(State) = .empty,
    sessions: std.ArrayList(Session) = .empty,
    cache: std.ArrayList(Cached) = .empty,
    pub fn deinit(self: *Auth) void {
        for (self.sessions.items) |s| self.gpa.free(s.email);
        self.sessions.deinit(self.gpa);
        self.states.deinit(self.gpa);
        for (self.cache.items) |c| self.gpa.free(c.token);
        self.cache.deinit(self.gpa);
    }
    pub fn session(self: *Auth, cookie: ?[]const u8, now: i64) ?[]const u8 {
        var parts = std.mem.splitScalar(u8, cookie orelse return null, ';');
        while (parts.next()) |part| {
            const p = std.mem.trim(u8, part, " ");
            if (!std.mem.startsWith(u8, p, "heronin_session=")) continue;
            var raw: [32]u8 = undefined;
            if (p.len != 80) continue;
            _ = std.fmt.hexToBytes(&raw, p[16..]) catch continue;
            const hash = digest(&raw);
            for (self.sessions.items) |s| if (std.mem.eql(u8, &s.hash, &hash) and s.expires > now) return s.email;
        }
        return null;
    }
    pub fn handle(self: *Auth, r: *std.http.Server.Request, a: std.mem.Allocator, now: i64, action: Action) !void {
        const c = self.config orelse return r.respond("{\"error\":\"sign-in not configured\"}", .{ .status = .service_unavailable, .keep_alive = false, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
        if (action == .token or action == .logout) return self.credentials(r, a, now, action);
        const redirect = try std.fmt.allocPrint(a, "{s}/api/oauth/callback", .{c.public_url});
        if (action == .login) {
            var raw: [32]u8 = undefined;
            self.random.bytes(raw[0..16]);
            const key = std.fmt.bytesToHex(raw[0..16].*, .lower);
            self.random.bytes(&raw);
            var verifier: [43]u8 = undefined;
            _ = std.base64.url_safe_no_pad.Encoder.encode(&verifier, &raw);
            if (self.states.items.len == 16) _ = self.states.orderedRemove(0);
            try self.states.append(self.gpa, .{ .key = key, .verifier = verifier, .made_at = now });
            const challenge = digest(&verifier);
            var encoded: [43]u8 = undefined;
            const query = try google.formBody(a, &.{ .{ "client_id", c.id }, .{ "redirect_uri", redirect }, .{ "response_type", "code" }, .{ "scope", "openid email https://www.googleapis.com/auth/drive" }, .{ "access_type", "offline" }, .{ "prompt", "consent" }, .{ "state", &key }, .{ "code_challenge", std.base64.url_safe_no_pad.Encoder.encode(&encoded, &challenge) }, .{ "code_challenge_method", "S256" } });
            return r.respond("", .{ .status = .found, .keep_alive = false, .extra_headers = &.{.{ .name = "location", .value = try std.fmt.allocPrint(a, "https://accounts.google.com/o/oauth2/v2/auth?{s}", .{query}) }} });
        }
        var code: ?[]const u8 = null;
        var state: ?[]const u8 = null;
        var cancelled = false;
        var query = std.mem.splitScalar(u8, r.head.target[(std.mem.indexOfScalar(u8, r.head.target, '?') orelse r.head.target.len - 1) + 1 ..], '&');
        while (query.next()) |p| {
            const eq = std.mem.indexOfScalar(u8, p, '=') orelse continue;
            const value = try a.dupe(u8, p[eq + 1 ..]);
            const decoded = std.Uri.percentDecodeInPlace(value);
            if (std.mem.eql(u8, p[0..eq], "code")) code = decoded;
            if (std.mem.eql(u8, p[0..eq], "state")) state = decoded;
            if (std.mem.eql(u8, p[0..eq], "error")) cancelled = true;
        }
        var kept: ?State = null;
        for (self.states.items, 0..) |s, i| if (std.mem.eql(u8, &s.key, state orelse "")) {
            kept = self.states.orderedRemove(i);
            break;
        };
        if (cancelled) return failure(r, .forbidden, "sign-in cancelled");
        const s = kept orelse return failure(r, .bad_request, "sign-in expired, try again");
        if (now < s.made_at or now - s.made_at >= 600 or (code == null or code.?.len == 0)) return failure(r, .bad_request, "sign-in expired, try again");
        const tokens = self.google.exchangeFn(self.google.ctx, a, code.?, &s.verifier, redirect) catch return failure(r, .bad_gateway, "exchange");
        const email = identity(a, tokens.id_token, c, now) catch return failure(r, .forbidden, "not allowed");
        if (tokens.refresh_token) |token| {
            const dir_path = try std.fs.path.join(a, &.{ self.data, "tokens" });
            var dir = try std.Io.Dir.cwd().createDirPathOpen(self.io, dir_path, .{ .permissions = permissions(0o700), .open_options = .{ .iterate = true } });
            defer dir.close(self.io);
            if (@import("builtin").os.tag != .windows) try dir.setPermissions(self.io, permissions(0o700));
            const lower = try a.dupe(u8, email);
            for (lower) |*ch| ch.* = std.ascii.toLower(ch.*);
            const name = std.fmt.bytesToHex(digest(lower), .lower);
            var file = try dir.createFileAtomic(self.io, &name, .{ .permissions = permissions(0o600), .replace = true });
            defer file.deinit(self.io);
            try file.file.writeStreamingAll(self.io, token);
            try file.replace(self.io);
        }
        var raw: [32]u8 = undefined;
        self.random.bytes(&raw);
        try self.sessions.ensureUnusedCapacity(self.gpa, 1);
        const owned = try self.gpa.dupe(u8, email);
        if (self.sessions.items.len == 32) self.gpa.free(self.sessions.orderedRemove(0).email);
        self.sessions.appendAssumeCapacity(.{ .hash = digest(&raw), .email = owned, .expires = now + 2592000 });
        try self.save(a);
        std.log.info("sign-in ok", .{});
        try r.respond("", .{ .status = .found, .keep_alive = false, .extra_headers = &.{ .{ .name = "location", .value = try std.fmt.allocPrint(a, "{s}/", .{c.public_url}) }, .{ .name = "set-cookie", .value = try std.fmt.allocPrint(a, "heronin_session={s}; HttpOnly; Secure; SameSite=Lax; Path=/heronin/; Max-Age=2592000", .{std.fmt.bytesToHex(raw, .lower)}) } } });
    }
    fn save(self: *Auth, a: std.mem.Allocator) !void {
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        for (self.sessions.items) |s| try out.writer.print("{s} {d} {s}\n", .{ std.fmt.bytesToHex(s.hash, .lower), s.expires, s.email });
        var file = try std.Io.Dir.cwd().createFileAtomic(self.io, try std.fs.path.join(a, &.{ self.data, "sessions" }), .{ .permissions = permissions(0o600), .replace = true });
        defer file.deinit(self.io);
        try file.file.writeStreamingAll(self.io, out.written());
        try file.replace(self.io);
    }
    pub fn load(self: *Auth, a: std.mem.Allocator, now: i64) !void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, try std.fs.path.join(a, &.{ self.data, "sessions" }), a, .limited(65536)) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer a.free(bytes);
        var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            var parts = std.mem.splitScalar(u8, line, ' ');
            const hex = parts.next() orelse continue;
            const expires = std.fmt.parseInt(i64, parts.next() orelse continue, 10) catch continue;
            const email = parts.next() orelse continue;
            if (hex.len != 64 or expires <= now or email.len == 0 or parts.next() != null) continue;
            var hash: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&hash, hex) catch continue;
            try self.sessions.append(self.gpa, .{ .hash = hash, .expires = expires, .email = try self.gpa.dupe(u8, email) });
            if (self.sessions.items.len > 32) {
                var oldest: usize = 0;
                for (self.sessions.items, 0..) |item, i| if (item.expires < self.sessions.items[oldest].expires) {
                    oldest = i;
                };
                self.gpa.free(self.sessions.orderedRemove(oldest).email);
            }
        }
        try self.save(a);
    }
    fn dropCache(self: *Auth, key: [32]u8) void {
        for (self.cache.items, 0..) |c, i| if (std.mem.eql(u8, &c.key, &key)) {
            self.gpa.free(self.cache.orderedRemove(i).token);
            return;
        };
    }
    fn credentials(self: *Auth, r: *std.http.Server.Request, a: std.mem.Allocator, now: i64, action: Action) !void {
        var headers = r.iterateHeaders();
        var cookie: ?[]const u8 = null;
        while (headers.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "cookie")) {
            cookie = h.value;
        };
        const email = try a.dupe(u8, self.session(cookie, now) orelse return json(r, .unauthorized, "{\"error\":\"sign in\"}"));
        const lower = try a.dupe(u8, email);
        for (lower) |*ch| ch.* = std.ascii.toLower(ch.*);
        const key = digest(lower);
        const path = try std.fs.path.join(a, &.{ self.data, "tokens", &std.fmt.bytesToHex(key, .lower) });
        if (action == .logout) {
            var parts = std.mem.splitScalar(u8, cookie.?, ';');
            remove: while (parts.next()) |part| {
                const p = std.mem.trim(u8, part, " ");
                if (p.len != 80 or !std.mem.startsWith(u8, p, "heronin_session=")) continue;
                var raw: [32]u8 = undefined;
                _ = std.fmt.hexToBytes(&raw, p[16..]) catch continue;
                for (self.sessions.items, 0..) |s, i| if (std.mem.eql(u8, &s.hash, &digest(&raw)) and s.expires > now) {
                    self.gpa.free(self.sessions.orderedRemove(i).email);
                    break :remove;
                };
            }
            try self.save(a);
            var another = false;
            for (self.sessions.items) |s| if (s.expires > now and std.ascii.eqlIgnoreCase(s.email, email)) {
                another = true;
            };
            if (!another) {
                if (std.Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(65536))) |token| {
                    self.google.revokeFn(self.google.ctx, a, token) catch {
                        std.log.info("revoke failed", .{});
                    };
                } else |_| {}
                std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
                self.dropCache(key);
            }
            std.log.info("logout", .{});
            return r.respond("", .{ .status = .no_content, .keep_alive = false, .extra_headers = &.{.{ .name = "set-cookie", .value = "heronin_session=; HttpOnly; Secure; SameSite=Lax; Path=/heronin/; Max-Age=0" }} });
        }
        for (self.cache.items) |c| if (std.mem.eql(u8, &c.key, &key) and c.expires - now > 120) return tokenReply(r, a, c, email, now);
        const refresh = std.Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(65536)) catch |err| {
            if (err != error.FileNotFound) return err;
            return json(r, .unauthorized, "{\"error\":\"sign in again\"}");
        };
        const fresh = self.google.refreshFn(self.google.ctx, a, refresh) catch |err| {
            if (err != error.InvalidGrant) return json(r, .bad_gateway, "{\"error\":\"google unavailable\"}");
            std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
            self.dropCache(key);
            std.log.info("refresh refused", .{});
            return json(r, .unauthorized, "{\"error\":\"sign in again\"}");
        };
        self.dropCache(key);
        if (self.cache.items.len == 32) self.gpa.free(self.cache.orderedRemove(0).token);
        try self.cache.append(self.gpa, .{ .key = key, .token = try self.gpa.dupe(u8, fresh.access_token), .expires = now + fresh.expires_in });
        return tokenReply(r, a, self.cache.items[self.cache.items.len - 1], email, now);
    }
};
fn digest(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}
fn failure(r: *std.http.Server.Request, status: std.http.Status, message: []const u8) !void {
    std.log.info("{s}", .{if (status == .bad_request) "expired" else if (status == .bad_gateway) "exchange" else if (std.mem.eql(u8, message, "sign-in cancelled")) "cancelled" else "denied"});
    var buffer: [128]u8 = undefined;
    try r.respond(try std.fmt.bufPrint(&buffer, "<!doctype html><p>{s}</p>", .{message}), .{ .status = status, .keep_alive = false, .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }} });
}
fn identity(a: std.mem.Allocator, token: []const u8, c: Config, now: i64) ![]const u8 {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return error.Invalid;
    const payload = parts.next() orelse return error.Invalid;
    _ = parts.next() orelse return error.Invalid;
    if (parts.next() != null) return error.Invalid;
    const bytes = try a.alloc(u8, try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload));
    try std.base64.url_safe_no_pad.Decoder.decode(bytes, payload);
    const claims = (try std.json.parseFromSlice(struct { iss: []const u8, aud: []const u8, email: []const u8, email_verified: bool, exp: i64 }, a, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })).value;
    if ((!std.mem.eql(u8, claims.iss, "accounts.google.com") and !std.mem.eql(u8, claims.iss, "https://accounts.google.com")) or !std.mem.eql(u8, claims.aud, c.id) or !claims.email_verified or claims.exp <= now) return error.Invalid;
    for (c.allow) |email| if (std.ascii.eqlIgnoreCase(email, claims.email)) return claims.email;
    return error.Invalid;
}
fn permissions(mode: u16) std.Io.File.Permissions {
    return if (@import("builtin").os.tag == .windows) .default_file else .fromMode(mode);
}

fn json(r: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    return r.respond(body, .{ .status = status, .keep_alive = false, .extra_headers = &.{ .{ .name = "content-type", .value = "application/json" }, .{ .name = "cache-control", .value = "no-store" } } });
}
fn tokenReply(r: *std.http.Server.Request, a: std.mem.Allocator, c: Cached, email: []const u8, now: i64) !void {
    std.log.info("token ok", .{});
    return json(r, .ok, try std.json.Stringify.valueAlloc(a, .{ .access_token = c.token, .expires_in = c.expires - now, .email = email }, .{}));
}
