const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const theme = @import("theme.zig");
const tabs = @import("views/tabs.zig");
pub const plugin_options = @import("fizzy_plugin_options");
pub const plugin_id = plugin_options.id;
var plugin: sdk.Plugin = .{ .state = undefined, .vtable = &.{ .deinit = deinit }, .id = plugin_id, .display_name = plugin_options.name };
const library = @import("views/library.zig");
const photo = @import("views/photo.zig");
var fake: ?@import("fake_store.zig").FakeStore = null;
var state: library.State = .{};
const add = @import("views/add.zig");
var queue: @import("import_queue.zig").Queue = .{ .allocator = @import("std").heap.page_allocator };
pub var current: tabs.Tab = .library;
pub fn register(host: *sdk.Host) !void {
    plugin.state = @ptrCast(host);
    try host.registerPlugin(&plugin);
    try host.registerSurface(.{ .id = "heronin.library", .owner = &plugin, .title = "Library", .keywords = &.{"heronin"}, .scrolls_itself = true, .draw = draw });
}
fn deinit(_: *anyopaque) void {
    if (fake) |*f| f.deinit();
    fake = null;
    for (queue.rows.items) |row| queue.allocator.free(row.name);
    queue.deinit();
    queue = .{ .allocator = @import("std").heap.page_allocator };
    state.arena.deinit();
    state = .{};
    current = .library;
}
fn draw(_: ?*anyopaque) anyerror!dvui.App.Result {
    if (fake == null) {
        fake = try @import("fake_store.zig").FakeStore.init(@import("std").heap.page_allocator);
        fake.?.store().list(null, 60, &state, library.State.listed);
        fake.?.store().places(&state, library.State.placed);
    }
    add.pick(&queue);
    const importing = queue.busy;
    fake.?.store().pump();
    if (importing and !queue.busy and queue.rows.items[queue.active].state == .imported) {
        state.stale = true;
        dvui.refresh(null, @src(), null);
        fake.?.store().list(null, 60, &state, library.State.listed);
    }
    if (current == .library and state.open == null and state.stale) state.reload(fake.?.store());
    if (!state.requested and state.items.len > 0) {
        for (state.items, 0..) |item, i| fake.?.store().thumbnail(item.photo.id, 600, &state.washes[i], library.State.thumbnail);
        state.requested = true;
        dvui.refresh(null, @src(), null);
    }
    dvui.themeSet(theme.light(dvui.themeGet()));
    var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .color_fill = .{ .color = theme.paper }, .padding = .all(16) });
    defer page.deinit();
    {
        var content = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer content.deinit();
        if (current == .library) {
            if (state.open != null) photo.draw(&state, fake.?.store()) else library.draw(&state);
        } else if (current == .add) add.draw(&queue, &state, fake.?.store()) else dvui.labelNoFmt(@src(), current.title(), .{}, .{ .font = dvui.Font.theme(.title), .color_text = .{ .color = theme.red[0] } });
    }
    tabs.draw(&current);
    return .ok;
}
