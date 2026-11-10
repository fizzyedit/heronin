const std = @import("std");
const model = @import("model");
const wire = @import("tagger.zig");
const logic = @import("decide.zig");
const Fake = @import("fake_tagger.zig").Fake;
const server = @import("main.zig");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const strings = std.testing.expectEqualStrings;
const a = std.testing.allocator;
fn answer(candidates: []wire.Candidate, name: []const u8) wire.Answer {
    return .{ .candidates = candidates, .model = name };
}
test "decide single agent above at below threshold and no candidates" {
    for ([_]struct { confidence: f32, state: model.Photo.State }{
        .{ .confidence = 0.95, .state = .tagged },
        .{ .confidence = 0.85, .state = .tagged },
        .{ .confidence = 0.84, .state = .review },
    }) |row| {
        var candidates = [_]wire.Candidate{.{ .species = "grbher3", .confidence = row.confidence }};
        const ours = logic.decide(.ours, answer(&candidates, "ours-v1"), null, logic.default_threshold, 123);
        try equal(row.state, ours.state);
        try equal(@as(usize, 1), ours.len);
        try equal(model.Tag.Source.ours, ours.tags[0].source);
        try equal(model.Tag.Accepted.auto, ours.tags[0].accepted);
        try equal(@as(i64, 123), ours.tags[0].at);
        try strings("ours-v1", ours.tags[0].model);
        const yours = logic.decide(.yours, null, answer(&candidates, "yours-v1"), logic.default_threshold, 124);
        try equal(row.state, yours.state);
        try equal(model.Tag.Source.yours, yours.tags[0].source);
        try strings("yours-v1", yours.tags[0].model);
        try equal(model.Photo.State.review, logic.decide(.ours, answer(&candidates, "fake"), null, 2, 0).state);
    }
    const empty = logic.decide(.ours, answer(&.{}, "fake"), null, logic.default_threshold, 0);
    try equal(model.Photo.State.skipped, empty.state);
    try equal(@as(usize, 0), empty.len);
}
test "decide both agreement disagreement union dedupe order and partial answers" {
    var ours = [_]wire.Candidate{ .{ .species = "grbher3", .confidence = 0.8 }, .{ .species = "norcar", .confidence = 0.7 } };
    var yours = [_]wire.Candidate{ .{ .species = "grbher3", .confidence = 0.9 }, .{ .species = "norcar", .confidence = 0.6 } };
    var decision = logic.decide(.both, answer(&ours, "one"), answer(&yours, "two"), logic.default_threshold, 10);
    try equal(model.Photo.State.tagged, decision.state);
    try equal(@as(f32, 0.9), decision.tags[0].confidence);
    try equal(model.Tag.Source.yours, decision.tags[0].source);
    try strings("two", decision.tags[0].model);
    yours[0].confidence = 0.81;
    try equal(model.Photo.State.review, logic.decide(.both, answer(&ours, "one"), answer(&yours, "two"), logic.default_threshold, 0).state);
    yours[0] = .{ .species = "osprey", .confidence = 0.99 };
    decision = logic.decide(.both, answer(&ours, "one"), answer(&yours, "two"), logic.default_threshold, 0);
    try equal(model.Photo.State.review, decision.state);
    try equal(@as(usize, 3), decision.len);
    for ([_][]const u8{ "osprey", "grbher3", "norcar" }, 0..) |code, i| try strings(code, decision.tags[i].species);
    try equal(@as(f32, 0.7), decision.tags[2].confidence);
    try equal(model.Tag.Source.ours, decision.tags[2].source);
    for ([_]logic.Decision{
        logic.decide(.both, answer(&ours, "one"), null, logic.default_threshold, 0),
        logic.decide(.both, null, answer(&yours, "two"), logic.default_threshold, 0),
        logic.decide(.both, answer(&.{}, "one"), null, logic.default_threshold, 0),
    }) |partial| try equal(model.Photo.State.review, partial.state);
    try equal(model.Photo.State.review, logic.decide(.both, answer(&.{}, "one"), answer(&yours, "two"), logic.default_threshold, 0).state);
    try equal(model.Photo.State.skipped, logic.decide(.both, answer(&.{}, "one"), answer(&.{}, "two"), logic.default_threshold, 0).state);
    var many: [12]wire.Candidate = undefined;
    for (&many, model.species.table, 0..) |*c, species, i| c.* = .{ .species = species.code, .confidence = @as(f32, @floatFromInt(i)) / 12 };
    decision = logic.decide(.both, answer(many[0..6], "one"), answer(many[6..], "two"), logic.default_threshold, 0);
    try equal(@as(usize, 5), decision.len);
    for (decision.tags[0..5], 0..) |tag, i| try strings(model.species.table[11 - i].code, tag.species);
}
test "clean caps known candidates clamps confidence and truncates UTF8 text" {
    var candidates: [7]wire.Candidate = undefined;
    for (&candidates, 0..) |*c, i| c.* = .{ .species = model.species.table[i].code, .confidence = 1.3, .detail = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", .note = "nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnné" };
    candidates[0].species = "unknown";
    const cleaned = wire.clean(answer(&candidates, "fake"));
    try equal(@as(usize, 5), cleaned.candidates.len);
    try strings(model.species.table[1].code, cleaned.candidates[0].species);
    for (cleaned.candidates) |c| {
        try equal(@as(f32, 1), c.confidence);
        try equal(@as(usize, 40), c.detail.?.len);
        try equal(@as(usize, 109), c.note.?.len);
    }
    var unicode = [_]wire.Candidate{.{ .species = "osprey", .confidence = -0.2, .detail = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxé" }};
    const result = wire.clean(answer(&unicode, "fake"));
    try equal(@as(usize, 39), result.candidates[0].detail.?.len);
    try equal(@as(f32, 0), result.candidates[0].confidence);
}
fn input(md5: u8) wire.Request {
    return .{ .md5 = .{ .bytes = @splat(md5) }, .image = "", .taken_at = null, .place = null, .agent = .ours, .auto_accept = true };
}
test "fake exact fixture repeatable unknown and unavailable" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var fake: Fake = .{};
    const fixture = try fake.tagger().tag(arena.allocator(), input(0));
    try equal(@as(usize, 2), fixture.candidates.len);
    try strings("fake", fixture.model);
    try strings("grbher3", fixture.candidates[0].species);
    try equal(@as(f32, 0.95), fixture.candidates[0].confidence);
    try strings("greegr", fixture.candidates[1].species);
    try equal(@as(f32, 0.6), fixture.candidates[1].confidence);
    const first = try fake.tagger().tag(arena.allocator(), input(0xab));
    const second = try fake.tagger().tag(arena.allocator(), input(0xab));
    try equal(@as(usize, 1), first.candidates.len);
    try strings(first.candidates[0].species, second.candidates[0].species);
    try equal(first.candidates[0].confidence, second.candidates[0].confidence);
    try expect(first.candidates[0].confidence >= 0.5 and first.candidates[0].confidence <= 0.95);
    fake.fail = true;
    try std.testing.expectError(error.Unavailable, fake.tagger().tag(arena.allocator(), input(0)));
}
fn handle(raw: []const u8, fail: bool) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var reader = std.Io.Reader.fixed(raw);
    var writer: std.Io.Writer.Allocating = .init(a);
    defer writer.deinit();
    var http = std.http.Server.init(&reader, &writer.writer);
    var request = try http.receiveHead();
    var fake: Fake = .{ .fail = fail };
    try server.handle(&request, arena.allocator(), fake.tagger(), logic.default_threshold, 42);
    return a.dupe(u8, writer.written());
}
fn post(path: []const u8, body: []const u8, fail: bool) ![]u8 {
    const raw = try std.fmt.allocPrint(a, "POST {s} HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n{s}", .{ path, body.len, body });
    defer a.free(raw);
    return handle(raw, fail);
}
test "HTTP in memory returns Answer JSON both paths manual review bad requests and 502" {
    for ([_][]const u8{ "/api/tag", "/heronin/api/tag" }) |path| {
        const body = try std.json.Stringify.valueAlloc(a, input(0), .{});
        defer a.free(body);
        const response = try post(path, body, false);
        defer a.free(response);
        try expect(std.mem.startsWith(u8, response, "HTTP/1.1 200"));
        const offset = std.mem.indexOf(u8, response, "\r\n\r\n").? + 4;
        const parsed = try std.json.parseFromSlice(wire.Response, a, response[offset..], .{});
        defer parsed.deinit();
        try equal(model.Photo.State.tagged, parsed.value.state);
        try equal(@as(usize, 2), parsed.value.tags.len);
        try strings("grbher3", parsed.value.tags[0].species);
        try equal(@as(i64, 42), parsed.value.tags[0].at);
        const failed = try post(path, body, true);
        defer a.free(failed);
        try expect(std.mem.startsWith(u8, failed, "HTTP/1.1 502"));
    }
    var manual = input(0);
    manual.auto_accept = false;
    const body = try std.json.Stringify.valueAlloc(a, manual, .{});
    defer a.free(body);
    const response = try post("/api/tag", body, false);
    defer a.free(response);
    try expect(std.mem.indexOf(u8, response, "\"state\":\"review\"") != null);
    const bad = try post("/api/tag", "{}", false);
    defer a.free(bad);
    try expect(std.mem.startsWith(u8, bad, "HTTP/1.1 400"));
}
test "HTTP in memory rejects 3 MiB content length and chunked bodies" {
    const body = try a.alloc(u8, 3 * 1024 * 1024);
    defer a.free(body);
    @memset(body, 'x');
    const response = try post("/api/tag", body, false);
    defer a.free(response);
    try expect(std.mem.startsWith(u8, response, "HTTP/1.1 413"));
    const raw = try std.fmt.allocPrint(a, "POST /api/tag HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n300000\r\n{s}\r\n0\r\n\r\n", .{body});
    defer a.free(raw);
    const chunked = try handle(raw, false);
    defer a.free(chunked);
    try expect(std.mem.startsWith(u8, chunked, "HTTP/1.1 413"));
}
test "missing config threshold uses the single default" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const config = try std.zon.parse.fromSlice(server.Config, .{ .gpa = a, .arena = arena.allocator(), .source = ".{ .port = 8791, .tagger = \"fake\" }", .diagnostics = &diagnostics });
    try equal(logic.default_threshold, config.threshold);
}
