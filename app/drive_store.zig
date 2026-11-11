const std = @import("std");
const vfs = @import("core").vfs;
const path = vfs.path;
const api = @import("store.zig");
const model = @import("model");
pub const Clock = *const fn () i64;
const Kind = enum { list, thumbnail, import_file, unsupported, places, save };
const Callback = union(Kind) {
    list: api.Done([]const api.Item),
    thumbnail: api.Done(api.Thumbnail),
    import_file: api.Done(api.Imported),
    unsupported: api.Done(void),
    places: api.Done([]const model.Place),
    save: api.Done([]const model.Place),
};
/// Borrows Fs; an injected Unix-seconds clock supplies UTC years 1970..9999.
/// Place saves retry one conflict with fresh metadata (last writer wins after one retry).
pub const DriveStore = struct {
    config: struct {
        gpa: std.mem.Allocator,
        fs: vfs.Fs,
        root: []const u8,
        clock: Clock,
    },
    cache: struct {
        arenas: [2]std.heap.ArenaAllocator,
        live: u1 = 0,
        items: ?[]api.Item = null,
        modified: ?i64 = null,
    },
    queue: struct {
        head: ?*Request = null,
        tail: ?*Request = null,
        retired: ?*Request = null,
    } = .{},
    const Request = struct {
        owner: *DriveStore,
        arena: std.heap.ArenaAllocator,
        input: struct {
            cb: Callback,
            ctx: ?*anyopaque,
            name: []const u8 = "",
            bytes: []const u8 = "",
            failure: ?api.Error = null,
            limit: u32 = 0,
            after: ?[]const u8 = null,
        },
        state: struct {
            next: ?*Request = null,
            stage: u8 = 0,
            err: ?vfs.Error = null,
            job: ?vfs.Job = null,
            path: []const u8 = "",
            dirs: std.ArrayList([]const u8) = .empty,
            items: std.ArrayList(api.Item) = .empty,
            dir: usize = 0,
            suffix: u32 = 1,
            year: []const u8 = "",
            fresh: bool = true,
            entries: []vfs.Entry = &.{},
            stat: vfs.Stat = .{ .kind = .file },
            read: vfs.Read = .{ .bytes = &.{} },
            values: []const model.Place = &.{},
        } = .{},
        fn copy(r: *Request, name: []const u8, bytes: []const u8) !void {
            r.input.name = try r.allocator().dupe(u8, name);
            r.input.bytes = try r.allocator().dupe(u8, bytes);
        }
        fn save(r: *Request, values: []const model.Place) !void {
            r.input.bytes = try std.json.Stringify.valueAlloc(r.allocator(), values, .{});
            r.state.values = try std.json.parseFromSliceLeaky([]model.Place, r.allocator(), r.input.bytes, .{});
        }
        fn allocator(r: *Request) std.mem.Allocator {
            return r.arena.allocator();
        }
        fn listed(ctx: ?*anyopaque, result: vfs.Result([]vfs.Entry)) void {
            const r: *Request = @ptrCast(@alignCast(ctx.?));
            r.state.job = null;
            r.state.entries = result.get() catch |err| {
                r.state.err = err;
                return;
            };
        }
        fn stated(ctx: ?*anyopaque, result: vfs.Result(vfs.Stat)) void {
            const r: *Request = @ptrCast(@alignCast(ctx.?));
            r.state.job = null;
            r.state.stat = result.get() catch |err| {
                r.state.err = err;
                return;
            };
        }
        fn read(ctx: ?*anyopaque, result: vfs.Result(vfs.Read)) void {
            const r: *Request = @ptrCast(@alignCast(ctx.?));
            r.state.job = null;
            r.state.read = result.get() catch |err| {
                r.state.err = err;
                return;
            };
        }
        fn done(ctx: ?*anyopaque, result: vfs.Result(void)) void {
            const r: *Request = @ptrCast(@alignCast(ctx.?));
            r.state.job = null;
            result.get() catch |err| {
                r.state.err = err;
                return;
            };
        }
        fn begin(r: *Request, p: []const u8, stage: u8) void {
            r.state.path = p;
            r.state.stage = stage;
            r.state.err = null;
        }
        fn listDir(r: *Request, p: []const u8, stage: u8) !bool {
            r.begin(p, stage);
            r.state.job = try r.owner.config.fs.listDir(r.allocator(), p, listed, r);
            return false;
        }
        fn stat(r: *Request, p: []const u8, stage: u8) !bool {
            r.begin(p, stage);
            r.state.job = try r.owner.config.fs.stat(p, stated, r);
            return false;
        }
        fn readFile(r: *Request, p: []const u8, stage: u8) !bool {
            r.begin(p, stage);
            r.state.job = try r.owner.config.fs.readFile(r.allocator(), p, read, r);
            return false;
        }
        fn writeFile(r: *Request, p: []const u8, stage: u8) !bool {
            r.begin(p, stage);
            const modified = if (r.input.cb == .save) r.owner.cache.modified else null;
            r.state.job = try r.owner.config.fs.writeFile(p, r.input.bytes, .{ .if_unmodified_ms = modified }, done, r);
            return false;
        }
        fn mkdir(r: *Request, p: []const u8, stage: u8) !bool {
            r.begin(p, stage);
            r.state.job = try r.owner.config.fs.mkdir(p, done, r);
            return false;
        }
        fn step(r: *Request) !bool {
            const s = r.owner;
            const a = r.allocator();
            const d = &r.state;
            const in = r.input;
            switch (in.cb) {
                .unsupported, .thumbnail => return true,
                .list => {
                    if (s.cache.items != null) return true;
                    if (d.stage == 0) {
                        try d.dirs.append(a, "");
                        return r.listDir(s.config.root, 1);
                    }
                    if (d.err != null and (d.err.? != error.NotFound or d.dir != 0)) return error.Io;
                    for (d.entries) |entry| {
                        const id = if (d.dir == 0) entry.name else try path.join(a, d.dirs.items[d.dir], entry.name);
                        const is_year = entry.name.len == 4 and std.mem.indexOfNone(u8, entry.name, "0123456789") == null;
                        if (entry.kind == .dir and d.dir == 0 and is_year) try d.dirs.append(a, id);
                        if (entry.kind == .file and isImage(entry.name)) {
                            try d.items.append(a, .{ .photo = try photo(id, entry.size, entry.modified_ms), .tags = &.{} });
                        }
                    }
                    d.dir += 1;
                    if (d.dir < d.dirs.items.len) return r.listDir(try path.join(a, s.config.root, d.dirs.items[d.dir]), 1);
                    s.cache.live ^= 1;
                    _ = s.cache.arenas[s.cache.live].reset(.retain_capacity);
                    const dest = s.cache.arenas[s.cache.live].allocator();
                    const items = try dest.dupe(api.Item, d.items.items);
                    for (items) |*item| {
                        item.photo.id = try dest.dupe(u8, item.photo.id);
                        item.photo.name = path.basename(item.photo.id);
                    }
                    std.mem.sort(api.Item, items, {}, less);
                    s.cache.items = items;
                    return true;
                },
                .import_file => switch (d.stage) {
                    0 => {
                        d.year = try r.year();
                        s.cache.items = null;
                        return r.mkdir(s.config.root, 1);
                    },
                    1, 2 => {
                        if (d.err != null and d.err.? != error.Exists) return error.Io;
                        if (d.stage == 1) return r.mkdir(try path.join(a, s.config.root, d.year), 2);
                        return r.stat(try path.join(a, d.path, in.name), 3);
                    },
                    3 => {
                        if (d.err != null) {
                            if (d.err.? != error.NotFound) return error.Io;
                            return r.writeFile(d.path, 4);
                        }
                        _ = try photo(d.path, d.stat.size, d.stat.modified_ms);
                        if (d.suffix == 1 and d.stat.kind == .file and d.stat.size == in.bytes.len) {
                            d.fresh = false;
                            return true;
                        }
                        d.suffix = std.math.add(u32, d.suffix, 1) catch return error.Io;
                        const ext = std.fs.path.extension(in.name);
                        const name = try std.fmt.allocPrint(a, "{s} ({d}){s}", .{ in.name[0 .. in.name.len - ext.len], d.suffix, ext });
                        return r.stat(try path.join(a, path.dirname(d.path), name), 3);
                    },
                    4 => {
                        if (d.err != null) return error.Io;
                        d.stat.size = in.bytes.len;
                        return true;
                    },
                    else => unreachable,
                },
                .places, .save => switch (d.stage) {
                    0 => {
                        d.path = try path.join(a, s.config.root, "places.json");
                        return if (in.cb == .places) r.readFile(d.path, 1) else r.writeFile(d.path, 2);
                    },
                    1, 3 => {
                        if (d.err != null and d.err.? != error.NotFound) return error.Io;
                        if (d.err == null and (d.read.modified_ms < 0 or d.read.modified_ms > 253402300799999)) return error.Io;
                        s.cache.modified = if (d.err != null) null else d.read.modified_ms;
                        if (in.cb == .save) return r.writeFile(d.path, 4);
                        d.values = if (d.err != null) &.{} else try std.json.parseFromSliceLeaky([]model.Place, a, d.read.bytes, .{ .ignore_unknown_fields = true });
                        try validPlaces(d.values);
                        return true;
                    },
                    2, 4 => {
                        if (d.err != null and d.err.? == error.Conflict and d.stage == 2) return r.readFile(d.path, 3);
                        if (d.err != null) return error.Io;
                        return r.stat(d.path, 5);
                    },
                    else => {
                        if (d.err != null or d.stat.modified_ms < 0 or d.stat.modified_ms > 253402300799999) return error.Io;
                        s.cache.modified = d.stat.modified_ms;
                        return true;
                    },
                },
            }
        }
        fn year(r: *Request) ![]const u8 {
            const seconds = r.owner.config.clock();
            if (seconds < 0 or seconds > 253402300799) return error.Io;
            const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
            return std.fmt.allocPrint(r.allocator(), "{d}", .{epoch.getEpochDay().calculateYearDay().year});
        }
        fn deliver(r: *Request, failure: ?api.Error) void {
            const in = r.input;
            const d = r.state;
            switch (in.cb) {
                .list => |cb| {
                    const items = r.owner.cache.items orelse &.{};
                    const start = if (in.after) |id| (index(items, id) orelse return cb(in.ctx, failure orelse error.NotFound)) + 1 else 0;
                    cb(in.ctx, if (failure) |err| err else items[start .. start + @min(items.len - start, in.limit)]);
                },
                .thumbnail => |cb| {
                    var hash = std.hash.Wyhash.hash(0, in.name);
                    cb(in.ctx, if (failure) |err| err else .{ .wash = std.mem.asBytes(&hash)[0] % 6 });
                },
                .unsupported => |cb| cb(in.ctx, failure orelse error.Unsupported),
                .import_file => |cb| {
                    if (failure) |err| return cb(in.ctx, err);
                    const offset = r.owner.config.root.len + @intFromBool(!path.isRoot(r.owner.config.root));
                    const p = photo(d.path[offset..], d.stat.size, d.stat.modified_ms) catch return cb(in.ctx, error.Io);
                    cb(in.ctx, .{ .photo = p, .new = d.fresh });
                },
                .places, .save => |cb| cb(in.ctx, if (failure) |err| err else d.values),
            }
        }
    };
    pub fn init(gpa: std.mem.Allocator, fs: vfs.Fs, root: []const u8, clock: Clock) !DriveStore {
        return .{
            .config = .{ .gpa = gpa, .fs = fs, .root = try gpa.dupe(u8, root), .clock = clock },
            .cache = .{ .arenas = .{ .init(gpa), .init(gpa) } },
        };
    }
    fn destroy(s: *DriveStore, r: *Request) void {
        if (r.state.job) |job| s.config.fs.cancel(job);
        r.arena.deinit();
        s.config.gpa.destroy(r);
    }
    pub fn deinit(s: *DriveStore) void {
        while (s.queue.head) |r| {
            s.queue.head = r.state.next;
            s.destroy(r);
        }
        while (s.queue.retired) |r| {
            s.queue.retired = r.state.next;
            s.destroy(r);
        }
        for (&s.cache.arenas) |*arena| arena.deinit();
        s.config.gpa.free(s.config.root);
    }
    pub fn store(s: *DriveStore) api.Store {
        return .{
            .ptr = s,
            .vtable = &.{
                .list = list,
                .thumbnail = thumbnail,
                .importFile = importFile,
                .setTags = setTags,
                .setFavorite = setFavorite,
                .places = places,
                .savePlaces = savePlaces,
                .pump = pump,
            },
        };
    }
    fn enqueue(ptr: *anyopaque, cb: Callback, ctx: ?*anyopaque, name: []const u8, bytes: []const u8) *Request {
        const s: *DriveStore = @ptrCast(@alignCast(ptr));
        const r = s.config.gpa.create(Request) catch @panic("DriveStore queue exhausted");
        r.* = .{
            .owner = s,
            .arena = .init(s.config.gpa),
            .input = .{ .cb = cb, .ctx = ctx },
        };
        if (s.queue.tail) |tail| tail.state.next = r else s.queue.head = r;
        s.queue.tail = r;
        r.copy(name, bytes) catch {
            r.input.failure = error.OutOfMemory;
        };
        return r;
    }
    fn list(ptr: *anyopaque, after: ?[]const u8, limit: u32, ctx: ?*anyopaque, cb: api.Done([]const api.Item)) void {
        const r = enqueue(ptr, .{ .list = cb }, ctx, after orelse "", "");
        r.input.after = if (after != null) r.input.name else null;
        r.input.limit = limit;
    }
    fn thumbnail(ptr: *anyopaque, id: []const u8, _: u32, ctx: ?*anyopaque, cb: api.Done(api.Thumbnail)) void {
        _ = enqueue(ptr, .{ .thumbnail = cb }, ctx, id, "");
    }
    fn importFile(ptr: *anyopaque, name: []const u8, bytes: []const u8, ctx: ?*anyopaque, cb: api.Done(api.Imported)) void {
        _ = enqueue(ptr, .{ .import_file = cb }, ctx, name, bytes);
    }
    fn setTags(ptr: *anyopaque, _: []const u8, _: []const model.Tag, _: model.Photo.State, ctx: ?*anyopaque, cb: api.Done(void)) void {
        _ = enqueue(ptr, .{ .unsupported = cb }, ctx, "", "");
    }
    fn setFavorite(ptr: *anyopaque, _: []const u8, _: bool, ctx: ?*anyopaque, cb: api.Done(void)) void {
        _ = enqueue(ptr, .{ .unsupported = cb }, ctx, "", "");
    }
    fn places(ptr: *anyopaque, ctx: ?*anyopaque, cb: api.Done([]const model.Place)) void {
        _ = enqueue(ptr, .{ .places = cb }, ctx, "", "");
    }
    fn savePlaces(ptr: *anyopaque, values: []const model.Place, ctx: ?*anyopaque, cb: api.Done([]const model.Place)) void {
        const r = enqueue(ptr, .{ .save = cb }, ctx, "", "");
        r.save(values) catch {
            r.input.failure = error.Io;
        };
    }
    fn pump(ptr: *anyopaque) void {
        const s: *DriveStore = @ptrCast(@alignCast(ptr));
        while (s.queue.retired) |r| {
            s.queue.retired = r.state.next;
            s.destroy(r);
        }
        s.queue.retired = null;
        s.config.fs.pump();
        while (s.queue.head) |r| {
            if (r.state.job != null) return;
            var failure = r.input.failure;
            const complete = if (failure != null) true else r.step() catch blk: {
                failure = error.Io;
                break :blk true;
            };
            if (!complete) return;
            s.queue.head = r.state.next;
            if (s.queue.head == null) s.queue.tail = null;
            r.state.next = s.queue.retired;
            s.queue.retired = r;
            r.deliver(failure);
        }
    }
    fn photo(id: []const u8, size: u64, ms: i64) !model.Photo {
        if (ms < 0 or ms > 253402300799999 or size > std.math.maxInt(i64)) return error.Io;
        return .{
            .id = id,
            .name = path.basename(id),
            .bytes = size,
            .taken_at = if (ms > 0) @divFloor(ms, 1000) else null,
            .w = 4,
            .h = 3,
            .md5 = .{ .bytes = @splat(0) },
        };
    }
    fn less(_: void, l: api.Item, r: api.Item) bool {
        return if (l.photo.taken_at != r.photo.taken_at) (l.photo.taken_at orelse -1) > (r.photo.taken_at orelse -1) else std.mem.order(u8, l.photo.id, r.photo.id) == .lt;
    }
    fn isImage(name: []const u8) bool {
        for ([_][]const u8{ ".jpg", ".jpeg", ".png", ".heic", ".webp" }) |ext| if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
        return false;
    }
    fn index(items: []const api.Item, id: []const u8) ?usize {
        for (items, 0..) |item, i| if (std.mem.eql(u8, id, item.photo.id)) return i;
        return null;
    }
    fn validPlaces(values: []const model.Place) !void {
        for (values) |p| if (p.name.len > 40 or !std.math.isFinite(p.lat) or @abs(p.lat) > 90 or !std.math.isFinite(p.lon) or @abs(p.lon) > 180 or !std.math.isFinite(p.radius_m) or p.radius_m < 0 or p.radius_m > 20040000) return error.Io;
    }
};
