const std = @import("std");
const sdk = @import("fizzy_sdk");
const Store = @import("store.zig").Store;
const DriveStore = @import("drive_store.zig").DriveStore;
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
        var args: std.Io.Writer.Allocating = .init(a);
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
                self.state = .waiting;
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
        s.* = DriveStore.init(host.allocator, resolved.fs, resolved.rel, @import("views/library.zig").now) catch {
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
