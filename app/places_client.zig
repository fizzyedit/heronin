const std = @import("std");
const model = @import("model");
const core = @import("core");
pub var names: Names = .{};
pub const Answer = struct { lat: f64, lon: f64, name: ?[]const u8 = null };
pub const Names = struct {
    answers: std.ArrayList(Answer) = .empty,
    scanned: ?struct { photos: [*]const model.Photo, photos_len: usize, saved_len: usize, answers_len: usize } = null,
    busy: bool = false,
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    job: ?core.vfs.http.Job = null,
    transport: ?core.vfs.http.Transport = null,
    pub fn deinit(self: *Names) void {
        if (self.job) |job| self.transport.?.cancel(job);
        self.arena.deinit();
        self.* = .{};
    }
};
pub fn near(self: *const Names, point: anytype) ?[]const u8 {
    var best: ?Answer = null;
    for (self.answers.items) |answer| if (answer.name != null and model.places.distanceM(point, answer) <= 150 and (best == null or model.places.distanceM(point, answer) < model.places.distanceM(point, best.?))) {
        best = answer;
    };
    return if (best) |answer| answer.name else null;
}
pub fn step(self: *Names, photos: []const model.Photo, saved: []const model.Place, transport: core.vfs.http.Transport, base: ?[]const u8) void {
    if (self.busy) return;
    if (self.scanned) |scan| if (scan.photos == photos.ptr and scan.photos_len == photos.len and scan.saved_len == saved.len and scan.answers_len == self.answers.items.len) return;
    var best: ?model.Photo = null;
    for (photos) |p| {
        const point = model.places.placeOf(p, photos) orelse continue;
        if (model.places.namedPlace(point, saved) != null) continue;
        if (for (self.answers.items) |answer| {
            if (model.places.distanceM(point, answer) <= 150) break true;
        } else false) continue;
        if (best == null or (if (p.taken_at != best.?.taken_at) (if (p.taken_at) |at| best.?.taken_at == null or at < best.?.taken_at.? else false) else std.mem.lessThan(u8, p.id, best.?.id))) best = p;
    }
    const point = model.places.placeOf(best orelse {
        self.scanned = .{ .photos = photos.ptr, .photos_len = photos.len, .saved_len = saved.len, .answers_len = self.answers.items.len };
        return;
    }, photos).?;
    const a = self.arena.allocator();
    self.answers.append(a, .{ .lat = @round(point.lat * 1000) / 1000, .lon = @round(point.lon * 1000) / 1000 }) catch return;
    self.busy = true;
    self.transport = transport;
    self.job = transport.request(a, .{ .method = .GET, .url = std.fmt.allocPrint(a, "{s}?lat={d:.3}&lon={d:.3}", .{ @import("tag_queue.zig").serverUrl(a, base, "place") catch return done(self, error.Io), self.answers.items[self.answers.items.len - 1].lat, self.answers.items[self.answers.items.len - 1].lon }) catch return done(self, error.Io) }, done, self) catch return done(self, error.Io);
}
pub fn done(ctx: ?*anyopaque, result: core.vfs.Error!core.vfs.http.Response) void {
    const self: *Names = @ptrCast(@alignCast(ctx.?));
    self.busy = false;
    self.job = null;
    const response = result catch return;
    defer response.deinit(self.arena.allocator());
    if (response.status == 401) {
        _ = self.answers.pop();
        @import("sign_in.zig").lost();
    }
    if (response.status != 200) return;
    const parsed = std.json.parseFromSlice(struct { name: ?[]const u8 }, self.arena.allocator(), response.body, .{ .allocate = .alloc_always }) catch return;
    self.answers.items[self.answers.items.len - 1].name = parsed.value.name;
}
