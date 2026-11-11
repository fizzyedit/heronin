const std = @import("std");
const vfs = @import("core").vfs;
const m = @import("model");
const api = @import("store.zig");
const Done = api.Done;
const Items = []const api.Item;
const Places = []const m.Place;
const P = *anyopaque;
const C = ?*anyopaque;
pub const DriveStore = struct {
    gpa: std.mem.Allocator,
    fs: vfs.Fs,
    root: []u8,
    answers: std.ArrayList(Answer) = .empty,
    listing: struct {
        state: enum { empty, reading, ready } = .empty,
        left: u32 = 0,
        arenas: [2]std.heap.ArenaAllocator,
        live: u1 = 0,
        items: []api.Item = &.{},
        pending: std.ArrayList(api.Item) = .empty,
        failed: bool = false,
    },
    const Folder = struct { self: *DriveStore, name: []const u8 };
    const Answer = struct {
        ctx: C,
        reply: union(enum) {
            list: struct { done: Done(Items), after: ?[]u8, limit: u32 },
            wash: struct { done: Done(api.Thumbnail), value: u8 },
            refused_void: Done(void),
            refused_import: Done(api.Imported),
            refused_places: Done(Places),
        },
    };
    pub fn init(gpa: std.mem.Allocator, fs: vfs.Fs, root: []const u8) !DriveStore {
        const l: @FieldType(DriveStore, "listing") = .{ .arenas = .{ .init(gpa), .init(gpa) } };
        return .{ .gpa = gpa, .fs = fs, .root = try gpa.dupe(u8, root), .listing = l };
    }
    pub fn deinit(self: *DriveStore) void {
        for (self.answers.items) |answer| {
            if (answer.reply == .list) self.gpa.free(answer.reply.list.after orelse continue);
        }
        self.answers.deinit(self.gpa);
        for (&self.listing.arenas) |*a| a.deinit();
        self.gpa.free(self.root);
    }
    pub fn store(self: *DriveStore) api.Store {
        return .{ .ptr = self, .vtable = &.{
            .list = list,
            .thumbnail = thumbnail,
            .importFile = importFile,
            .setTags = setTags,
            .setFavorite = setFavorite,
            .places = places,
            .savePlaces = savePlaces,
            .pump = pump,
        } };
    }
    fn cast(ptr: P) *DriveStore {
        return @ptrCast(@alignCast(ptr));
    }
    fn arena(self: *DriveStore) std.mem.Allocator {
        return self.listing.arenas[self.listing.live ^ 1].allocator();
    }
    fn queue(self: *DriveStore, ctx: C, reply: @FieldType(Answer, "reply")) void {
        self.answers.append(self.gpa, .{ .ctx = ctx, .reply = reply }) catch @panic("OOM");
    }
    fn list(ptr: P, after: ?[]const u8, limit: u32, ctx: C, done: Done(Items)) void {
        const self = cast(ptr);
        const copy = if (after) |s| self.gpa.dupe(u8, s) catch @panic("OOM") else null;
        self.queue(ctx, .{ .list = .{ .done = done, .after = copy, .limit = limit } });
        if (self.listing.state != .empty) return;
        self.listing.state = .reading;
        self.listing.failed = false;
        _ = self.listing.arenas[self.listing.live ^ 1].reset(.retain_capacity);
        self.listing.pending = .empty;
        self.startFolder("") catch {
            self.listing.failed = true;
            self.listing.state = .ready;
        };
    }
    fn listed(ctx: C, result: vfs.Result([]vfs.Entry)) void {
        const folder: *Folder = @ptrCast(@alignCast(ctx.?));
        const self = folder.self;
        const entries = result.get() catch |err| {
            self.listing.failed = folder.name.len != 0 or err != error.NotFound;
            return self.finish();
        };
        self.collect(folder.name, entries) catch {
            self.listing.failed = true;
        };
        for (entries) |entry| {
            if (folder.name.len != 0) break;
            if (entry.kind != .dir or entry.name.len != 4) continue;
            if (std.mem.indexOfNone(u8, entry.name, "0123456789") != null) continue;
            self.startFolder(entry.name) catch {
                self.listing.failed = true;
            };
        }
        self.finish();
    }
    fn startFolder(s: *DriveStore, name: []const u8) !void {
        const folder = try s.arena().create(Folder);
        folder.* = .{ .self = s, .name = name };
        const path = if (name.len == 0) s.root else try vfs.path.join(s.arena(), s.root, name);
        const left = std.math.add(u32, s.listing.left, 1) catch return error.Io;
        _ = try s.fs.listDir(s.arena(), path, listed, folder);
        s.listing.left = left;
    }
    fn collect(s: *DriveStore, d: []const u8, entries: []vfs.Entry) !void {
        for (entries) |entry| {
            if (entry.kind != .file) continue;
            const ext = std.fs.path.extension(entry.name);
            for ([_][]const u8{ ".jpg", ".jpeg", ".png", ".heic", ".webp" }) |suffix| {
                if (std.ascii.eqlIgnoreCase(ext, suffix)) break;
            } else continue;
            const id = if (d.len == 0) entry.name else try vfs.path.join(s.arena(), d, entry.name);
            const at = if (entry.modified_ms > 0) @divFloor(entry.modified_ms, 1000) else null;
            try s.listing.pending.append(s.arena(), .{ .photo = .{
                .id = id,
                .name = id[id.len - entry.name.len ..],
                .bytes = entry.size,
                .taken_at = at,
                .w = 4,
                .h = 3,
                .md5 = .{ .bytes = @splat(0) },
            }, .tags = &.{} });
        }
    }
    fn less(_: void, a: api.Item, b: api.Item) bool {
        const at = a.photo.taken_at orelse -1;
        const bt = b.photo.taken_at orelse -1;
        return if (at != bt) at > bt else std.mem.lessThan(u8, a.photo.id, b.photo.id);
    }
    fn finish(self: *DriveStore) void {
        self.listing.left -= 1;
        if (self.listing.left != 0) return;
        self.listing.items = self.listing.pending.items;
        std.mem.sort(api.Item, self.listing.items, {}, less);
        self.listing.live ^= 1;
        self.listing.state = .ready;
    }
    fn thumbnail(ptr: P, id: []const u8, _: u32, ctx: C, done: Done(api.Thumbnail)) void {
        const value = @as(u8, @truncate(std.hash.Wyhash.hash(0, id))) % 6;
        cast(ptr).queue(ctx, .{ .wash = .{ .done = done, .value = value } });
    }
    fn importFile(ptr: P, _: []const u8, _: []const u8, ctx: C, done: Done(api.Imported)) void {
        cast(ptr).queue(ctx, .{ .refused_import = done });
    }
    fn setTags(p: P, _: []const u8, _: []const m.Tag, _: m.Photo.State, c: C, d: Done(void)) void {
        cast(p).queue(c, .{ .refused_void = d });
    }
    fn setFavorite(ptr: P, _: []const u8, _: bool, ctx: C, done: Done(void)) void {
        cast(ptr).queue(ctx, .{ .refused_void = done });
    }
    fn places(ptr: P, ctx: C, done: Done(Places)) void {
        cast(ptr).queue(ctx, .{ .refused_places = done });
    }
    fn savePlaces(ptr: P, _: Places, ctx: C, done: Done(Places)) void {
        places(ptr, ctx, done);
    }
    fn page(self: *DriveStore, after: ?[]u8, limit: u32) api.Error!Items {
        var start: usize = 0;
        const items = self.listing.items;
        if (after) |id| {
            while (start < items.len and !std.mem.eql(u8, items[start].photo.id, id)) {
                start += 1;
            }
            if (start == items.len) return error.NotFound;
            start += 1;
        }
        return items[start .. start + @min(items.len - start, limit)];
    }
    fn pump(ptr: P) void {
        const self = cast(ptr);
        self.fs.pump();
        const failed = self.listing.failed;
        const ready = self.listing.state == .ready;
        if (ready and failed) self.listing.state = .empty;
        var answers = self.answers;
        self.answers = .empty;
        defer answers.deinit(self.gpa);
        for (answers.items) |answer| switch (answer.reply) {
            .list => |a| {
                if (!ready) {
                    self.queue(answer.ctx, answer.reply);
                    continue;
                }
                defer self.gpa.free(a.after orelse &.{});
                a.done(answer.ctx, if (failed) error.Io else self.page(a.after, a.limit));
            },
            .wash => |a| a.done(answer.ctx, .{ .wash = a.value }),
            .refused_void => |done| done(answer.ctx, error.Unsupported),
            .refused_import => |done| done(answer.ctx, error.Unsupported),
            .refused_places => |done| done(answer.ctx, error.Unsupported),
        };
    }
};
