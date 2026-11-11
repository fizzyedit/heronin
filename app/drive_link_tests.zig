const std = @import("std");
const t = std.testing;
const sdk = @import("fizzy_sdk");
const core = @import("core");
const drive = @import("drive_link.zig");
const api = @import("store.zig");
pub const Stub = struct {
    host: *sdk.Host,
    mem: *core.vfs.Mem,
    facts: bool = false,
    ticket: u32 = 0,
    fail: bool = false,
    mounted: bool = false,
    seen: ?[]u8 = null,
    pub fn deinit(self: *Stub) void {
        if (self.seen) |args| t.allocator.free(args);
    }
    pub fn register(self: *Stub, plugin: *sdk.Plugin) !void {
        plugin.* = .{ .state = self, .vtable = &.{}, .id = "drive", .display_name = "Drive" };
        try self.host.registerPlugin(plugin);
        try self.host.registerCommand(.{ .id = "drive.use_token", .owner = plugin, .title = "Token", .visibility = .internal, .runWith = useToken });
        try self.host.registerCommand(.{ .id = "drive.mount_path", .owner = plugin, .title = "Mount", .visibility = .internal, .runWith = mountPath });
        if (!self.facts) return;
        for ([_][]const u8{ "drive.image_info", "drive.thumbnail", "drive.set_props" }) |id| {
            const run: *const fn (*anyopaque, *sdk.Command.Call) anyerror!void =
                if (std.mem.endsWith(u8, id, "info")) info else meta;
            try self.host.registerCommand(.{
                .id = id,
                .owner = plugin,
                .title = "Meta",
                .visibility = .internal,
                .runWith = run,
            });
        }
    }
    fn info(_: *anyopaque, call: *sdk.Command.Call) !void {
        call.result = ".{ .md5 = \"\", .taken_ms = 0, .lat = null, .lon = null," ++
            " .camera = \"Test Camera\", .w = 800, .h = 600 }";
    }
    fn meta(ptr: *anyopaque, call: *sdk.Command.Call) !void {
        const self: *Stub = @ptrCast(@alignCast(ptr));
        self.ticket = call.later();
    }
    fn useToken(ptr: *anyopaque, call: *sdk.Command.Call) !void {
        const self: *Stub = @ptrCast(@alignCast(ptr));
        if (self.seen) |args| t.allocator.free(args);
        self.seen = try t.allocator.dupe(u8, call.args);
        if (self.fail) {
            self.fail = false;
            call.message = "drive is not ready yet";
            return error.NotReady;
        }
        const args = try sdk.Host.events.parse(struct { access_token: []const u8, expires_in: u32 }, call.arena, .{ .name = "", .payload = call.args });
        self.mounted = args.access_token.len != 0;
        if (self.mounted) try self.host.mount("gdrive://a@example.invalid", self.mem.fs()) else self.host.unmount("gdrive://a@example.invalid");
    }
    fn mountPath(ptr: *anyopaque, call: *sdk.Command.Call) !void {
        const self: *Stub = @ptrCast(@alignCast(ptr));
        call.result = if (self.mounted) ".{ .prefix = \"gdrive://a@example.invalid\" }" else ".{ .prefix = \"\" }";
    }
};
var listed: bool = false;
var width: u32 = 4;
fn list(_: ?*anyopaque, result: api.Error![]const api.Item) void {
    const items = result catch unreachable;
    t.expectEqual(1, items.len) catch unreachable;
    t.expectEqualStrings("photo.jpg", items[0].photo.id) catch unreachable;
    t.expectEqual(width, items[0].photo.w) catch unreachable;
    t.expectEqual(if (width == 4) @as(u32, 3) else 600, items[0].photo.h) catch unreachable;
    listed = true;
}
test "absent drive falls back; command mount lists photos, signs out and retains stores" {
    try mounted(false);
    try mounted(true);
}
fn mounted(facts: bool) !void {
    var host = sdk.Host.init(t.allocator);
    defer host.deinit();
    var files = core.FileTable.init(t.allocator, t.io);
    defer files.deinit();
    host.files = &files;
    var mem = try core.vfs.Mem.init(t.allocator);
    defer mem.deinit();
    try mem.putDir("/Heronin");
    try mem.put("/Heronin/photo.jpg", "image");
    var fake = try @import("fake_store.zig").FakeStore.init(t.allocator);
    defer fake.deinit();
    var link: drive.Link = .{};
    defer link.deinit();
    link.give(&host, "tok-1", 3600);
    try t.expectEqual(.absent, link.state);
    try t.expectEqual(fake.store().ptr, link.current(fake.store()).ptr);
    var stub: Stub = .{ .host = &host, .mem = &mem, .facts = facts };
    width = if (facts) 800 else 4;
    defer stub.deinit();
    var plugin: sdk.Plugin = undefined;
    try stub.register(&plugin);
    stub.fail = true;
    link.give(&host, "tok-1", 3600);
    try t.expect(link.retry);
    inline for (@typeInfo(drive.Link).@"struct".field_names) |field| {
        comptime if (std.mem.indexOf(u8, field, "token") != null and !std.mem.eql(u8, field, "token_due")) @compileError("token field");
    }
    link.give(&host, "tok-1", 3600);
    link.step();
    try t.expectEqual(.mounted, link.state);
    try t.expect(!link.retry and link.changed);
    listed = false;
    const store = link.current(fake.store());
    store.list(null, 60, null, list);
    store.pump();
    store.pump();
    try t.expect(listed);
    const Sink = @import("drive_store_tests.zig").Sink;
    var thumb: Sink(api.Thumbnail) = .{};
    store.thumbnail("photo.jpg", 64, &thumb, @TypeOf(thumb).done);
    if (facts) host.finishCall(stub.ticket, .{ .ok = ".{ .base64 = \"aGk=\" }" });
    try t.expectEqual(0, thumb.calls);
    store.pump();
    try t.expectEqual(1, thumb.calls);
    const tag = std.meta.activeTag(try thumb.result);
    try t.expectEqual(@as(@TypeOf(tag), if (facts) .encoded else .wash), tag);
    var edit: Sink(void) = .{};
    store.setTags("photo.jpg", &.{}, .review, &edit, @TypeOf(edit).done);
    if (facts) host.finishCall(stub.ticket, .{ .ok = null });
    try t.expectEqual(0, edit.calls);
    store.pump();
    if (facts) try edit.result else try t.expectError(error.Unsupported, edit.result);
    link.changed = false;
    link.give(&host, "tok-1", 3600);
    try t.expectEqual(.mounted, link.state);
    try t.expectEqual(store.ptr, link.current(fake.store()).ptr);
    link.step();
    try t.expectEqual(store.ptr, link.current(fake.store()).ptr);
    try t.expectEqual(1, link.retired.items.len);
    try t.expect(!link.changed);
    link.give(&host, "", 0);
    try t.expectEqual(.absent, link.state);
    try t.expectEqual(fake.store().ptr, link.current(fake.store()).ptr);
    try t.expectEqual(1, link.retired.items.len);
    link.give(&host, "tok-1", 3600);
    link.step();
    try t.expectEqual(2, link.retired.items.len);
}
test "drive token event only marks the next frame due" {
    var host = sdk.Host.init(t.allocator);
    defer host.deinit();
    var files = core.FileTable.init(t.allocator, t.io);
    defer files.deinit();
    host.files = &files;
    defer drive.link.deinit();
    var dummy: u8 = 0;
    var owner: sdk.Plugin = .{ .state = &dummy, .vtable = &.{}, .id = "heronin", .display_name = "Heronin" };
    try host.registerPlugin(&owner);
    try drive.register(&host);
    host.emit("drive.token_needed", "");
    try t.expect(!drive.link.token_due);
    host.deliverEvents();
    try t.expect(drive.link.token_due);
}
