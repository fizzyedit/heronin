const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const model = @import("model");
const theme = @import("../theme.zig");
const places = @import("places.zig");
const lib = @import("library.zig");
fn day(at: i64, now: i64) []const u8 {
    return lib.logic.dayLabel(dvui.currentWindow().arena().alloc(u8, 40) catch unreachable, at, now, 0);
}
pub fn draw(state: *lib.State, now: i64, current: *@import("tabs.zig").Tab) void {
    const arena = dvui.currentWindow().arena();
    const photos = arena.alloc(model.Photo, state.items.len) catch unreachable;
    const tags = arena.alloc([]const model.Tag, state.items.len) catch unreachable;
    var n: usize = 0;
    for (state.items) |item| {
        if (state.segment == .by_place and model.places.placeOf(item.photo, state.photos) == null) continue;
        photos[n] = item.photo;
        tags[n] = item.tags;
        n += 1;
    }
    const groups = places.groups(state);
    const entries = if (state.at_cluster) |i| groups.entries(state, groups.clusters[i]) else model.life_list.build(arena, photos[0..n], tags[0..n]) catch unreachable;
    var new_buf: [model.species.table.len]usize = undefined;
    const recent = model.life_list.newThisWeek(entries, now, &new_buf);
    dvui.labelNoFmt(@src(), "Life list", .{}, .{ .font = dvui.Font.theme(.title), .color_text = .{ .color = theme.red[0] } });
    dvui.label(@src(), "{d} species", .{entries.len}, .{ .font = dvui.Font.theme(.body).withSize(theme.size.meta) });
    var segments = dvui.box(@src(), .{ .dir = .horizontal }, .{});
    inline for (.{ "Seen", "Not yet", "By place" }, .{ "heronin-seg-seen", "heronin-seg-not-yet", "heronin-seg-by-place" }, 0..) |title, tag, i| {
        const chosen = @backingInt(state.segment) == i;
        if (dvui.button(@src(), title, .{}, .{ .id_extra = i, .tag = tag, .min_size_content = .{ .h = 44 }, .border = .all(2), .corners = .all(22), .color_fill = .{ .color = if (chosen) theme.red[0] else theme.card }, .color_fill_hover = .{ .color = if (chosen) theme.red[0] else theme.card }, .color_fill_press = .{ .color = if (chosen) theme.red[0] else theme.card }, .color_text = .{ .color = if (chosen) theme.card else theme.red[0] }, .color_border = .{ .color = theme.red[0] } })) {
            state.segment = @fromBackingInt(@intCast(i));
            state.at_cluster = null;
        }
    }
    segments.deinit();
    const search = dvui.textEntry(@src(), .{ .placeholder = "Search species or place", .text = .{ .internal = .{ .limit = 40 } } }, .{ .expand = .horizontal });
    const query = search.getText();
    search.deinit();
    if (state.at_cluster) |i| {
        if (dvui.button(@src(), lib.fmt("At {s} ×", .{places.name(state, groups.clusters[i])}), .{}, .{ .tag = "heronin-place-chip", .min_size_content = .{ .h = 44 } })) state.at_cluster = null;
    }
    if (recent.len > 0) {
        const e = entries[recent[0]];
        var banner = dvui.box(@src(), .{}, .{ .tag = "heronin-new-week", .expand = .horizontal, .background = true, .color_fill = .{ .color = theme.mustard[2] } });
        lib.label(@src(), lib.fmt("New this week: {s}{s}. First photo {s}.", .{ e.species.common, if (recent.len > 1) lib.fmt(" and {d} more", .{recent.len - 1}) else "", day(e.first_at.?, now) }), .{});
        banner.deinit();
    }
    var scroll = core.widgets.ScrollArea.init(@src(), .{ .horizontal = .none }, .{ .expand = .both });
    defer scroll.deinit();
    if (state.segment == .by_place) {
        places.draw(state, groups);
        return;
    }
    var missing_buf: [model.species.table.len]model.Species = undefined;
    const missing = model.life_list.notYet(entries, &missing_buf);
    var shown: usize = 0;
    if (state.segment == .seen) {
        for (entries, 0..) |e, ei| {
            if (!model.species.matches(e.species.common, query) and !model.species.matches(e.species.scientific, query) and !places.matches(groups, state, e.species.code, query)) continue;
            const index = model.species.index(e.species.code).?;
            var row: dvui.ButtonWidget = undefined;
            row.init(@src(), .{}, .{ .id_extra = index, .tag = lib.fmt("heronin-seen-{d}", .{index}), .expand = .horizontal, .background = true, .color_fill = .{ .color = theme.washes[index % 6] } });
            row.processEvents();
            row.drawBackground();
            lib.species(e.species.common, theme.size.species);
            var place: ?[]const u8 = null;
            for (photos[0..n]) |photo| if (std.mem.eql(u8, photo.id, e.first)) {
                place = lib.logic.placeText(model.places.placeOf(photo, state.photos), state.places, if (model.places.placeOf(photo, state.photos)) |point| lib.places_client.near(&lib.places_client.names, point) else null);
                break;
            };
            lib.label(@src(), if (e.first_at) |at| lib.fmt("First seen {s}{s}{s}", .{ day(at, now), if (place != null) " · " else "", place orelse "" }) else "First seen: date unknown", .{ .font = dvui.Font.theme(.body).withSize(theme.size.meta) });
            var is_new = false;
            for (recent) |i| {
                if (i == ei) is_new = true;
            }
            dvui.label(@src(), "{d}", .{e.count}, .{ .background = true, .color_fill = .{ .color = if (is_new) theme.mustard[0] else theme.chip } });
            if (row.clicked()) {
                state.species = model.species.table[index].code;
                state.filter = .species;
                state.close();
                current.* = .library;
            }
            row.deinit();
            shown += 1;
        }
    } else {
        for (missing) |s| {
            if (!model.species.matches(s.common, query) and !model.species.matches(s.scientific, query)) continue;
            dvui.labelNoFmt(@src(), s.common, .{}, .{ .id_extra = model.species.index(s.code).?, .color_text = .{ .color = theme.brown[0] } });
            shown += 1;
        }
    }
    if (shown == 0) lib.label(@src(), if (std.mem.trim(u8, query, " ").len > 0) "No species match" else if (state.segment == .seen) "No birds yet. Confirm a photo to start your list." else "You have photographed every species Heronin knows.", .{});
}
