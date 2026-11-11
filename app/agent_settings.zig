const std = @import("std");
const core = @import("core");
const http = core.vfs.http;
// The key is only ever sent to the server, then zeroed here.
pub var state: struct { address: [256]u8 = @splat(0), model: [256]u8 = @splat(0), key: [256]u8 = @splat(0), wrap: bool = false, has_key: bool = false, connected: bool = false, saved: enum { unknown, saved, failed } = .unknown, job: ?http.Job = null } = .{};
pub var allocator: std.mem.Allocator = std.heap.page_allocator;
var transport: ?http.Transport = null;
var url_buffer: [1024]u8 = undefined;
var url: []const u8 = "";
var body: []u8 = &.{};
pub fn text(buffer: []const u8) []const u8 {
    return std.mem.sliceTo(buffer, 0);
}
pub fn load(t: http.Transport, base: ?[]const u8) void {
    transport = t;
    var fixed = std.heap.FixedBufferAllocator.init(&url_buffer);
    url = @import("tag_queue.zig").serverUrl(fixed.allocator(), base, "agent") catch return;
    state.job = t.request(allocator, .{ .method = .GET, .url = url }, loaded, null) catch null;
}
fn loaded(_: ?*anyopaque, result: core.vfs.Error!http.Response) void {
    state.job = null;
    const response = result catch return;
    defer response.deinit(allocator);
    const parsed = std.json.parseFromSlice(struct { address: []const u8, wrap: bool, model: []const u8, has_key: bool }, allocator, response.body, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    if (response.status != 200 or parsed.value.address.len >= 256 or parsed.value.model.len >= 256) return;
    state = .{ .wrap = parsed.value.wrap, .has_key = parsed.value.has_key, .connected = parsed.value.address.len > 0 };
    @memcpy(state.address[0..parsed.value.address.len], parsed.value.address);
    @memcpy(state.model[0..parsed.value.model.len], parsed.value.model);
}
pub fn save() void {
    if (state.job != null or transport == null) return;
    body = std.json.Stringify.valueAlloc(allocator, .{ .address = text(&state.address), .key = text(&state.key), .wrap = state.wrap, .model = text(&state.model) }, .{}) catch return saved(null, error.Io);
    state.job = transport.?.request(allocator, .{ .method = .POST, .url = url, .body = body, .headers = &.{.{ .name = "Content-Type", .value = "application/json" }} }, saved, null) catch |err| return saved(null, err);
}
fn saved(_: ?*anyopaque, result: core.vfs.Error!http.Response) void {
    state.job = null;
    release();
    state.saved = .failed;
    const response = result catch return;
    defer response.deinit(allocator);
    if (response.status != 204) return;
    state = .{ .address = state.address, .model = state.model, .wrap = state.wrap, .has_key = state.has_key or text(&state.key).len > 0, .connected = text(&state.address).len > 0, .saved = .saved };
}
fn release() void {
    std.crypto.secureZero(u8, body);
    allocator.free(body);
    body = &.{};
}
pub fn deinit() void {
    if (state.job) |job| transport.?.cancel(job);
    release();
    state = .{};
    transport = null;
}
