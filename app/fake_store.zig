const std = @import("std");
const model = @import("model");
const api = @import("store.zig");
pub const FakeStore = struct {
    arena: std.heap.ArenaAllocator,
    answers: [2]std.heap.ArenaAllocator,
    live: u1 = 0,
    imports: usize = 0,
    items: []api.Item,
    saved: []const model.Place,
    head: ?*Answer = null,
    tail: ?*Answer = null,
    const Answer = struct { next: ?*Answer = null, deliver: *const fn (*Answer) void };
    pub fn init(allocator: std.mem.Allocator) !FakeStore {
        var self: FakeStore = .{ .arena = .init(allocator), .answers = .{ .init(allocator), .init(allocator) }, .items = undefined, .saved = undefined };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        self.items = try a.alloc(api.Item, 60);
        self.saved = try a.dupe(model.Place, &.{
            .{ .id = 1, .name = "Backyard", .lat = 0.0105, .lon = 0.0105, .radius_m = 500 },
            .{ .id = 2, .name = "Marsh trail", .lat = 60.0105, .lon = -29.9895, .radius_m = 500 },
        });
        for (self.items, 0..) |*item, i| {
            const name = try std.fmt.allocPrint(a, "fake-{d:0>2}.jpg", .{i});
            const at: i64 = 1_793_000_000 - @as(i64, @intCast(i * 9 / 60)) * 86_400 - @as(i64, @intCast(i % 7)) * 2_400;
            const offset = @as(f64, @floatFromInt(i % 10)) * 0.0003;
            const marsh_lat: f64 = 60.0105;
            const origin_lat: f64 = 0.0105;
            const east_lon: f64 = 179.9995;
            const west_lon: f64 = -179.9995;
            item.* = .{ .photo = .{
                .id = name[0..7],
                .name = name,
                .md5 = .{ .bytes = @splat(@intCast(i)) },
                .taken_at = at,
                .bytes = 2_000_000 + i * 1000,
                .camera = if (i % 2 == 0) "Fake Camera" else null,
                .w = if (i % 3 == 0) 4000 else 3000,
                .h = if (i % 3 == 1) 4000 else 3000,
                .state = ([_]model.Photo.State{ .tagged, .review, .tagging, .new, .failed, .skipped })[i % 6],
                .favorite = i % 5 == 0,
                .place = if (i % 4 == 3) null else .{ .lat = (if (i % 3 == 1) marsh_lat else origin_lat) + offset, .lon = switch (i % 3) {
                    0 => 0.0105 + offset,
                    1 => -29.9895 + offset,
                    else => if (i % 2 == 0) east_lon else west_lon,
                } },
            }, .tags = &.{} };
            const tags = try a.alloc(model.Tag, if (i % 6 == 0) 1 else if (i % 6 == 1) 3 else 0);
            for (tags, 0..) |*tag, j| tag.* = .{
                .species = model.species.table[(i + j) % 12].code,
                .confidence = if (tags.len == 1) 0.92 else ([_]f32{ 0.62, 0.21, 0.09 })[j],
                .source = .ours,
                .accepted = .auto,
                .model = "fake",
                .at = at + 60,
                .box = if (i % 2 == 0) .{ .x = 0.3, .y = 0.25, .w = 0.4, .h = 0.5 } else null,
                .detail = if (i % 4 == 0) "adult male" else null,
                .note = if (i % 3 == 0) "Crest, red bill and black face matched." else null,
            };
            item.tags = tags;
        }
        std.mem.sort(api.Item, self.items, {}, struct {
            fn less(_: void, left: api.Item, right: api.Item) bool {
                return left.photo.taken_at.? > right.photo.taken_at.?;
            }
        }.less);
        return self;
    }
    pub fn deinit(self: *FakeStore) void {
        self.arena.deinit();
        for (&self.answers) |*arena| arena.deinit();
    }
    pub fn store(self: *FakeStore) api.Store {
        return .{ .ptr = self, .vtable = &.{ .list = list, .thumbnail = thumbnail, .importFile = importFile, .setTags = setTags, .setFavorite = setFavorite, .places = places, .savePlaces = savePlaces, .pump = pump } };
    }
    fn cast(ptr: *anyopaque) *FakeStore {
        return @ptrCast(@alignCast(ptr));
    }
    fn index(self: *FakeStore, id: []const u8) ?usize {
        for (self.items, 0..) |item, i| if (std.mem.eql(u8, item.photo.id, id)) return i;
        return null;
    }
    fn answer(self: *FakeStore, comptime T: type, ctx: ?*anyopaque, done: api.Done(T), result: api.Error!T) void {
        const Node = struct {
            base: Answer = .{ .deliver = deliver },
            ctx: ?*anyopaque,
            done: api.Done(T),
            result: api.Error!T,
            fn deliver(base: *Answer) void {
                const node: *@This() = @alignCast(@fieldParentPtr("base", base));
                node.done(node.ctx, node.result);
            }
        };
        const node = self.answers[self.live].allocator().create(Node) catch @panic("FakeStore answer queue exhausted");
        node.* = .{ .ctx = ctx, .done = done, .result = result };
        if (self.tail) |tail| tail.next = &node.base else self.head = &node.base;
        self.tail = &node.base;
    }
    fn list(ptr: *anyopaque, after: ?[]const u8, limit: u32, ctx: ?*anyopaque, done: api.Done([]const api.Item)) void {
        const self = cast(ptr);
        const start = if (after) |id| (self.index(id) orelse return self.answer([]const api.Item, ctx, done, error.NotFound)) + 1 else 0;
        self.answer([]const api.Item, ctx, done, self.items[start..@min(self.items.len, start + @as(usize, limit))]);
    }
    fn thumbnail(ptr: *anyopaque, id: []const u8, _: u32, ctx: ?*anyopaque, done: api.Done(api.Thumbnail)) void {
        const self = cast(ptr);
        const i = self.index(id) orelse return self.answer(api.Thumbnail, ctx, done, error.NotFound);
        self.answer(api.Thumbnail, ctx, done, .{ .wash = self.items[i].photo.md5.bytes[0] % 6 });
    }
    fn importFile(ptr: *anyopaque, name: []const u8, bytes: []const u8, ctx: ?*anyopaque, done: api.Done(api.Imported)) void {
        const self = cast(ptr);
        var md5: model.Md5 = undefined;
        std.crypto.hash.Md5.hash(bytes, &md5.bytes, .{});
        for (self.items) |item| if (std.mem.eql(u8, &item.photo.md5.bytes, &md5.bytes)) return self.answer(api.Imported, ctx, done, .{ .photo = item.photo, .new = false });
        const a = self.arena.allocator();
        const items = a.alloc(api.Item, self.items.len + 1) catch return self.answer(api.Imported, ctx, done, error.OutOfMemory);
        const id = std.fmt.allocPrint(a, "imp-{d:0>3}", .{self.imports}) catch return self.answer(api.Imported, ctx, done, error.OutOfMemory);
        const copy = a.dupe(u8, name) catch return self.answer(api.Imported, ctx, done, error.OutOfMemory);
        items[0] = .{ .photo = .{ .id = id, .name = copy, .md5 = md5, .bytes = bytes.len, .w = 4000, .h = 3000 }, .tags = &.{} };
        @memcpy(items[1..], self.items);
        self.items = items;
        self.imports += 1;
        self.answer(api.Imported, ctx, done, .{ .photo = items[0].photo, .new = true });
    }
    fn setTags(ptr: *anyopaque, id: []const u8, tags: []const model.Tag, state: model.Photo.State, ctx: ?*anyopaque, done: api.Done(void)) void {
        const self = cast(ptr);
        const i = self.index(id) orelse return self.answer(void, ctx, done, error.NotFound);
        const a = self.arena.allocator();
        const copy = a.dupe(model.Tag, tags) catch return self.answer(void, ctx, done, error.OutOfMemory);
        for (copy) |*tag| {
            tag.species = a.dupe(u8, tag.species) catch return self.answer(void, ctx, done, error.OutOfMemory);
            tag.model = a.dupe(u8, tag.model) catch return self.answer(void, ctx, done, error.OutOfMemory);
            if (tag.detail) |s| tag.detail = a.dupe(u8, s) catch return self.answer(void, ctx, done, error.OutOfMemory);
            if (tag.note) |s| tag.note = a.dupe(u8, s) catch return self.answer(void, ctx, done, error.OutOfMemory);
        }
        self.items[i].tags = copy;
        self.items[i].photo.state = state;
        self.answer(void, ctx, done, {});
    }
    fn setFavorite(ptr: *anyopaque, id: []const u8, on: bool, ctx: ?*anyopaque, done: api.Done(void)) void {
        const self = cast(ptr);
        const i = self.index(id) orelse return self.answer(void, ctx, done, error.NotFound);
        self.items[i].photo.favorite = on;
        self.answer(void, ctx, done, {});
    }
    fn places(ptr: *anyopaque, ctx: ?*anyopaque, done: api.Done([]const model.Place)) void {
        const self = cast(ptr);
        self.answer([]const model.Place, ctx, done, self.saved);
    }
    fn savePlaces(ptr: *anyopaque, values: []const model.Place, ctx: ?*anyopaque, done: api.Done([]const model.Place)) void {
        const self = cast(ptr);
        const a = self.arena.allocator();
        const saved = a.dupe(model.Place, values) catch return self.answer([]const model.Place, ctx, done, error.OutOfMemory);
        for (saved) |*p| p.name = a.dupe(u8, p.name) catch return self.answer([]const model.Place, ctx, done, error.OutOfMemory);
        self.saved = saved;
        self.answer([]const model.Place, ctx, done, saved);
    }
    /// Not reentrant; callbacks may queue answers for the next pump.
    fn pump(ptr: *anyopaque) void {
        const self = cast(ptr);
        const detached = self.live;
        self.live ^= 1;
        defer _ = self.answers[detached].reset(.retain_capacity);
        var next = self.head;
        self.head = null;
        self.tail = null;
        while (next) |node| {
            next = node.next;
            node.deliver(node);
        }
    }
};
