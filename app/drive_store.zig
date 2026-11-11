const std = @import("std");
const vfs = @import("core").vfs;
const m = @import("model");
const api = @import("store.zig");
const Done = api.Done;
const Items = []const api.Item;
const Places = []const m.Place;
const P = *anyopaque;
const C = ?*anyopaque;
pub const Clock = *const fn () i64;
pub const DriveStore = struct {
    clock: Clock,
    places_ms: ?i64 = null,
    importing: ?*Import = null,
    imports: std.ArrayList(*Import) = .empty,
    place_ops: std.ArrayList(*PlacesOp) = .empty,
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
    const Import = struct {
        s: *DriveStore,
        arena: std.heap.ArenaAllocator,
        ctx: C,
        done: Done(api.Imported),
        state: enum { make_root, make_year, probe, write } = .make_root,
        name: []const u8 = "",
        bytes: []const u8 = "",
        dir: []const u8 = "",
        id: []const u8 = "",
        path: []const u8 = "",
        number: u64 = 1,
        failed: bool = false,
        retired: bool = false,
        fn start(o: *Import) !void {
            const a = o.arena.allocator();
            switch (o.state) {
                .make_root => _ = try o.s.fs.mkdir(o.s.root, wrote, o),
                .make_year => {
                    const secs = std.math.cast(u64, o.s.clock()) orelse return error.Io;
                    // Bound the conversion's year increment, which uses u16 internally.
                    if (secs / 86400 >= 23217004) return error.Io;
                    const year = (std.time.epoch.EpochSeconds{ .secs = secs })
                        .getEpochDay().calculateYearDay().year;
                    o.dir = try std.fmt.allocPrint(a, "{d}", .{year});
                    _ = try o.s.fs.mkdir(try vfs.path.join(a, o.s.root, o.dir), wrote, o);
                },
                .probe => {
                    const name = if (o.number == 1) o.name else try std.fmt.allocPrint(
                        a,
                        "{s} ({d}){s}",
                        .{ std.fs.path.stem(o.name), o.number, std.fs.path.extension(o.name) },
                    );
                    o.id = try vfs.path.join(a, o.dir, name);
                    o.path = try vfs.path.join(a, o.s.root, o.id);
                    _ = try o.s.fs.stat(o.path, probed, o);
                },
                .write => _ = try o.s.fs.writeFile(o.path, o.bytes, .{}, wrote, o),
            }
        }
        fn answer(o: *Import, stat: vfs.Stat, new: bool) void {
            o.s.listing.state = .empty;
            end(o, .{ .new = new, .photo = .{
                .id = o.id,
                .name = std.fs.path.basename(o.id),
                .bytes = stat.size,
                .taken_at = if (stat.modified_ms > 0) @divFloor(stat.modified_ms, 1000) else null,
                .w = 4,
                .h = 3,
                .md5 = .{ .bytes = @splat(0) },
            } });
        }
        fn wrote(ctx: C, result: vfs.Result(void)) void {
            const o: *Import = @ptrCast(@alignCast(ctx.?));
            result.get() catch |err| {
                if (o.state == .write or err != error.Exists) return end(o, error.Io);
            };
            o.state = switch (o.state) {
                .make_root => .make_year,
                .make_year => .probe,
                .write => return o.answer(.{ .kind = .file, .size = o.bytes.len }, true),
                .probe => unreachable,
            };
            o.start() catch end(o, error.Io);
        }
        fn probed(ctx: C, result: vfs.Result(vfs.Stat)) void {
            const o: *Import = @ptrCast(@alignCast(ctx.?));
            if (result.get()) |stat| {
                if (stat.kind == .file and stat.size == o.bytes.len and o.number == 1)
                    return o.answer(stat, false);
                o.number = std.math.add(u64, o.number, 1) catch return end(o, error.Io);
            } else |err| {
                if (err != error.NotFound) return end(o, error.Io);
                o.state = .write;
            }
            o.start() catch end(o, error.Io);
        }
    };
    /// A conflicting save rereads once, then retries the caller's values: last writer wins.
    const PlacesOp = struct {
        s: *DriveStore,
        arena: std.heap.ArenaAllocator,
        ctx: C,
        done: Done(Places),
        state: enum { read, write, reread, rewrite, stat } = .read,
        path: []const u8 = "",
        bytes: []const u8 = "",
        values: Places = &.{},
        failed: bool = false,
        retired: bool = false,
        fn start(o: *PlacesOp) !void {
            switch (o.state) {
                .read, .reread => _ = try o.s.fs.readFile(o.arena.allocator(), o.path, read, o),
                .write, .rewrite => _ = try o.s.fs.writeFile(
                    o.path,
                    o.bytes,
                    .{ .if_unmodified_ms = o.s.places_ms },
                    wrote,
                    o,
                ),
                .stat => _ = try o.s.fs.stat(o.path, stated, o),
            }
        }
        fn read(ctx: C, result: vfs.Result(vfs.Read)) void {
            const o: *PlacesOp = @ptrCast(@alignCast(ctx.?));
            const value = result.get() catch |err| {
                if (err != error.NotFound or o.state != .read) return end(o, error.Io);
                o.s.places_ms = null;
                return end(o, &.{});
            };
            o.s.places_ms = value.modified_ms;
            if (o.state == .read) return end(o, std.json.parseFromSliceLeaky(
                Places,
                o.arena.allocator(),
                value.bytes,
                .{ .ignore_unknown_fields = true },
            ) catch return end(o, error.Io));
            o.state = .rewrite;
            o.start() catch end(o, error.Io);
        }
        fn wrote(ctx: C, result: vfs.Result(void)) void {
            const o: *PlacesOp = @ptrCast(@alignCast(ctx.?));
            o.state = if (result.get()) |_| .stat else |err| retry: {
                if (err != error.Conflict or o.state != .write) return end(o, error.Io);
                break :retry .reread;
            };
            o.start() catch end(o, error.Io);
        }
        fn stated(ctx: C, result: vfs.Result(vfs.Stat)) void {
            const o: *PlacesOp = @ptrCast(@alignCast(ctx.?));
            const stat = result.get() catch return end(o, error.Io);
            o.s.places_ms = stat.modified_ms;
            end(o, o.values);
        }
    };
    fn end(o: anytype, result: api.Error!if (@TypeOf(o) == *Import) api.Imported else Places) void {
        o.retired = true;
        if (@TypeOf(o) == *Import) o.s.importing = null;
        o.done(o.ctx, result);
    }
    const Folder = struct { self: *DriveStore, name: []const u8 };
    const Answer = struct {
        ctx: C,
        reply: union(enum) {
            list: struct { done: Done(Items), after: ?[]u8, limit: u32 },
            wash: struct { done: Done(api.Thumbnail), value: u8 },
            refused_void: Done(void),
        },
    };
    pub fn init(gpa: std.mem.Allocator, fs: vfs.Fs, root: []const u8, clock: Clock) !DriveStore {
        const l: @FieldType(DriveStore, "listing") = .{ .arenas = .{ .init(gpa), .init(gpa) } };
        const copy = try gpa.dupe(u8, root);
        return .{ .gpa = gpa, .fs = fs, .root = copy, .listing = l, .clock = clock };
    }
    pub fn deinit(self: *DriveStore) void {
        self.reap(true);
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
    fn importFile(p: P, name: []const u8, bytes: []const u8, c: C, d: Done(api.Imported)) void {
        const s = cast(p);
        std.debug.assert(s.importing == null);
        const o = s.gpa.create(Import) catch @panic("OOM");
        o.* = .{ .s = s, .arena = .init(s.gpa), .ctx = c, .done = d };
        const a = o.arena.allocator();
        o.name = a.dupe(u8, name) catch @panic("OOM");
        o.bytes = a.dupe(u8, bytes) catch @panic("OOM");
        s.imports.append(s.gpa, o) catch @panic("OOM");
        s.importing = o;
        o.start() catch {
            o.failed = true;
        };
    }
    fn setTags(p: P, _: []const u8, _: []const m.Tag, _: m.Photo.State, c: C, d: Done(void)) void {
        cast(p).queue(c, .{ .refused_void = d });
    }
    fn setFavorite(ptr: P, _: []const u8, _: bool, ctx: C, done: Done(void)) void {
        cast(ptr).queue(ctx, .{ .refused_void = done });
    }
    fn places(ptr: P, ctx: C, done: Done(Places)) void {
        placesOp(ptr, null, ctx, done);
    }
    fn savePlaces(ptr: P, values: Places, ctx: C, done: Done(Places)) void {
        placesOp(ptr, values, ctx, done);
    }
    fn placesOp(ptr: P, values: ?Places, ctx: C, done: Done(Places)) void {
        const s = cast(ptr);
        const o = s.gpa.create(PlacesOp) catch @panic("OOM");
        o.* = .{ .s = s, .arena = .init(s.gpa), .ctx = ctx, .done = done };
        const a = o.arena.allocator();
        o.path = vfs.path.join(a, s.root, "places.json") catch @panic("OOM");
        if (values) |v| {
            o.state = .write;
            o.bytes = std.json.Stringify.valueAlloc(a, v, .{}) catch @panic("OOM");
            o.values = std.json.parseFromSliceLeaky(Places, a, o.bytes, .{}) catch @panic("OOM");
        }
        s.place_ops.append(s.gpa, o) catch @panic("OOM");
        o.start() catch {
            o.failed = true;
        };
    }
    fn reap(s: *DriveStore, all: bool) void {
        inline for (.{ &s.imports, &s.place_ops }) |ops| {
            var i: usize = 0;
            while (i < ops.items.len) {
                const o = ops.items[i];
                if (all or o.retired) {
                    o.arena.deinit();
                    s.gpa.destroy(o);
                    _ = ops.swapRemove(i);
                } else {
                    if (o.failed) end(o, error.Io);
                    i += 1;
                }
            }
            if (all) ops.deinit(s.gpa);
        }
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
        self.reap(false);
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
        };
    }
};
