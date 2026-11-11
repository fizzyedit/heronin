const std = @import("std");
const wire = @import("tagger.zig");
const decisions = @import("decide.zig");
const Fake = @import("fake_tagger.zig").Fake;
const Gazetteer = @import("place_names.zig").Gazetteer;
const auth = @import("auth.zig");
const Claude = @import("claude_tagger.zig").Claude;
pub const Config = struct { google: ?auth.Config = null, gazetteer: []const u8 = "geonames.txt", port: u16 = 8790, threshold: f32 = decisions.default_threshold, tagger: []const u8 = "fake", claude: ?Claude.Config = null };
pub fn checkConfig(config: Config) !void {
    const claude = std.mem.eql(u8, config.tagger, "claude") and config.claude != null and config.claude.?.key.len > 0;
    if (!(std.mem.eql(u8, config.tagger, "fake") or claude) or !std.math.isFinite(config.threshold) or config.threshold < 0 or config.threshold > 1) return error.InvalidConfig;
}
const cap = 2 * 1024 * 1024;
fn respond(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    try request.respond(body, .{ .status = status, .keep_alive = false, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}
const Route = enum { tag, place, login, callback, token, logout };
fn route(target: []const u8) ?Route {
    const path = if (std.mem.startsWith(u8, target, "/heronin")) target[8..] else target;
    const paths = std.StaticStringMap(Route).initComptime(.{ .{ "/api/tag", .tag }, .{ "/api/place", .place }, .{ "/api/login", .login }, .{ "/api/oauth/callback", .callback }, .{ "/api/token", .token }, .{ "/api/logout", .logout } });
    return paths.get(path[0 .. std.mem.indexOfScalar(u8, path, '?') orelse path.len]);
}
pub fn handle(request: *std.http.Server.Request, allocator: std.mem.Allocator, tagger: wire.Tagger, threshold: f32, now: i64, gazetteer: Gazetteer) !void {
    return handleAuth(request, allocator, tagger, threshold, now, gazetteer, null);
}
pub fn handleAuth(request: *std.http.Server.Request, allocator: std.mem.Allocator, tagger: wire.Tagger, threshold: f32, now: i64, gazetteer: Gazetteer, sign_in: ?*auth.Auth) !void {
    const matched = route(request.head.target) orelse return respond(request, .not_found, "{\"error\":\"not found\"}");
    if (request.head.method != (if (matched != .tag and matched != .logout) std.http.Method.GET else .POST)) return request.respond("{\"error\":\"method not allowed\"}", .{ .status = .method_not_allowed, .keep_alive = false, .extra_headers = &.{ .{ .name = "allow", .value = if (matched != .tag and matched != .logout) "GET" else "POST" }, .{ .name = "content-type", .value = "application/json" } } });
    if (sign_in) |configured| if (configured.config != null and (matched == .tag or matched == .place or matched == .token or matched == .logout)) {
        var headers = request.iterateHeaders();
        var cookie: ?[]const u8 = null;
        while (headers.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "cookie")) {
            cookie = h.value;
        };
        if (configured.session(cookie, now) == null) return respond(request, .unauthorized, "{\"error\":\"sign in\"}");
    };
    if (request.head.content_length orelse 0 > cap) return respond(request, .payload_too_large, "{\"error\":\"body too large\"}");
    if (matched == .login or matched == .callback or matched == .token or matched == .logout) {
        const configured = sign_in orelse return respond(request, .service_unavailable, "{\"error\":\"sign-in not configured\"}");
        return configured.handle(request, allocator, now, switch (matched) {
            .login => .login,
            .callback => .callback,
            .token => .token,
            .logout => .logout,
            else => unreachable,
        });
    }
    if (matched == .place) {
        var lat: f64 = std.math.nan(f64);
        var lon = lat;
        var query = std.mem.splitScalar(u8, request.head.target[(std.mem.indexOfScalar(u8, request.head.target, '?') orelse request.head.target.len - 1) + 1 ..], '&');
        while (query.next()) |part| {
            const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
            const value = std.fmt.parseFloat(f64, part[eq + 1 ..]) catch std.math.nan(f64);
            if (std.mem.eql(u8, part[0..eq], "lat")) lat = value;
            if (std.mem.eql(u8, part[0..eq], "lon")) lon = value;
        }
        if (!std.math.isFinite(lat) or !std.math.isFinite(lon) or @abs(lat) > 90 or @abs(lon) > 180) return respond(request, .bad_request, "{}");
        const json = try std.json.Stringify.valueAlloc(allocator, .{ .name = gazetteer.nearest(@round(lat * 1000) / 1000, @round(lon * 1000) / 1000) }, .{});
        defer allocator.free(json);
        return respond(request, .ok, json);
    }
    const reader = try request.readerExpectContinue(&.{});
    const body = reader.allocRemaining(allocator, .limited(cap)) catch |err| return respond(request, if (err == error.StreamTooLong) .payload_too_large else .bad_request, "{\"error\":\"invalid body\"}");
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(wire.Request, allocator, body, .{}) catch return respond(request, .bad_request, "{\"error\":\"invalid request\"}");
    defer parsed.deinit();
    const input = parsed.value;
    var ours: ?wire.Answer = null;
    var yours: ?wire.Answer = null;
    if (input.agent != .yours) ours = tagger.tag(allocator, input) catch return respond(request, .bad_gateway, "{\"error\":\"tagger unavailable\"}");
    if (input.agent != .ours) yours = tagger.tag(allocator, input) catch return respond(request, .bad_gateway, "{\"error\":\"tagger unavailable\"}");
    const decision = decisions.decide(input.agent, ours, yours, if (input.auto_accept) threshold else 2, now);
    std.log.info("{s} {s}", .{ std.fmt.bytesToHex(input.md5.bytes, .lower), @tagName(decision.state) });
    const json = try std.json.Stringify.valueAlloc(allocator, wire.Response{ .state = decision.state, .tags = decision.tags[0..decision.len] }, .{});
    defer allocator.free(json);
    try respond(request, .ok, json);
}
pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var config: Config = .{};
    var gazetteer: Gazetteer = .{};
    if (init.environ_map.get("HERONIN_DATA")) |data| {
        const path = try std.fs.path.join(allocator, &.{ data, "server.zon" });
        const source = std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(65536)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (source) |bytes| {
            var diagnostics: std.zon.parse.Diagnostics = undefined;
            config = std.zon.parse.fromSlice(Config, .{ .gpa = allocator, .arena = allocator, .source = try allocator.dupeSentinel(u8, bytes, 0), .diagnostics = &diagnostics }) catch |err| {
                diagnostics.log(path);
                return err;
            };
        }
    }
    if (init.environ_map.get("HERONIN_DATA")) |data| gazetteer = try Gazetteer.load(allocator, init.io, if (std.fs.path.isAbsolute(config.gazetteer)) config.gazetteer else try std.fs.path.join(allocator, &.{ data, config.gazetteer }));
    try checkConfig(config);
    if (init.environ_map.get("HERONIN_PORT")) |port| config.port = try std.fmt.parseInt(u16, port, 10);
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", config.port);
    var listener = try address.listen(init.io, .{ .reuse_address = true });
    defer listener.deinit(init.io);
    var real: @import("google.zig").Real = .{ .io = init.io, .id = if (config.google) |g| g.id else "", .secret = if (config.google) |g| g.secret else "" };
    var seed: [32]u8 = undefined;
    try init.io.randomSecure(&seed);
    var random = std.Random.DefaultCsprng.init(seed);
    var sign_in: auth.Auth = .{ .gpa = init.gpa, .io = init.io, .data = init.environ_map.get("HERONIN_DATA") orelse ".", .config = config.google, .google = real.google(), .random = random.random() };
    defer sign_in.deinit();
    if (config.google != null) try sign_in.load(allocator, std.Io.Clock.real.now(init.io).toSeconds());
    var fake: Fake = .{};
    var claude: Claude = .{ .io = init.io, .config = config.claude orelse .{ .key = "" } };
    const tagger = if (std.mem.eql(u8, config.tagger, "claude")) claude.tagger() else fake.tagger();
    while (true) {
        const stream = listener.accept(init.io) catch |err| {
            std.log.warn("accept failed: {s}", .{@errorName(err)});
            continue;
        };
        defer stream.close(init.io);
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();
        var read_buffer: [8192]u8 = undefined;
        var write_buffer: [8192]u8 = undefined;
        var reader = stream.reader(init.io, &read_buffer);
        var writer = stream.writer(init.io, &write_buffer);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = server.receiveHead() catch continue;
        handleAuth(&request, arena.allocator(), tagger, config.threshold, std.Io.Clock.real.now(init.io).toSeconds(), gazetteer, &sign_in) catch {
            respond(&request, .internal_server_error, "{\"error\":\"internal\"}") catch {};
        };
    }
}
