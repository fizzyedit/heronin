const std = @import("std");
const sdk = @import("fizzy_sdk");
const Store = @import("store.zig").Store;
const ds = @import("drive_store.zig");
const DriveStore = ds.DriveStore;
pub var link: Link = .{};
pub const Link = struct {
    host: ?*sdk.Host = null,
    state: enum { absent, waiting, mounted } = .absent,
    store: ?*DriveStore = null,
    retired: std.ArrayList(*DriveStore) = .empty,
    retry: bool = false,
    token_due: bool = false,
    changed: bool = false,
    /// Keep current and retired stores until app shutdown: Fs callbacks may still
    /// reference their ops after unmount. Never destroy a store during a swap.
    pub fn deinit(self: *Link) void {
        const a = (self.host orelse return).allocator;
        for (self.retired.items) |s| {
            s.deinit();
            a.destroy(s);
        }
        self.retired.deinit(a);
        self.* = .{};
    }
    pub fn give(self: *Link, host: *sdk.Host, token: []const u8, expires_in: u32) void {
        self.host = host;
        const a = host.allocator;
        const capacity = std.math.add(usize, std.math.mul(usize, token.len, 6) catch return, 64) catch return;
        var args = std.Io.Writer.Allocating.initCapacity(a, capacity) catch return;
        defer args.deinit();
        defer std.crypto.secureZero(u8, args.written());
        std.zon.stringify.serialize(.{ .access_token = token, .expires_in = expires_in }, .{}, &args.writer) catch return;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        self.retry = false;
        switch (host.callCommand("drive.use_token", args.written(), arena.allocator())) {
            .unknown => self.drop(),
            .failed => |message| self.retry = std.mem.eql(u8, message, "drive is not ready yet"),
            .ok => if (token.len == 0) self.drop() else {
                if (self.state != .mounted) self.state = .waiting;
            },
            else => {},
        }
    }
    fn drop(self: *Link) void {
        self.changed = self.changed or self.store != null;
        self.store = null;
        self.state = .absent;
    }
    pub fn step(self: *Link) void {
        if (self.state != .waiting) return;
        const host = self.host orelse return;
        const files = host.files orelse return self.drop();
        var arena = std.heap.ArenaAllocator.init(host.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const result = switch (host.callCommand("drive.mount_path", "", a)) {
            .ok => |value| value orelse return,
            else => return,
        };
        const source = a.dupeSentinel(u8, result, 0) catch return;
        var diagnostics: std.zon.parse.Diagnostics = undefined;
        const mounted = std.zon.parse.fromSlice(struct { prefix: []const u8 }, .{ .gpa = a, .arena = a, .source = source, .diagnostics = &diagnostics }) catch return;
        if (mounted.prefix.len == 0) return;
        const path = std.mem.concat(a, u8, &.{ mounted.prefix, "/Heronin" }) catch return;
        const resolved = files.resolve(path);
        const s = host.allocator.create(DriveStore) catch return;
        const now = @import("views/library.zig").now;
        s.* = DriveStore.init(host.allocator, resolved.fs, resolved.rel, now, self.meta()) catch {
            host.allocator.destroy(s);
            return;
        };
        self.retired.append(host.allocator, s) catch {
            s.deinit();
            host.allocator.destroy(s);
            return;
        };
        self.store = s;
        self.state = .mounted;
        self.changed = true;
    }
    fn meta(self: *Link) ds.Meta {
        return .{ .ctx = self.host.?, .info = info, .thumbnail = thumbnail, .setProps = setProps };
    }
    fn info(ctx: *anyopaque, a: std.mem.Allocator, path: []const u8) ?ds.Info {
        const host: *sdk.Host = @ptrCast(@alignCast(ctx));
        var args: std.Io.Writer.Allocating = .init(a);
        std.zon.stringify.serialize(.{ .path = path }, .{}, &args.writer) catch return null;
        const text = switch (host.callCommand("drive.image_info", args.written(), a)) {
            .ok => |text| text orelse return null,
            else => return null,
        };
        const Wire = struct {
            md5: []const u8,
            taken_ms: i64,
            lat: ?f64,
            lon: ?f64,
            camera: []const u8,
            w: u32,
            h: u32,
            props: []const u8 = "{}",
        };
        const wire = sdk.Host.events.parse(Wire, a, .{ .name = "", .payload = text }) catch
            return null;
        var out: ds.Info = .{
            .taken_ms = wire.taken_ms,
            .lat = wire.lat,
            .lon = wire.lon,
            .camera = wire.camera,
            .w = wire.w,
            .h = wire.h,
            .props = wire.props,
        };
        if (wire.md5.len != 0) _ = std.fmt.hexToBytes(&out.md5, wire.md5) catch return null;
        return out;
    }
    fn thumbnail(ctx: *anyopaque, path: []const u8, px: u32, done: *ds.Pending) void {
        request(ctx, "drive.thumbnail", .{ .path = path, .px = px }, done);
    }
    fn setProps(ctx: *anyopaque, path: []const u8, props: []const u8, done: *ds.Pending) void {
        request(ctx, "drive.set_props", .{ .path = path, .props = props }, done);
    }
    fn finish(ctx: *anyopaque, outcome: sdk.Host.CommandOutcome) void {
        const p: *ds.Pending = @ptrCast(@alignCast(ctx));
        var arena = p.arena;
        defer arena.deinit();
        const a = arena.allocator();
        if (outcome == .unknown) return p.unsupported();
        const text = switch (outcome) {
            .ok => |text| text,
            else => return p.answer(null),
        };
        if (p.done == .props) return p.answer("");
        const payload = text orelse return p.answer(null);
        const event: sdk.Host.events.Event = .{ .name = "", .payload = payload };
        const wire = sdk.Host.events.parse(struct { base64: []const u8 }, a, event) catch
            return p.answer(null);
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(wire.base64) catch return p.answer(null);
        const bytes = a.alloc(u8, size) catch @panic("OOM");
        decoder.decode(bytes, wire.base64) catch return p.answer(null);
        p.answer(bytes);
    }
    fn request(ctx: *anyopaque, id: []const u8, values: anytype, done: *ds.Pending) void {
        const host: *sdk.Host = @ptrCast(@alignCast(ctx));
        done.arena = .init(host.allocator);
        const a = done.arena.allocator();
        var args: std.Io.Writer.Allocating = .init(a);
        std.zon.stringify.serialize(values, .{}, &args.writer) catch @panic("OOM");
        const sink: sdk.Host.CallSink = .{
            .ctx = done,
            .done = finish,
            .owner = host.pluginById("heronin"),
        };
        switch (host.callCommandAwaiting(id, args.written(), a, sink)) {
            .now => |outcome| finish(done, outcome),
            .later => {},
        }
    }
    pub fn current(self: *Link, fake: Store) Store {
        return if (self.state == .mounted) self.store.?.store() else fake;
    }
};
pub fn register(host: *sdk.Host) !void {
    link.host = host;
    try host.subscribe(.{ .event = "drive.token_needed", .owner = host.pluginById("heronin"), .handler = needed });
}
fn needed(_: *anyopaque, _: sdk.Host.events.Event) void {
    link.token_due = true;
}
