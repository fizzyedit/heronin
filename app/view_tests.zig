const std = @import("std");
const dvui = @import("dvui");
const root = @import("views/root.zig");
const library = @import("views/library.zig");
const imports = @import("import_queue.zig");
var fake: @import("fake_store.zig").FakeStore = undefined;
var state: library.State = .{};
var queue: imports.Queue = undefined;
var current: @import("views/tabs.zig").Tab = .library;
fn frame() !dvui.App.Result {
    root.draw(&current, &state, &queue, fake.store());
    return .ok;
}
test "tabs stay visible in library, photo and add without duplicate widget ids" {
    var testing = try dvui.testing.init(.{ .window_size = .{ .w = 390, .h = 844 } });
    defer testing.deinit();
    fake = try .init(std.testing.allocator);
    defer fake.deinit();
    state = .{};
    defer state.arena.deinit();
    queue = .{ .allocator = std.testing.allocator };
    defer queue.deinit();
    current = .library;
    fake.store().list(null, 60, &state, library.State.listed);
    fake.store().places(&state, library.State.placed);
    fake.store().pump();
    try dvui.testing.settle(frame);
    try dvui.testing.expectVisible("heronin-tabs");
    for (state.items) |item| {
        if (item.tags.len >= 2) {
            state.open = item.photo.id;
            break;
        }
    }
    try std.testing.expect(state.open != null);
    try dvui.testing.settle(frame);
    try dvui.testing.expectVisible("heronin-tabs");
    try queue.add(&.{ "a.jpg", "b.jpg" }, &.{ try queue.allocator.dupe(u8, "a"), try queue.allocator.dupe(u8, "b") });
    while (queue.busy or for (queue.rows.items) |row| {
        if (row.state == .queued) break true;
    } else false) {
        queue.step(fake.store());
        fake.store().pump();
    }
    current = .add;
    try dvui.testing.settle(frame);
    try dvui.testing.expectVisible("heronin-tabs");
}
