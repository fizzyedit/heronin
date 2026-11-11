const std = @import("std");
const model = @import("model");
const wire = @import("tagger.zig");
const logic = @import("decide.zig");
const server = @import("main.zig");
const Claude = @import("claude_tagger.zig").Claude;
const handle = @import("server_tests.zig").handle;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const strings = std.testing.expectEqualStrings;
const a = std.testing.allocator;
const two_species =
    \\{"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-5-5-test",
    \\ "content":[{"type":"text","text":"Two herons."},
    \\  {"type":"tool_use","id":"toolu_1","name":"birds","input":{"candidates":[
    \\   {"species":"greegr","common":"Great Egret","confidence":0.61},
    \\   {"species":"grbher3","common":"Great Blue Heron","confidence":0.92,"detail":"adult","note":"long gray neck"}]}}],
    \\ "stop_reason":"tool_use","usage":{"input_tokens":12,"output_tokens":34}}
;
const renamed =
    \\{"model":"claude-sonnet-5-5-test","content":[{"type":"tool_use","id":"toolu_2","name":"birds","input":{"candidates":[
    \\ {"species":"grblhe","common":"great blue heron","confidence":0.92},
    \\ {"species":"zzzbrd","common":"Mystery Bird","confidence":0.88}]}}]}
;
const empty =
    \\{"model":"claude-sonnet-5-5-test","content":[{"type":"tool_use","id":"toolu_3","name":"birds","input":{"candidates":[]}}]}
;
const too_sure =
    \\{"model":"claude-sonnet-5-5-test","content":[{"type":"tool_use","id":"toolu_4","name":"birds","input":{"candidates":[
    \\ {"species":"osprey","common":"Osprey","confidence":1.7}]}}]}
;
const text_only =
    \\{"model":"claude-sonnet-5-5-test","content":[{"type":"text","text":"I see a heron."}]}
