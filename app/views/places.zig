const std = @import("std");
const dvui = @import("dvui");
const model = @import("model");
const lib = @import("library.zig");
const api = @import("../store.zig");
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
    if (@import("../places_client.zig").near(&@import("../places_client.zig").names, c)) |n| return lib.fmt("near {s}", .{n});
    return model.places.unnamed;
}
pub fn matches(g: Groups, state: *lib.State, code: []const u8, query: []const u8) bool {
    for (g.clusters) |c| {
        if (c.place == null or !model.species.matches(name(state, c), query)) continue;
        for (g.entries(state, c)) |e| if (std.mem.eql(u8, e.species.code, code)) return true;
    }
    return false;
}
pub fn draw(state: *lib.State, store: api.Store, g: Groups) void {
    if (g.clusters.len == 0) lib.label(@src(), "No photos with a place yet", .{});
    for (g.clusters, 0..) |c, i| {
        var box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .expand = .horizontal });
        defer box.deinit();
        var row: dvui.ButtonWidget = undefined;
        row.init(@src(), .{}, .{ .id_extra = i, .tag = lib.fmt("heronin-place-{d}", .{i}), .expand = .horizontal, .background = true, .color_fill = .{ .color = theme.washes[i % 6] } });
        row.processEvents();
        row.drawBackground();
        lib.label(@src(), name(state, c), .{ .id_extra = i, .tag = lib.fmt("heronin-species-{x}", .{dvui.parentGet().data().id}), .font = .find(.{ .family = theme.species_face, .size = theme.size.species, .weight = .bold }), .color_text = .{ .color = theme.red[0] } });
        lib.label(@src(), lib.fmt("{d} photos · {d} species", .{ c.count, g.entries(state, c).len }), .{ .id_extra = i });
        if (row.clicked()) {
            state.at_cluster = i;
            state.segment = .seen;
        }
        row.deinit();
        var largest: u16 = 0;
        for (state.places) |p| largest = @max(largest, p.id);
        if (state.renaming == i) {
            var edit = dvui.box(@src(), .{}, .{ .id_extra = i });
            defer edit.deinit();
            const initial = if (c.place != null) name(state, c) else lib.places_client.near(&lib.places_client.names, c) orelse "";
            const entry = dvui.textEntry(@src(), .{ .text = .{ .internal = .{ .limit = 40 } }, .text_initial = initial }, .{ .id_extra = i, .tag = "heronin-rename-entry", .min_size_content = .{ .w = 90 } });
            var text = std.mem.trim(u8, entry.getText(), " \t\r\n");
            var len = @min(text.len, 40);
            while (len > 0 and !std.unicode.utf8ValidateSlice(text[0..len])) len -= 1;
            text = text[0..len];
            const enter = entry.enter_pressed;
            entry.deinit();
            if ((dvui.button(@src(), "Save", .{ .grayed = text.len == 0 }, .{ .id_extra = i, .tag = "heronin-rename-save", .min_size_content = .{ .h = 44 } }) or enter) and text.len > 0) {
                const values = dvui.currentWindow().arena().alloc(model.Place, state.places.len + @intFromBool(c.place == null)) catch unreachable;
                @memcpy(values[0..state.places.len], state.places);
                if (c.place) |id| {
                    for (values) |*p| if (p.id == id) {
                        p.name = text;
                    };
                } else values[state.places.len] = .{ .id = largest + 1, .name = text, .lat = c.lat, .lon = c.lon, .radius_m = 150 };
                store.savePlaces(values, state, renamed);
            }
            if (dvui.button(@src(), "Cancel", .{}, .{ .id_extra = i, .tag = "heronin-rename-cancel", .min_size_content = .{ .h = 44 } })) state.renaming = null;
            if (state.rename_failed) lib.label(@src(), "Could not save the name", .{ .id_extra = i });
        } else if (c.place != null or largest < std.math.maxInt(u16)) {
            if (dvui.button(@src(), "Rename", .{}, .{ .id_extra = i, .tag = lib.fmt("heronin-rename-{d}", .{i}), .min_size_content = .{ .h = 44 } })) {
                state.renaming = i;
                state.rename_failed = false;
            }
        }
    }
}
fn renamed(ctx: ?*anyopaque, result: api.Error![]const model.Place) void {
    const state: *lib.State = @ptrCast(@alignCast(ctx.?));
    state.rename_failed = std.meta.isError(result);
    if (!state.rename_failed) lib.State.placed(ctx, result);
}
