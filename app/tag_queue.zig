const std = @import("std");
const model = @import("model");
const api = @import("store.zig");
pub const wire = @import("wire");
pub const Settings = struct { auto: bool = false, ask_below: bool = true, use_place: bool = true, agent: model.QueueItem.Agent = .ours };
pub fn endpoint(a: std.mem.Allocator, override: ?[]const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/heronin/api/tag", .{std.mem.trimEnd(u8, override orelse "http://127.0.0.1:8787", "/")});
}
pub const TagQueue = struct {
    asked: ?[]const u8 = null,
    busy: ?[]const u8 = null,
    attempts: std.StringHashMapUnmanaged(u8) = .empty,
    settings: *const Settings,
    items: []api.Item = &.{},
    photos: []const model.Photo = &.{},
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    owned: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    tags_allocator: ?std.mem.Allocator = null,
    store: api.Store = undefined,
    post: Post = undefined,
    active: usize = 0,
    pub const Post = *const fn (*TagQueue, wire.Request) void;
    pub fn deinit(self: *TagQueue) void {
        self.arena.deinit();
        self.owned.deinit();
        self.* = .{ .settings = self.settings };
    }
    pub fn ask(self: *TagQueue, id: []const u8) void {
        self.asked = self.owned.allocator().dupe(u8, id) catch return;
    }
    pub fn next(self: *TagQueue, items: []const api.Item) ?[]const u8 {
        if (self.busy != null) return null;
        if (self.asked) |id| for (items) |item| {
            if (std.mem.eql(u8, id, item.photo.id)) return id;
        };
        if (!self.settings.auto) return null;
        var best: ?model.Photo = null;
        for (items) |item| {
            const p = item.photo;
            if (p.state != .new) continue;
            if (best == null or (p.taken_at != null and best.?.taken_at == null) or (p.taken_at != null and best.?.taken_at != null and p.taken_at.? < best.?.taken_at.?) or (p.taken_at == best.?.taken_at and std.mem.lessThan(u8, p.id, best.?.id))) best = p;
        }
        return if (best) |p| p.id else null;
    }
    pub fn step(self: *TagQueue, store: api.Store, post: Post) void {
        const id = self.next(self.items) orelse return;
        self.busy = id;
        self.store = store;
        self.post = post;
        for (self.items, 0..) |item, i| self.active = if (std.mem.eql(u8, item.photo.id, id)) i else self.active;
        self.items[self.active].photo.state = .tagging;
        store.setTags(id, &.{}, .tagging, null, ignored);
        store.thumbnail(id, 1024, self, thumbnail);
    }
    fn ignored(_: ?*anyopaque, _: api.Error!void) void {}
    fn thumbnail(ctx: ?*anyopaque, result: api.Error!api.Thumbnail) void {
        const self: *TagQueue = @ptrCast(@alignCast(ctx.?));
        const image = result catch return self.answer(error.Io);
        const encoded = switch (image) {
            .wash => "",
            .encoded => |bytes| std.base64.standard.Encoder.encode(self.arena.allocator().alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len)) catch return self.answer(error.OutOfMemory), bytes),
        };
        const p = self.items[self.active].photo;
        const place = if (self.settings.use_place) model.places.placeOf(p, self.photos) else null;
        self.post(self, .{ .md5 = p.md5, .image = encoded, .taken_at = p.taken_at, .place = if (place) |v| .{ .lat = @round(v.lat * 100) / 100, .lon = @round(v.lon * 100) / 100 } else null, .agent = self.settings.agent, .auto_accept = self.settings.ask_below });
    }
    pub fn answer(self: *TagQueue, result: anyerror!wire.Response) void {
        const item = &self.items[self.active];
        const response = result catch blk: {
            const count = self.attempts.getOrPut(self.owned.allocator(), self.owned.allocator().dupe(u8, item.photo.id) catch return) catch return;
            if (!count.found_existing) count.value_ptr.* = 0;
            count.value_ptr.* +|= 1;
            break :blk wire.Response{ .tags = &.{}, .state = if (count.value_ptr.* >= 3) .failed else .new };
        };
        item.tags = copyTags(self.tags_allocator orelse self.owned.allocator(), response.tags) catch return self.answer(error.OutOfMemory);
        item.photo.state = response.state;
        self.store.setTags(item.photo.id, response.tags, response.state, self, saved);
    }
    fn saved(ctx: ?*anyopaque, result: api.Error!void) void {
        const self: *TagQueue = @ptrCast(@alignCast(ctx.?));
        if (self.items[self.active].photo.state != .failed) result catch |err| return self.answer(err);
        if (self.items[self.active].photo.state != .new and self.asked != null and std.mem.eql(u8, self.asked.?, self.busy.?)) self.asked = null;
        self.busy = null;
        _ = self.arena.reset(.free_all);
    }
};
fn copyTags(a: std.mem.Allocator, tags: []const model.Tag) ![]model.Tag {
    const out = try a.dupe(model.Tag, tags);
    for (out) |*tag| inline for (.{ "species", "model", "detail", "note" }) |field| {
        if (@FieldType(model.Tag, field) == []const u8) @field(tag, field) = try a.dupe(u8, @field(tag, field)) else if (@field(tag, field)) |s| {
            @field(tag, field) = try a.dupe(u8, s);
        }
    };
    return out;
}
