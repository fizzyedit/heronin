const dvui = @import("dvui");
const mercator = @import("model").mercator;
const tiles = @import("../map_tiles.zig");
const lib = @import("library.zig");
const places = @import("places.zig");
const theme = @import("../theme.zig");
const View = struct {
    z: u5 = 3,
    framed: bool = false,
    scroll: dvui.ScrollInfo = .{ .horizontal = .given, .vertical = .given, .viewport = .{ .x = 1024, .y = 1024 } },
};
pub var view: View = .{};
fn center(x: f64, y: f64) void {
    const s = &view.scroll;
    const size: f32 = @floatFromInt(@as(u64, 256) << view.z);
    s.virtual_size = .{ .w = size, .h = size };
    s.viewport.x = @floatCast(@max(0, @min(size - s.viewport.w, x - s.viewport.w / 2)));
    s.viewport.y = @floatCast(@max(0, @min(size - s.viewport.h, y - s.viewport.h / 2)));
}
pub fn draw(state: *lib.State, current: *@import("tabs.zig").Tab) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
    inline for (.{ "−", "+" }, 0..) |text, i| {
        if (dvui.button(@src(), text, .{}, .{ .id_extra = i, .tag = if (i == 0) "heronin-map-zoom-out" else "heronin-map-zoom-in", .min_size_content = .{ .w = 44, .h = 44 }, .padding = .all(0) })) {
            const old = view.z;
            view.z = if (i == 0) @max(mercator.min_zoom, view.z -| 1) else @min(mercator.max_zoom, view.z +| 1);
            const factor: f64 = if (view.z > old) 2 else if (view.z < old) 0.5 else 1;
            center((view.scroll.viewport.x + view.scroll.viewport.w / 2) * factor, (view.scroll.viewport.y + view.scroll.viewport.h / 2) * factor);
        }
    }
    row.deinit();
    dvui.labelNoFmt(@src(), "© OpenStreetMap contributors", .{}, .{ .tag = "heronin-map-attribution", .gravity_y = 1, .font = dvui.Font.theme(.body).withSize(theme.size.meta), .color_text = .{ .color = theme.tab_off_ink } });
    const clusters = places.groups(state).clusters;
    const world = mercator.worldPx(view.z, 0, 0);
    center(if (view.framed) view.scroll.viewport.x + view.scroll.viewport.w / 2 else world.x, if (view.framed) view.scroll.viewport.y + view.scroll.viewport.h / 2 else world.y);
    var area = dvui.scrollArea(@src(), .{ .scroll_info = &view.scroll, .horizontal_bar = .hide, .vertical_bar = .hide }, .{ .tag = "heronin-map", .expand = .both, .color_fill = .{ .color = theme.washes[2] } });
    defer area.deinit();
    const v = view.scroll.viewport;
    if (!view.framed and clusters.len > 0 and v.w > 0 and v.h > 0) {
        const fit = mercator.fit(clusters, v.w, v.h, 32);
        view.z = fit.z;
        center(fit.center.x, fit.center.y);
        view.framed = clusters.len > 0;
        dvui.refresh(null, @src(), null);
    }
    const viewport = view.scroll.viewport;
    const range = mercator.tiles(view.z, viewport.x, viewport.y, viewport.w, viewport.h);
    for (range.y0..@as(usize, range.y1) +| 1) |y| {
        for (range.x0..@as(usize, range.x1) +| 1) |x| {
            if (tiles.get(.{ .z = view.z, .x = @intCast(x), .y = @intCast(y) })) |png| {
                _ = dvui.image(@src(), .{ .source = .{ .imageFile = .{ .bytes = png, .name = lib.fmt("tile-{d}-{d}-{d}", .{ view.z, x, y }) } } }, .{ .id_extra = y *% 65536 +% x, .rect = .{ .x = @as(f32, @floatFromInt(x)) * 256, .y = @as(f32, @floatFromInt(y)) * 256, .w = 256, .h = 256 } });
            }
        }
    }
    for (clusters, 0..) |c, i| {
        const p = mercator.worldPx(view.z, c.lat, c.lon);
        if (dvui.button(@src(), lib.fmt("{d}", .{c.count}), .{}, .{ .id_extra = i, .tag = lib.fmt("heronin-map-dot-{d}", .{i}), .rect = .{ .x = @floatCast(p.x - 22), .y = @floatCast(p.y - 22), .w = 44, .h = 44 }, .corners = .all(22), .color_fill = .{ .color = theme.orange[0] }, .color_text = .{ .color = theme.card } })) {
            state.at_cluster = i;
            state.segment = .seen;
            current.* = .species;
        }
    }
}
