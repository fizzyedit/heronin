const std = @import("std");
const wire = @import("tagger.zig");
const decisions = @import("decide.zig");
const Fake = @import("fake_tagger.zig").Fake;
pub const Config = struct { port: u16 = 8790, threshold: f32 = decisions.default_threshold, tagger: []const u8 = "fake" };
const cap = 2 * 1024 * 1024;
fn respond(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    try request.respond(body, .{ .status = status, .keep_alive = false, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}
const Route = enum { tag };
fn route(target: []const u8) ?Route {
    const path = if (std.mem.startsWith(u8, target, "/heronin")) target[8..] else target;
    const paths = std.StaticStringMap(Route).initComptime(.{.{ "/api/tag", .tag }});
    return paths.get(path);
}
pub fn handle(request: *std.http.Server.Request, allocator: std.mem.Allocator, tagger: wire.Tagger, threshold: f32, now: i64) !void {
    if (request.head.content_length orelse 0 > cap) return respond(request, .payload_too_large, "{\"error\":\"body too large\"}");
    const matched = route(request.head.target) orelse return respond(request, .not_found, "{\"error\":\"not found\"}");
    if (request.head.method != .POST) return request.respond("{\"error\":\"method not allowed\"}", .{ .status = .method_not_allowed, .keep_alive = false, .extra_headers = &.{ .{ .name = "allow", .value = "POST" }, .{ .name = "content-type", .value = "application/json" } } });
    switch (matched) {
        .tag => {},
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
    if (!std.mem.eql(u8, config.tagger, "fake") or !std.math.isFinite(config.threshold) or config.threshold < 0 or config.threshold > 1) return error.InvalidConfig;
    if (init.environ_map.get("HERONIN_PORT")) |port| config.port = try std.fmt.parseInt(u16, port, 10);
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", config.port);
    var listener = try address.listen(init.io, .{ .reuse_address = true });
    defer listener.deinit(init.io);
    var fake: Fake = .{};
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
        handle(&request, arena.allocator(), fake.tagger(), config.threshold, std.Io.Clock.real.now(init.io).toSeconds()) catch {
            respond(&request, .internal_server_error, "{\"error\":\"internal\"}") catch {};
        };
    }
}
