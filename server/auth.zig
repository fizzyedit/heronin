const std = @import("std");
const google = @import("google.zig");
pub const Config = struct { id: []const u8, secret: []const u8, public_url: []const u8, allow: []const []const u8 };
const State = struct { key: [32]u8, verifier: [43]u8, made_at: i64 };
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
    pub fn deinit(self: *Auth) void {
        for (self.sessions.items) |s| self.gpa.free(s.email);
        self.sessions.deinit(self.gpa);
        self.states.deinit(self.gpa);
    }
    pub fn session(self: *Auth, cookie: ?[]const u8, now: i64) ?[]const u8 {
        var parts = std.mem.splitScalar(u8, cookie orelse return null, ';');
        while (parts.next()) |part| {
            const p = std.mem.trim(u8, part, " ");
            if (!std.mem.startsWith(u8, p, "heronin_session=")) continue;
            var raw: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&raw, p[16..]) catch return null;
            if (p.len != 80) return null;
            const hash = digest(&raw);
            for (self.sessions.items) |s| if (std.mem.eql(u8, &s.hash, &hash) and s.expires > now) return s.email;
        }
        return null;
    }
    pub fn handle(self: *Auth, r: *std.http.Server.Request, a: std.mem.Allocator, now: i64, login: bool) !void {
        const c = self.config orelse return r.respond("{\"error\":\"sign-in not configured\"}", .{ .status = .service_unavailable, .keep_alive = false });
        const redirect = try std.fmt.allocPrint(a, "{s}/api/oauth/callback", .{c.public_url});
        if (login) {
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
            try dir.setPermissions(self.io, permissions(0o700));
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
        std.log.info("sign-in ok", .{});
        try r.respond("", .{ .status = .found, .keep_alive = false, .extra_headers = &.{ .{ .name = "location", .value = try std.fmt.allocPrint(a, "{s}/", .{c.public_url}) }, .{ .name = "set-cookie", .value = try std.fmt.allocPrint(a, "heronin_session={s}; HttpOnly; Secure; SameSite=Lax; Path=/heronin/; Max-Age=2592000", .{std.fmt.bytesToHex(raw, .lower)}) } } });
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
