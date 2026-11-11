const std = @import("std");
const wire = @import("tagger.zig");
const yours = @import("yours.zig");
const Contract = @import("contract_tagger.zig").Contract;
const expect = std.testing.expect;
const strings = std.testing.expectEqualStrings;
const a = std.testing.allocator;
const io = std.testing.io;
test "valid accepts https and an agent on this machine only" {
    for ([_][]const u8{ "https://agent.example.invalid", "http://127.0.0.1:9000", "http://localhost", "http://localhost/tag" }) |address| try expect(yours.valid(.{ .address = address }));
    for ([_][]const u8{ "http://agent.example.invalid", "http://localhost.example.invalid", "http://localhost:80@agent.example.invalid", "http://127.0.0.1.agent.example.invalid", "https://k1@agent.example.invalid", "https://", "" }) |address| try expect(!yours.valid(.{ .address = address }));
    try expect(!yours.valid(.{ .address = "https://agent.example.invalid", .wrap = true, .model = "" }));
}
test "save load and tagger: nothing, a Claude on the saved address, else the contract" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(a, &.{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path, "yours.zon" });
    defer a.free(path);
    var first: yours.Yours = .{ .gpa = a, .io = io, .path = path };
    defer first.deinit();
    try first.load();
    try expect(first.tagger(io) == null);
    try first.save(.{ .address = "https://agent.example.invalid/v1/messages", .key = "k1", .wrap = true, .model = "mine" });
    const huge = try a.alloc(u8, 65536);
    defer a.free(huge);
    @memset(huge, 'k');
    try std.testing.expectError(error.TooLarge, first.save(.{ .address = "https://agent.example.invalid", .key = huge }));
    try strings("k1", first.saved.key);
    var second: yours.Yours = .{ .gpa = a, .io = io, .path = path };
    defer second.deinit();
    try second.load();
    try strings("k1", second.saved.key);
    try expect(second.tagger(io).?.ctx == @as(*anyopaque, &second.claude));
    try strings("https://agent.example.invalid/v1/messages", second.claude.config.url);
    try strings("mine", second.claude.config.model);
    second.saved.wrap = false;
    try expect(second.tagger(io).?.ctx == @as(*anyopaque, &second.contract));
    if (@import("builtin").os.tag == .windows) return;
    var file = try tmp.dir.openFile(io, "yours.zon", .{});
    defer file.close(io);
    try std.testing.expectEqual(0o600, (try file.stat(io)).permissions.toMode() & 0o777);
}
const Recorder = struct {
    status: u16 = 200,
    answer: []const u8 = "{\"candidates\":[{\"species\":\"norcar\",\"confidence\":0.9}],\"model\":\"mine\",\"took_ms\":800}",
    sent: []const u8 = "",
    bearer: ?[]const u8 = null,
    fn send(ctx: ?*anyopaque, contract: *Contract, allocator: std.mem.Allocator, body: []const u8) !Contract.Reply {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        self.sent = body;
        self.bearer = null;
        for (try contract.headers(allocator)) |h| if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
            self.bearer = h.value;
        };
        return .{ .status = self.status, .body = self.answer };
    }
};
test "contract sends image date and place, a bearer key only when set, and reads candidates" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var recorder: Recorder = .{};
    var contract: Contract = .{ .io = io, .address = "https://agent.example.invalid", .key = "k1", .post = .{ .ctx = &recorder, .postFn = Recorder.send } };
    var request: wire.Request = .{ .md5 = .{ .bytes = @splat(7) }, .image = "/9j/", .taken_at = 1700000000, .place = .{ .lat = 0.12, .lon = 0.34 }, .agent = .yours, .auto_accept = true };
    const answer = try contract.tagger().tag(arena.allocator(), request);
    try strings("mine", answer.model);
    try std.testing.expectEqual(1, answer.candidates.len);
    try strings("norcar", answer.candidates[0].species);
    try strings("Bearer k1", recorder.bearer.?);
    try strings("{\"image\":\"/9j/\",\"taken_at\":1700000000,\"place\":{\"lat\":0.12,\"lon\":0.34}}", recorder.sent);
    contract.key = "";
    for ([_]i64{ std.math.minInt(i64), std.math.maxInt(i64), -2208988801, 7258118400 }) |at| {
        request.taken_at = at;
        try std.testing.expectError(error.BadRequest, contract.tagger().tag(arena.allocator(), request));
    }
    request.taken_at = -2208988800;
    request.place = .{ .lat = std.math.inf(f64), .lon = 0 };
    _ = try contract.tagger().tag(arena.allocator(), request);
    try expect(recorder.bearer == null);
    try strings("{\"image\":\"/9j/\",\"taken_at\":-2208988800,\"place\":null}", recorder.sent);
    for ([_]struct { u16, []const u8, anyerror }{ .{ 401, "{}", error.Unauthorized }, .{ 503, "{}", error.Unavailable }, .{ 200, "not json", error.BadAnswer } }) |case| {
        recorder.status = case[0];
        recorder.answer = case[1];
        try std.testing.expectError(case[2], contract.tagger().tag(arena.allocator(), request));
    }
}
