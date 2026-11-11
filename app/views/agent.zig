const sign_in = @import("../sign_in.zig");
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const theme = @import("../theme.zig");
const lib = @import("library.zig");
const tags = @import("../tag_queue.zig");
// Keep this displayed value aligned with server/decide.zig default_threshold.
pub const auto_accept_shown = 85;
pub fn draw(settings: *tags.Settings) void {
    if (sign_in.account.state == .signed_in or sign_in.account.state == .signed_out or sign_in.account.state == .opening) {
        lib.label(@src(), "Account", .{});
        if (sign_in.account.state == .signed_in) {
            lib.label(@src(), if (sign_in.account.email) |email| lib.fmt("Signed in as {s}", .{email}) else "Signed in", .{});
            if (dvui.button(@src(), "Sign out", .{}, .{ .tag = "heronin-sign-out", .min_size_content = .{ .h = 44 } })) sign_in.signOut();
            if (sign_in.account.failed == .sign_out) lib.label(@src(), "Could not sign out", .{});
        } else sign_in.button(1);
    }
    lib.label(@src(), "Tagging agent", .{ .font = dvui.Font.theme(.title) });
    lib.label(@src(), "Who looks at your photos and names the bird.", .{});
    inline for (.{ "Our agent", "Your own agent", "Both, compare" }, .{ "Default", "Connect", "Extra check" }, 0..) |name, hint, i| {
        const chosen = @backingInt(settings.agent) == i;
        const opts: dvui.Options = .{ .id_extra = i, .min_size_content = .{ .h = 44 }, .border = .all(if (chosen) 3 else 0), .color_border = .{ .color = theme.orange[0] }, .color_fill = .{ .color = theme.washes[0] }, .color_text = .{ .color = if (i == 0) theme.ink else theme.tab_off_ink } };
        if (i == 0) {
            _ = dvui.button(@src(), name ++ " · " ++ hint, .{}, opts);
        } else dvui.labelNoFmt(@src(), name ++ " · " ++ hint, .{}, opts.override(.{ .background = true, .color_text = .{ .color = theme.tab_off_ink } }));
    }
    lib.label(@src(), "Connect", .{});
    inline for (.{ "Address", "Key (kept on your Heronin server)", "Test with one photo" }, 0..) |text, i| dvui.labelNoFmt(@src(), text, .{}, .{ .id_extra = i, .tag = lib.fmt("heronin-connect-{d}", .{i}), .min_size_content = .{ .h = 44 }, .color_text = .{ .color = theme.tab_off_ink }, .background = true, .color_fill = .{ .color = theme.chip } });
    toggle(0, "Send previews to the tagging agent", &settings.auto);
    toggle(1, lib.fmt("Ask me below {d} percent", .{auto_accept_shown}), &settings.ask_below);
    toggle(2, "Use location to narrow guesses", &settings.use_place);
    lib.label(@src(), "Place names: GeoNames (CC BY 4.0), looked up on your Heronin server", .{ .id_extra = 0 });
    lib.label(@src(), "Only the place is sent, never the photo's location data", .{});
}
fn toggle(id: usize, text: []const u8, value: *bool) void {
    if (dvui.button(@src(), text, .{}, .{ .id_extra = id, .min_size_content = .{ .h = 44 }, .color_fill = .{ .color = if (value.*) theme.olive[0] else theme.chip }, .color_text = .{ .color = if (value.*) theme.card else theme.ink } })) value.* = !value.*;
}
const web = @import("builtin").cpu.arch == .wasm32;
var native: if (web) void else core.transport.Native = undefined;
pub var transport: core.vfs.http.Transport = undefined;
pub var url: []const u8 = undefined;
var job: ?core.vfs.http.Job = null;
pub fn init() void {
    if (web) {
        transport = core.transport.Web.transport(std.heap.page_allocator);
    } else {
        native = .init(std.heap.page_allocator, dvui.io, null);
        transport = native.transport();
    }
}
pub fn deinit() void {
    if (job) |pending| transport.cancel(pending);
    job = null;
    if (!web) native.deinit();
}
pub fn post(q: *tags.TagQueue, request: tags.wire.Request) void {
    const body = std.json.Stringify.valueAlloc(q.arena.allocator(), request, .{}) catch return q.answer(error.OutOfMemory);
    job = transport.request(q.arena.allocator(), .{ .method = .POST, .url = url, .body = body, .headers = &.{.{ .name = "Content-Type", .value = "application/json" }} }, received, q) catch return q.answer(error.Io);
}
fn received(ctx: ?*anyopaque, result: core.vfs.Error!core.vfs.http.Response) void {
    job = null;
    const q: *tags.TagQueue = @ptrCast(@alignCast(ctx.?));
    const response = result catch return q.answer(error.Io);
    if (response.status == 401) sign_in.lost();
    const parsed = if (response.status == 200) std.json.parseFromSlice(tags.wire.Response, q.arena.allocator(), response.body, .{ .allocate = .alloc_always }) else error.Io;
    response.deinit(q.arena.allocator());
    const answer = parsed catch return q.answer(error.Io);
    q.answer(answer.value);
}
pub fn page(current: *@import("tabs.zig").Tab, settings: *tags.Settings) void {
    dvui.themeSet(theme.light(dvui.themeGet()));
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .color_fill = .{ .color = theme.paper }, .padding = .all(16) });
    defer box.deinit();
    @import("tabs.zig").draw(current);
    var scroll = core.widgets.ScrollArea.init(@src(), .{ .horizontal = .none }, .{ .expand = .both });
    defer scroll.deinit();
    draw(settings);
}
test "Agent tab keeps tabs visible without duplicate widget ids" {
    var testing = try dvui.testing.init(.{ .window_size = .{ .w = 390, .h = 844 } });
    defer testing.deinit();
    try dvui.testing.settle(struct {
        fn frame() !dvui.App.Result {
            var current: @import("tabs.zig").Tab = .agent;
            var settings: tags.Settings = .{};
            page(&current, &settings);
            return .ok;
        }
    }.frame);
    try dvui.testing.expectVisible("heronin-tabs");
}
