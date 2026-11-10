const std = @import("std");
const dvui = @import("dvui");
const model = @import("model");
const lib = @import("library.zig");
const theme = @import("../theme.zig");
pub const Groups = struct {
    clusters: []model.places.Cluster,
    items: []usize,
    lists: [][]model.life_list.Entry = &.{},
    pub fn entries(self: Groups, _: *lib.State, c: model.places.Cluster) []model.life_list.Entry {
        for (self.clusters, self.lists) |cluster, list| if (cluster.members.ptr == c.members.ptr) return list;
        unreachable;
    }
    fn buildEntries(self: Groups, state: *lib.State, c: model.places.Cluster) []model.life_list.Entry {
        const a = dvui.currentWindow().arena();
        const photos = a.alloc(model.Photo, c.members.len) catch unreachable;
        const tags = a.alloc([]const model.Tag, c.members.len) catch unreachable;
        for (c.members, photos, tags) |m, *p, *t| {
            const item = state.items[self.items[m]];
            p.* = item.photo;
            t.* = item.tags;
        }
        return model.life_list.build(a, photos, tags) catch unreachable;
    }
};
pub fn groups(state: *lib.State) Groups {
    const a = dvui.currentWindow().arena();
    var points: std.ArrayList(model.places.Point) = .empty;
    var items: std.ArrayList(usize) = .empty;
    for (state.items, 0..) |item, i| if (model.places.placeOf(item.photo, state.photos)) |p| {
        points.append(a, .{ .lat = p.lat, .lon = p.lon, .at = item.photo.taken_at, .id = item.photo.id }) catch unreachable;
        items.append(a, i) catch unreachable;
    };
    var result: Groups = .{ .clusters = model.places.cluster(a, points.items, state.places, 150) catch unreachable, .items = items.items };
    result.lists = a.alloc([]model.life_list.Entry, result.clusters.len) catch unreachable;
    for (result.clusters, result.lists) |c, *list| list.* = result.buildEntries(state, c);
    return result;
}
pub fn name(state: *lib.State, c: model.places.Cluster) []const u8 {
    for (state.places) |p| if (c.place == p.id) return p.name;
    return model.places.unnamed;
}
pub fn matches(g: Groups, state: *lib.State, code: []const u8, query: []const u8) bool {
    for (g.clusters) |c| {
        if (c.place == null or !model.species.matches(name(state, c), query)) continue;
        for (g.entries(state, c)) |e| if (std.mem.eql(u8, e.species.code, code)) return true;
    }
    return false;
}
pub fn draw(state: *lib.State, g: Groups) void {
    if (g.clusters.len == 0) lib.label(@src(), "No photos with a place yet", .{});
    for (g.clusters, 0..) |c, i| {
        var row: dvui.ButtonWidget = undefined;
        row.init(@src(), .{}, .{ .id_extra = i, .tag = lib.fmt("heronin-place-{d}", .{i}), .expand = .horizontal, .background = true, .color_fill = .{ .color = theme.washes[i % 6] } });
        row.processEvents();
        row.drawBackground();
        lib.species(name(state, c), theme.size.species);
        lib.label(@src(), lib.fmt("{d} photos · {d} species", .{ c.count, g.entries(state, c).len }), .{ .id_extra = i });
        if (row.clicked()) {
            state.at_cluster = i;
            state.segment = .seen;
        }
        row.deinit();
    }
}