;
const busy =
    \\{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
;
fn request(image: []const u8) wire.Request {
    return .{ .md5 = .{ .bytes = @splat(7) }, .image = image, .taken_at = 1700000000, .place = .{ .lat = 0.12, .lon = 0.34 }, .agent = .ours, .auto_accept = true };
}
const Recorder = struct {
    status: u16 = 200,
    answer: []const u8 = two_species,
    sent: ?[]const u8 = null,
    calls: usize = 0,
    fn post(self: *Recorder) Claude.Post {
        return .{ .ctx = self, .postFn = send };
    }
    fn send(ctx: ?*anyopaque, _: *Claude, _: std.mem.Allocator, body: []const u8) !Claude.Reply {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        self.sent = body;
        self.calls += 1;
        return .{ .status = self.status, .body = self.answer };
    }
};
fn claudeWith(recorder: *Recorder) Claude {
    return .{ .io = std.testing.io, .config = .{ .key = "test-key", .model = "claude-sonnet-5-5-test" }, .post = recorder.post() };
}
fn facts(allocator: std.mem.Allocator, input: wire.Request) !std.json.Value {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, try Claude.body(allocator, "claude-sonnet-5-5", input), .{});
    return value.object.get("messages").?.array.items[0].object.get("content").?.array.items[1].object.get("text").?;
}
test "body parses back with model tool choice media type and facts and no key" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    for ([_][2][]const u8{ .{ "/9j/4AAQ", "image/jpeg" }, .{ "iVBORw0K", "image/png" } }) |case| {
        const text = try Claude.body(allocator, "claude-sonnet-5-5", request(case[0]));
        try expect(std.mem.indexOf(u8, text, "test-key") == null);
        const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
        try strings("claude-sonnet-5-5", value.object.get("model").?.string);
        try equal(@as(i64, 1024), value.object.get("max_tokens").?.integer);
        try strings("birds", value.object.get("tool_choice").?.object.get("name").?.string);
        try strings("birds", value.object.get("tools").?.array.items[0].object.get("name").?.string);
        const image = value.object.get("messages").?.array.items[0].object.get("content").?.array.items[0].object.get("source").?.object;
        try strings(case[1], image.get("media_type").?.string);
        try strings(case[0], image.get("data").?.string);
    }
    try strings("Taken 2023-11-14. Near latitude 0.12, longitude 0.34.", (try facts(allocator, request("/9j/"))).string);
    var no_place = request("/9j/");
    no_place.place = null;
    try strings("Taken 2023-11-14.", (try facts(allocator, no_place)).string);
    no_place.taken_at = null;
    try strings("No date or place.", (try facts(allocator, no_place)).string);
}
test "headers carry the key as x-api-key and no authorization" {
    const headers = Claude.headers("test-key");
    var api_key = false;
    var version = false;
    for (headers) |h| {
        try expect(!std.ascii.eqlIgnoreCase(h.name, "authorization"));
        if (std.mem.eql(u8, h.name, "x-api-key")) api_key = std.mem.eql(u8, h.value, "test-key");
        if (std.mem.eql(u8, h.name, "anthropic-version")) version = std.mem.eql(u8, h.value, "2023-06-01");
    }
    try expect(api_key and version);
}
test "recorded answers keep known species map names drop unknown and clamp" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var recorder: Recorder = .{};
    var claude = claudeWith(&recorder);
    const both = try claude.tagger().tag(arena.allocator(), request("/9j/"));
    try strings("claude-sonnet-5-5-test", both.model);
    try equal(@as(usize, 2), both.candidates.len);
    try strings("grbher3", both.candidates[0].species);
    try strings("adult", both.candidates[0].detail.?);
    try strings("greegr", both.candidates[1].species);
    try expect(std.mem.indexOf(u8, recorder.sent.?, "\"model\":\"claude-sonnet-5-5-test\"") != null);
    recorder.answer = renamed;
    const mapped = try claude.tagger().tag(arena.allocator(), request("/9j/"));
    try equal(@as(usize, 1), mapped.candidates.len);
    try strings("grbher3", mapped.candidates[0].species);
    recorder.answer = empty;
    const none = try claude.tagger().tag(arena.allocator(), request("/9j/"));
    try equal(@as(usize, 0), none.candidates.len);
    try equal(model.Photo.State.skipped, logic.decide(.ours, none, null, logic.default_threshold, 0).state);
    recorder.answer = too_sure;
    try equal(@as(f32, 1), (try claude.tagger().tag(arena.allocator(), request("/9j/"))).candidates[0].confidence);
}
test "bad answers statuses and images are errors" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var recorder: Recorder = .{ .answer = text_only };
    var claude = claudeWith(&recorder);
    try std.testing.expectError(error.BadAnswer, claude.tagger().tag(arena.allocator(), request("/9j/")));
    recorder.answer = busy;
    for ([_]struct { u16, anyerror }{ .{ 401, error.Unauthorized }, .{ 403, error.Unauthorized }, .{ 429, error.Unavailable }, .{ 529, error.Unavailable }, .{ 418, error.BadAnswer } }) |case| {
        recorder.status = case[0];
        try std.testing.expectError(case[1], claude.tagger().tag(arena.allocator(), request("/9j/")));
    }
    const calls = recorder.calls;
    try std.testing.expectError(error.NoImage, claude.tagger().tag(arena.allocator(), request("")));
    try std.testing.expectError(error.UnsupportedImage, claude.tagger().tag(arena.allocator(), request("R0lGOD")));
    try equal(calls, recorder.calls);
}
test "checkConfig accepts fake and claude with a key only" {
    try server.checkConfig(.{ .tagger = "fake" });
    try server.checkConfig(.{ .tagger = "claude", .claude = .{ .key = "test-key" } });
    try std.testing.expectError(error.InvalidConfig, server.checkConfig(.{ .tagger = "claude" }));
    try std.testing.expectError(error.InvalidConfig, server.checkConfig(.{ .tagger = "claude", .claude = .{ .key = "" } }));
    try std.testing.expectError(error.InvalidConfig, server.checkConfig(.{ .tagger = "other" }));
}
test "POST /api/tag through Claude returns tagged with the top species first" {
    var recorder: Recorder = .{};
    var claude = claudeWith(&recorder);
    const body = try std.json.Stringify.valueAlloc(a, request("/9j/4AAQ"), .{});
    defer a.free(body);
    const raw = try std.fmt.allocPrint(a, "POST /api/tag HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    defer a.free(raw);
    const response = try handle(raw, claude.tagger());
    defer a.free(response);
    try expect(std.mem.startsWith(u8, response, "HTTP/1.1 200"));
    const parsed = try std.json.parseFromSlice(wire.Response, a, response[std.mem.indexOf(u8, response, "\r\n\r\n").? + 4 ..], .{});
    defer parsed.deinit();
    try equal(model.Photo.State.tagged, parsed.value.state);
    try strings("grbher3", parsed.value.tags[0].species);
    try strings("claude-sonnet-5-5-test", parsed.value.tags[0].model);
}
