const sign_in = @import("../sign_in.zig");
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const theme = @import("../theme.zig");
const lib = @import("library.zig");
const tags = @import("../tag_queue.zig");
const yours = @import("../agent_settings.zig");
// Keep this displayed value aligned with server/decide.zig default_threshold.
pub const auto_accept_shown = 85;
pub fn draw(settings: *tags.Settings) void {
    lib.label(@src(), "Agent", .{ .font = dvui.Font.theme(.title) });
    lib.label(@src(), "Who looks at your photos and names the bird.", .{});
    if (sign_in.account.state == .signed_in or sign_in.account.state == .signed_out or sign_in.account.state == .opening) {
        const account = section(0, "ACCOUNT");
        defer account.deinit();
        if (sign_in.account.state == .signed_in) {
            lib.label(@src(), sign_in.account.email orelse "Signed in", .{ .font = dvui.Font.theme(.body).withWeight(.bold) });
            lib.label(@src(), "Signed in with Google", .{});
            divider(1);
            if (dvui.button(@src(), "Sign out", .{}, .{ .border = .all(1), .color_border = .{ .color = theme.brown[0] }, .tag = "heronin-sign-out", .min_size_content = .{ .h = 44 } })) sign_in.signOut();
            if (sign_in.account.failed == .sign_out) lib.label(@src(), "Could not sign out", .{});
        } else sign_in.button(1);
    }
    const choices = section(1, "WHO NAMES THE BIRD");
    inline for (.{ "Our agent", "Your own agent", "Both, compare" }, .{ "Default", "Connect", "Extra check" }, .{ "Comes with Heronin. Tuned for birds and the species list.", "Your agent names the birds; Heronin keeps the photos and list.", "Both look; when they disagree the photo goes to Needs review." }, 0..) |name, hint, meta, i| {
        const off = i > 0 and !yours.state.connected;
        const chosen = @backingInt(settings.agent) == i;
        divider(i);
        var row: dvui.ButtonWidget = undefined;
        row.init(@src(), .{ .draw_focus = !off, .grayed = off }, .{ .id_extra = i, .tag = lib.fmt("heronin-agent-{d}", .{i}), .expand = .horizontal, .min_size_content = .{ .h = 44 }, .border = .all(if (chosen) 3 else 0), .color_border = .{ .color = theme.orange[0] }, .color_fill = .{ .color = theme.card }, .color_text = .{ .color = if (off) theme.tab_off_ink else theme.ink } });
        defer row.deinit();
        row.processEvents();
        row.drawBackground();
        const text = dvui.box(@src(), .{}, .{ .id_extra = i, .expand = .horizontal });
        const line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i });
        const circle = dvui.box(@src(), .{}, .{ .id_extra = i, .tag = lib.fmt("heronin-radio-{d}", .{i}), .min_size_content = .{ .w = 16, .h = 16 }, .corners = .all(8), .border = .all(2), .background = true, .color_border = .{ .color = theme.brown[0] }, .color_fill = .{ .color = if (chosen) theme.orange[0] else theme.card } });
        circle.deinit();
        dvui.labelNoFmt(@src(), name, .{}, .{ .id_extra = i });
        dvui.labelNoFmt(@src(), hint, .{}, .{ .id_extra = i, .background = true, .color_fill = .{ .color = theme.chip }, .corners = .all(6) });
        line.deinit();
        lib.label(@src(), meta, .{ .id_extra = i, .font = dvui.Font.theme(.body).withSize(theme.size.small) });
        text.deinit();
        if (row.clicked() and !off) settings.agent = @fromBackingInt(@intCast(i));
    }
    choices.deinit();
    const connect = section(2, "CONNECT YOUR OWN AGENT");
    const s = &yours.state;
    entry(0, "heronin-connect-address", &s.address, "Address", null);
    entry(1, "heronin-connect-key", &s.key, if (s.has_key) "Key saved" else "Key (kept on your Heronin server)", "*");
    toggle(3, "Model endpoint (Messages API)", &s.wrap);
    if (s.wrap) entry(2, "heronin-connect-model", &s.model, "Model", null);
    divider(4);
    if (dvui.button(@src(), "Save", .{}, field.override(.{ .tag = "heronin-connect-save" }))) yours.save();
    if (s.saved != .unknown) lib.label(@src(), if (s.saved == .saved) "Saved" else "Could not save", .{});
    connect.deinit();
    const behavior = section(3, "HOW IT BEHAVES");
    defer behavior.deinit();
    toggle(0, "Send previews to the tagging agent", &settings.auto);
    toggle(1, lib.fmt("Ask me below {d} percent", .{auto_accept_shown}), &settings.ask_below);
    toggle(2, "Use location to narrow guesses", &settings.use_place);
    lib.label(@src(), "Place names: GeoNames (CC BY 4.0), looked up on your Heronin server", .{ .id_extra = 0 });
    lib.label(@src(), "Only the place is sent, never the photo's location data", .{});
}
const field: dvui.Options = .{ .min_size_content = .{ .w = 300, .h = 44 }, .background = true, .color_fill = .{ .color = theme.chip }, .color_text = .{ .color = theme.ink } };
fn entry(id: usize, tag: []const u8, buffer: []u8, placeholder: []const u8, password: ?[]const u8) void {
    divider(id);
    dvui.textEntry(@src(), .{ .text = .{ .buffer = buffer[0..buffer.len -| 1] }, .placeholder = placeholder, .password_char = password }, field.override(.{ .id_extra = id, .tag = tag })).deinit();
}
fn section(id: usize, heading: []const u8) *dvui.BoxWidget {
    lib.label(@src(), heading, .{ .id_extra = id, .tag = lib.fmt("heronin-heading-{d}", .{id}), .font = dvui.Font.theme(.body).withSize(theme.size.small).withWeight(.bold), .color_text = .{ .color = theme.brown[0] } });
    return dvui.box(@src(), .{}, .{ .id_extra = id, .tag = lib.fmt("heronin-card-{d}", .{id}), .expand = .horizontal, .background = true, .color_fill = .{ .color = theme.card }, .border = .all(1), .color_border = .{ .color = theme.border }, .corners = .all(14), .padding = .all(8) });
}
fn divider(id: usize) void {
    if (id != 0) _ = dvui.separator(@src(), .{ .id_extra = id, .expand = .horizontal, .min_size_content = .{ .h = 1 }, .color_fill = .{ .color = theme.chip } });
}
fn toggle(id: usize, text: []const u8, value: *bool) void {
    divider(id);
    var row: dvui.ButtonWidget = undefined;
    row.init(@src(), .{}, .{ .id_extra = id, .tag = lib.fmt("heronin-switch-{d}", .{id}), .expand = .horizontal, .min_size_content = .{ .h = 44 }, .color_fill = .{ .color = theme.card } });
    defer row.deinit();
    row.processEvents();
    row.drawBackground();
    const line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    const track = dvui.box(@src(), .{}, .{ .tag = lib.fmt("heronin-track-{d}", .{id}), .min_size_content = .{ .w = if (value.*) 46 else 42, .h = if (value.*) 28 else 24 }, .max_size_content = .{ .w = if (value.*) 46 else 42, .h = if (value.*) 28 else 24 }, .corners = .all(14), .background = true, .border = .all(if (value.*) 0 else 2), .color_border = .{ .color = theme.brown[2] }, .color_fill = .{ .color = if (value.*) theme.olive[0] else theme.chip } });
    const knob = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 18, .h = 18 }, .gravity_x = if (value.*) 1 else 0, .gravity_y = 0.5, .corners = .all(9), .background = true, .color_fill = .{ .color = theme.card } });
    knob.deinit();
    track.deinit();
    const words = dvui.box(@src(), .{}, .{ .expand = .horizontal });
    lib.label(@src(), text, .{});
    const subtitle: ?[]const u8 = switch (id) {
        0 => "A small preview, never the original",
        1 => "Less sure photos go to Needs review",
        2 => "Only the place, never the photo's location data",
        else => null,
    };
    if (subtitle) |sub| lib.label(@src(), sub, .{ .font = dvui.Font.theme(.body).withSize(theme.size.small) });
    words.deinit();
    line.deinit();
    if (row.clicked()) value.* = !value.*;
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
        const session = @import("../app_session.zig");
        session.cookie = .{ .inner = native.transport() };
        transport = session.cookie.transport();
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
