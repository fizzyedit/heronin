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
    agent.url = if (@import("builtin").cpu.arch == .wasm32) "/heronin/api/tag" else try @import("tag_queue.zig").endpoint(tagging.owned.allocator(), @import("core").platform.processEnviron().getAlloc(tagging.owned.allocator(), "HERONIN_TAG_URL") catch null);
    plugin.state = @ptrCast(host);
    try host.registerPlugin(&plugin);
    try host.registerSurface(.{ .id = "heronin.library", .owner = &plugin, .title = "Library", .keywords = &.{"heronin"}, .scrolls_itself = true, .draw = draw });
}
fn deinit(_: *anyopaque) void {
    if (fake != null) agent.deinit();
    tagging.deinit();
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
    if (fake == null) {
        agent.init();
        state.tag_queue = &tagging;
        fake = try @import("fake_store.zig").FakeStore.init(@import("std").heap.page_allocator);
        fake.?.store().list(null, 60, &state, library.State.listed);
        fake.?.store().places(&state, library.State.placed);
    }
    add.pick(&queue);
    if (current != .add) queue.step(fake.?.store());
    if (queue.busy) dvui.refresh(null, @src(), null);
    agent.transport.pump();
    fake.?.store().pump();
    var finished: usize = 0;
    for (queue.rows.items) |row| {
        if (row.state == .imported) finished += 1;
    }
    if (finished != imported) {
        imported = finished;
        state.stale = true;
        dvui.refresh(null, @src(), null);
    }
    const reloaded = state.reloadBetweenJobs(fake.?.store(), tagging.busy != null, current == .library or current == .species);
    tagging.tags_allocator = state.arena.allocator();
    tagging.items = state.items;
    tagging.photos = state.photos;
    if (!reloaded) tagging.step(fake.?.store(), agent.post);
    if (tagging.busy != null) dvui.refresh(null, @src(), null);
    if (!state.requested and state.items.len > 0) {
        for (state.items, 0..) |item, i| fake.?.store().thumbnail(item.photo.id, 600, &state.washes[i], library.State.thumbnail);
        state.requested = true;
        dvui.refresh(null, @src(), null);
    }
    if (current == .agent) agent.page(&current, &settings) else root.draw(&current, &state, &queue, fake.?.store());
    return .ok;
}
