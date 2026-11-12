const session = @import("app_session.zig");
const drive_link = @import("drive_link.zig");
const sign_in = @import("sign_in.zig");
var places_base: ?[]const u8 = if (@import("builtin").cpu.arch == .wasm32) "" else null;
const build = @import("heronin_build");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const root = @import("views/root.zig");
const agent = @import("views/agent.zig");
var settings: @import("tag_queue.zig").Settings = .{};
var tagging: @import("tag_queue.zig").TagQueue = .{ .settings = &settings };
const tabs = @import("views/tabs.zig");
pub const plugin_options = @import("fizzy_plugin_options");
pub const plugin_id = plugin_options.id;
var plugin: sdk.Plugin = .{ .state = undefined, .vtable = &.{ .deinit = deinit }, .id = plugin_id, .display_name = plugin_options.name };
const library = @import("views/library.zig");
var fake: ?@import("fake_store.zig").FakeStore = null;
var state: library.State = .{};
const add = @import("views/add.zig");
var queue: @import("import_queue.zig").Queue = undefined;
var imported: usize = 0;
var current: tabs.Tab = .library;
pub fn register(host: *sdk.Host) !void {
    queue = .{ .allocator = host.allocator };
    if (@import("builtin").cpu.arch == .wasm32) {
        agent.url = "/heronin/api/tag";
    } else {
        const env = @import("core").platform.processEnviron().getAlloc(tagging.owned.allocator(), "HERONIN_TAG_URL") catch null;
        places_base = env orelse if (build.server_url.len != 0) build.server_url else null;
        agent.url = try @import("tag_queue.zig").serverUrl(
            tagging.owned.allocator(),
            places_base,
            "tag",
        );
    }
    plugin.state = @ptrCast(host);
    try host.registerPlugin(&plugin);
    try drive_link.register(host);
    try host.registerSurface(.{ .id = "heronin.library", .owner = &plugin, .title = "Library", .keywords = &.{"heronin"}, .scrolls_itself = true, .draw = draw });
}
fn deinit(_: *anyopaque) void {
    library.places_client.names.deinit();
    sign_in.account.deinit();
    if (fake != null) @import("agent_settings.zig").deinit();
    if (fake != null) agent.deinit();
    tagging.deinit();
    drive_link.link.deinit();
    if (fake) |*f| f.deinit();
    fake = null;
    for (queue.rows.items) |row| queue.allocator.free(row.name);
    queue.deinit();
    queue = .{ .allocator = queue.allocator };
    imported = 0;
    state.arena.deinit();
    state = .{};
    current = .library;
}
fn draw(_: ?*anyopaque) anyerror!dvui.App.Result {
    const host: *sdk.Host = @ptrCast(@alignCast(plugin.state));
    if (fake == null) {
        agent.init();
        if (@import("builtin").cpu.arch != .wasm32)
            session.cookie.value = session.hex(host.getSecret("heronin.session") orelse "");
        if (places_base) |base| sign_in.check(agent.transport, base);
        @import("agent_settings.zig").load(agent.transport, places_base);
        state.tag_queue = &tagging;
        fake = try @import("fake_store.zig").FakeStore.init(@import("std").heap.page_allocator);
        drive_link.link.current(fake.?.store()).list(null, 60, &state, library.State.listed);
        drive_link.link.current(fake.?.store()).places(&state, library.State.placed);
    }
    sign_in.step();
    if (@import("builtin").cpu.arch != .wasm32 and sign_in.account.state == .opening and
        dvui.timerDoneOrNone(dvui.parentGet().data().id))
        dvui.timer(dvui.parentGet().data().id, 2000000);
    drive_link.link.step();
    if (drive_link.link.changed) {
        drive_link.link.changed = false;
        state.stale = true;
        drive_link.link.current(fake.?.store()).list(null, 60, &state, library.State.listed);
        drive_link.link.current(fake.?.store()).places(&state, library.State.placed);
    }
    add.pick(&queue);
    if (current != .add) queue.step(drive_link.link.current(fake.?.store()));
    if (queue.busy) dvui.refresh(null, @src(), null);
    agent.transport.pump();
    if (sign_in.session_changed) {
        const saved = host.setSecret("heronin.session", if (session.cookie.value) |*v| v else "");
        saved catch @import("std").log.err("session not saved", .{});
        sign_in.session_changed = false;
    }
    if (@import("builtin").cpu.arch == .wasm32) @import("core").transport.WebOAuth.pump();
    if (drive_link.link.state == .waiting or drive_link.link.retry) dvui.refresh(null, @src(), null);
    if (sign_in.account.state == .checking) dvui.refresh(null, @src(), null);
    drive_link.link.current(fake.?.store()).pump();
    var finished: usize = 0;
    for (queue.rows.items) |row| {
        if (row.state == .imported) finished += 1;
    }
    if (finished != imported) {
        imported = finished;
        state.stale = true;
        dvui.refresh(null, @src(), null);
    }
    const reloaded = state.reloadBetweenJobs(drive_link.link.current(fake.?.store()), tagging.busy != null, current == .library or current == .species);
    tagging.tags_allocator = state.arena.allocator();
    tagging.items = state.items;
    tagging.photos = state.photos;
    if (sign_in.ready() and !reloaded) {
        tagging.step(drive_link.link.current(fake.?.store()), agent.post);
    }
    if (sign_in.ready()) library.places_client.step(&library.places_client.names, state.photos, state.places, agent.transport, places_base);
    if (library.places_client.names.busy) dvui.refresh(null, @src(), null);
    if (tagging.busy != null) dvui.refresh(null, @src(), null);
    if (!state.requested and state.items.len > 0) {
        for (state.items, 0..) |item, i| {
            if (i >= state.thumbs.len) break;
            const thumb = &state.thumbs[i];
            thumb.owner = &state;
            drive_link.link.current(fake.?.store()).thumbnail(
                item.photo.id,
                600,
                thumb,
                library.State.thumbnail,
            );
        }
        state.requested = true;
        dvui.refresh(null, @src(), null);
    }
    if (current == .agent) agent.page(&current, &settings) else root.draw(&current, &state, &queue, drive_link.link.current(fake.?.store()));
    return .ok;
}
