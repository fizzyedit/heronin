const dvui = @import("dvui");
const theme = @import("../theme.zig");
const tabs = @import("tabs.zig");
const library = @import("library.zig");
const species = @import("species.zig");
const photo = @import("photo.zig");
const add = @import("add.zig");
const imports = @import("../import_queue.zig");
const api = @import("../store.zig");
pub fn draw(current: *tabs.Tab, state: *library.State, queue: *imports.Queue, store: api.Store) void {
    dvui.themeSet(theme.light(dvui.themeGet()));
    var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .color_fill = .{ .color = theme.paper }, .padding = .all(16) });
    defer page.deinit();
    // Scroll areas report their full content height as their minimum size.
    // Reserve the bottom bar first so expanding content cannot take its space.
    tabs.draw(current);
    var content = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer content.deinit();
    @import("../sign_in.zig").banner();
    switch (current.*) {
        .library => if (state.open != null) photo.draw(state, store) else library.draw(state),
        .species => species.draw(state, library.now(), store, current),
        .map => @import("map.zig").draw(state, current),
        .add => add.draw(queue, state, store, current),
        else => dvui.labelNoFmt(@src(), current.title(), .{}, .{ .font = dvui.Font.theme(.title), .color_text = .{ .color = theme.red[0] } }),
    }
}
