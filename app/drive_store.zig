const std = @import("std");
const vfs = @import("core").vfs;
const m = @import("model");
const api = @import("store.zig");
const Done = api.Done;
const props = @import("drive_props.zig");
const Items = []const api.Item;
const Places = []const m.Place;
const P = *anyopaque;
const C = ?*anyopaque;
pub const Clock = *const fn () i64;
pub const Info = struct {
    md5: [16]u8 = @splat(0),
    taken_ms: i64 = 0,
    lat: ?f64 = null,
    lon: ?f64 = null,
    camera: []const u8 = "",
    w: u32 = 0,
    h: u32 = 0,
    props: []const u8 = "{}",
};
pub const Meta = struct {
    ctx: *anyopaque,
    info: *const fn (*anyopaque, std.mem.Allocator, []const u8) ?Info,
    thumbnail: *const fn (*anyopaque, []const u8, u32, *Pending) void,
    setProps: *const fn (*anyopaque, []const u8, []const u8, *Pending) void,
};
pub const Pending = struct {
    store: *DriveStore,
    arena: std.heap.ArenaAllocator = undefined,
    ctx: C,
    done: union(enum) { thumbnail: Done(api.Thumbnail), props: Done(void) },
    wash: u8 = 0,
    result: api.Error![]u8 = error.Io,
    pub fn answer(p: *Pending, result: ?[]const u8) void {
        p.result = if (result) |b| p.store.gpa.dupe(u8, b) catch @panic("OOM") else error.Io;
        p.store.queue(p.ctx, .{ .meta = p });
    }
    pub fn unsupported(p: *Pending) void {
        p.result = error.Unsupported;
        p.store.queue(p.ctx, .{ .meta = p });
    }
    fn free(p: *Pending) void {
        if (p.result) |b| p.store.gpa.free(b) else |_| {}
        p.store.gpa.destroy(p);
    }
};
pub const DriveStore = struct {
    clock: Clock,
    meta: ?Meta,
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
        jobs: std.ArrayList(vfs.Job) = .empty,
        failed: bool = false,
        stale: bool = false,
    },
    const Import = struct {
        s: *DriveStore,
        arena: std.heap.ArenaAllocator,
        ctx: C,
        done: Done(api.Imported),
        state: enum { make_root, make_year, probe, write } = .make_root,
        name: []const u8 = "",
        bytes: []const u8 = "",
        md5: [16]u8 = undefined,
        dir: []const u8 = "",
        id: []const u8 = "",
        path: []const u8 = "",
        number: u64 = 1,
        failed: bool = false,
        retired: bool = false,
        job: ?vfs.Job = null,
        fn start(o: *Import) !void {
            const a = o.arena.allocator();
            switch (o.state) {
                .make_root => o.job = try o.s.fs.mkdir(o.s.root, wrote, o),
                .make_year => {
                    const secs = std.math.cast(u64, o.s.clock()) orelse return error.Io;
                    // Bound the conversion's year increment, which uses u16 internally.
                    if (secs / 86400 >= 23217004) return error.Io;
                    const year = (std.time.epoch.EpochSeconds{ .secs = secs })
                        .getEpochDay().calculateYearDay().year;
                    o.dir = try std.fmt.allocPrint(a, "{d}", .{year});
                    o.job = try o.s.fs.mkdir(try vfs.path.join(a, o.s.root, o.dir), wrote, o);
                },
                .probe => {
                    const name = if (o.number == 1) o.name else try std.fmt.allocPrint(
                        a,
                        "{s} ({d}){s}",
                        .{ std.fs.path.stem(o.name), o.number, std.fs.path.extension(o.name) },
                    );
                    o.id = try vfs.path.join(a, o.dir, name);
                    o.path = try vfs.path.join(a, o.s.root, o.id);
                    o.job = try o.s.fs.stat(o.path, probed, o);
                },
                .write => o.job = try o.s.fs.writeFile(o.path, o.bytes, .{}, wrote, o),
            }
        }
        fn end(o: *Import, result: api.Error!api.Imported) void {
            o.retired = true;
            o.s.importing = null;
            o.done(o.ctx, result);
        }
        fn answer(o: *Import, stat: vfs.Stat, new: bool) void {
            o.s.invalidate();
            end(o, .{ .new = new, .photo = .{
                .id = o.id,
                .name = std.fs.path.basename(o.id),
                .bytes = stat.size,
                .taken_at = if (stat.modified_ms > 0) @divFloor(stat.modified_ms, 1000) else null,
                .w = 4,
                .h = 3,
                .md5 = .{ .bytes = o.md5 },
            } });
        }
        fn wrote(ctx: C, result: vfs.Result(void)) void {
            const o: *Import = @ptrCast(@alignCast(ctx.?));
            o.job = null;
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
            o.job = null;
            if (result.get()) |stat| {
                var same = stat.kind == .file and stat.size == o.bytes.len and o.number == 1;
                if (same) if (o.s.meta) |meta| {
                    if (meta.info(meta.ctx, o.arena.allocator(), o.path)) |info| {
                        if (!std.mem.allEqual(u8, &info.md5, 0))
                            same = std.mem.eql(u8, &info.md5, &o.md5);
                    }
                };
                if (same) return o.answer(stat, false);
                o.number = std.math.add(u64, o.number, 1) catch return end(o, error.Io);
            } else |err| {
                if (err != error.NotFound) return end(o, error.Io);
                o.state = .write;
            }
            o.start() catch end(o, error.Io);
        }
    };
    /// A conflicting save rereads once, then retries the caller's values: last writer wins.
    /// A file deleted meanwhile is written again.
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
        job: ?vfs.Job = null,
        fn start(o: *PlacesOp) !void {
            switch (o.state) {
                .read, .reread => o.job = try o.s.fs.readFile(o.arena.allocator(), o.path, read, o),
                .write, .rewrite => o.job = try o.s.fs.writeFile(
                    o.path,
                    o.bytes,
                    .{ .if_unmodified_ms = o.s.places_ms },
                    wrote,
                    o,
                ),
                .stat => o.job = try o.s.fs.stat(o.path, stated, o),
            }
        }
        fn read(ctx: C, result: vfs.Result(vfs.Read)) void {
            const o: *PlacesOp = @ptrCast(@alignCast(ctx.?));
            o.job = null;
            const value = result.get() catch |err| {
                if (err != error.NotFound) return end(o, error.Io);
                o.s.places_ms = null;
                if (o.state == .read) return end(o, &.{});
                o.state = .rewrite;
                return o.start() catch end(o, error.Io);
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
            o.job = null;
            o.state = if (result.get()) |_| .stat else |err| retry: {
                if (err != error.Conflict or o.state != .write) return end(o, error.Io);
                break :retry .reread;
            };
            o.start() catch end(o, error.Io);
        }
        fn end(o: *PlacesOp, result: api.Error!Places) void {
            o.retired = true;
            o.done(o.ctx, result);
        }
        fn stated(ctx: C, result: vfs.Result(vfs.Stat)) void {
            const o: *PlacesOp = @ptrCast(@alignCast(ctx.?));
            o.job = null;
            const stat = result.get() catch return end(o, error.Io);
            o.s.places_ms = stat.modified_ms;
            end(o, o.values);
        }
    };
    const Folder = struct { self: *DriveStore, name: []const u8 };
    const Answer = struct {
        ctx: C,
        reply: union(enum) {
            list: struct { done: Done(Items), after: ?[]u8, limit: u32 },
            wash: struct { done: Done(api.Thumbnail), value: u8 },
            refused_void: Done(void),
            meta: *Pending,
        },
    };
    pub fn init(a: std.mem.Allocator, fs: vfs.Fs, r: []const u8, c: Clock, mt: ?Meta) !DriveStore {
        const l: @FieldType(DriveStore, "listing") = .{ .arenas = .{ .init(a), .init(a) } };
        const copy = try a.dupe(u8, r);
        return .{ .gpa = a, .fs = fs, .root = copy, .listing = l, .clock = c, .meta = mt };
    }
    /// Cancels pending jobs so no callback runs after deinit.
    pub fn deinit(self: *DriveStore) void {
        self.reap(true);
        if (self.listing.state == .reading) {
            for (self.listing.jobs.items) |job| self.fs.cancel(job);
        }
        for (self.answers.items) |answer| {
            if (answer.reply == .meta) answer.reply.meta.free();
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
        self.readListing();
    }
    fn readListing(self: *DriveStore) void {
        self.listing.stale = false;
        self.listing.state = .reading;
        self.listing.failed = false;
        _ = self.listing.arenas[self.listing.live ^ 1].reset(.retain_capacity);
        self.listing.pending = .empty;
        self.listing.jobs = .empty;
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
        try s.listing.jobs.ensureUnusedCapacity(s.arena(), 1);
        s.listing.jobs.appendAssumeCapacity(try s.fs.listDir(s.arena(), path, listed, folder));
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
            var item: api.Item = .{ .photo = .{
                .id = id,
                .name = id[id.len - entry.name.len ..],
                .bytes = entry.size,
                .taken_at = at,
                .w = 4,
                .h = 3,
                .md5 = .{ .bytes = @splat(0) },
            }, .tags = &.{} };
            if (s.meta) |meta| {
                const path = try vfs.path.join(s.arena(), s.root, id);
                if (meta.info(meta.ctx, s.arena(), path)) |info| {
                    item.photo.md5.bytes = info.md5;
                    if (info.taken_ms > 0) item.photo.taken_at = @divFloor(info.taken_ms, 1000);
                    if (info.lat != null and info.lon != null)
                        item.photo.place = .{ .lat = info.lat.?, .lon = info.lon.? };
                    item.photo.camera = info.camera;
                    if (info.w > 0 and info.h > 0) {
                        item.photo.w = info.w;
                        item.photo.h = info.h;
                    }
                    const decoded = props.decode(s.arena(), info.props);
                    item.tags = decoded.tags;
                    if (decoded.state) |state| item.photo.state = state;
                    item.photo.favorite = decoded.favorite;
                }
            }
            try s.listing.pending.append(s.arena(), item);
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
        if (self.listing.stale) return self.readListing();
        self.listing.items = self.listing.pending.items;
        std.mem.sort(api.Item, self.listing.items, {}, less);
        self.listing.live ^= 1;
        self.listing.state = .ready;
    }
    fn thumbnail(ptr: P, id: []const u8, px: u32, ctx: C, done: Done(api.Thumbnail)) void {
        const value = @as(u8, @truncate(std.hash.Wyhash.hash(0, id))) % 6;
        const s = cast(ptr);
        if (s.meta) |meta| {
            const p = s.gpa.create(Pending) catch @panic("OOM");
            p.* = .{ .store = s, .ctx = ctx, .done = .{ .thumbnail = done }, .wash = value };
            const path = vfs.path.join(s.gpa, s.root, id) catch @panic("OOM");
            defer s.gpa.free(path);
            return meta.thumbnail(meta.ctx, path, px, p);
        }
        s.queue(ctx, .{ .wash = .{ .done = done, .value = value } });
    }
    fn importFile(p: P, name: []const u8, bytes: []const u8, c: C, d: Done(api.Imported)) void {
        const s = cast(p);
        std.debug.assert(s.importing == null);
        const o = s.gpa.create(Import) catch @panic("OOM");
        o.* = .{ .s = s, .arena = .init(s.gpa), .ctx = c, .done = d };
        const a = o.arena.allocator();
        o.name = a.dupe(u8, name) catch @panic("OOM");
        o.bytes = a.dupe(u8, bytes) catch @panic("OOM");
        std.crypto.hash.Md5.hash(bytes, &o.md5, .{});
        s.imports.append(s.gpa, o) catch @panic("OOM");
        s.importing = o;
        o.start() catch {
            o.failed = true;
        };
    }
    fn invalidate(s: *DriveStore) void {
        s.listing.stale = s.listing.state == .reading;
        if (!s.listing.stale) s.listing.state = .empty;
    }
    fn setTags(p: P, id: []const u8, t: []const m.Tag, v: m.Photo.State, c: C, d: Done(void)) void {
        const s = cast(p);
        const text = props.encodeTags(s.gpa, t, v) catch @panic("OOM");
        defer s.gpa.free(text);
        s.setProps(id, text, c, d);
    }
    fn setFavorite(p: P, id: []const u8, on: bool, c: C, d: Done(void)) void {
        cast(p).setProps(id, props.encodeFavorite(on), c, d);
    }
    fn setProps(s: *DriveStore, id: []const u8, text: []const u8, c: C, d: Done(void)) void {
        const meta = s.meta orelse return s.queue(c, .{ .refused_void = d });
        const p = s.gpa.create(Pending) catch @panic("OOM");
        p.* = .{ .store = s, .ctx = c, .done = .{ .props = d } };
        const path = vfs.path.join(s.gpa, s.root, id) catch @panic("OOM");
        defer s.gpa.free(path);
        meta.setProps(meta.ctx, path, text, p);
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
                    if (!o.retired) if (o.job) |job| s.fs.cancel(job);
                    o.arena.deinit();
                    s.gpa.destroy(o);
                    _ = ops.swapRemove(i);
                } else {
                    if (o.failed) o.end(error.Io);
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
            .meta => |p| {
                defer p.free();
                switch (p.done) {
                    .thumbnail => |done| {
                        const bytes = p.result catch null;
                        done(p.ctx, if (bytes) |b| .{ .encoded = b } else .{ .wash = p.wash });
                    },
                    .props => |done| {
                        if (p.result) |_| {
                            self.invalidate();
                            done(p.ctx, {});
                        } else |err| done(p.ctx, err);
                    },
                }
            },
            .refused_void => |done| done(answer.ctx, error.Unsupported),
        };
    }
};
