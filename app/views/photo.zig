const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const model = @import("model");
const api = @import("../store.zig");
const theme = @import("../theme.zig");
const lib = @import("library.zig");
fn done(_: ?*anyopaque, _: api.Error!void) void {}
pub fn draw(state: *lib.State, store: api.Store) void {
    if (dvui.button(@src(), "Back", .{}, .{ .min_size_content = .{ .h = 44 } })) {
        state.open = null;
        return;
    }
    var index: usize = 0;
    while (!std.mem.eql(u8, state.items[index].photo.id, state.open.?)) : (index += 1) {}
    const item = &state.items[index];
    const located = model.places.placeOf(item.photo, state.photos);
    const place = lib.logic.placeText(located, state.places);
    var scroll = core.widgets.ScrollArea.init(@src(), .{ .horizontal = .none }, .{ .expand = .both });
    defer scroll.deinit();
    lib.label(@src(), lib.fmt("{s}{s}{s}", .{ lib.day(item.photo), if (place != null) " · " else "", place orelse "" }), .{});
    if (item.tags.len > 0) {
        const tag = item.tags[0];
        const width = @max(44, dvui.parentGet().data().rect.w);
        const height = width * @as(f32, @floatFromInt(item.photo.h)) / @as(f32, @floatFromInt(item.photo.w));
        var image = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = width, .h = height }, .background = true, .color_fill = .{ .color = theme.washes[state.washes[index]] } });
        if (tag.box) |box| {
            var outline = dvui.box(@src(), .{}, .{ .rect = .{ .x = width * box.x, .y = height * box.y, .w = width * box.w, .h = height * box.h }, .border = .all(2), .color_border = .{ .color = theme.red[0] } });
            dvui.labelNoFmt(@src(), "bird found", .{}, .{ .font = dvui.Font.theme(.body).withSize(theme.size.small) });
            outline.deinit();
        }
        image.deinit();
        lib.species(lib.logic.common(tag), theme.size.species);
        lib.label(@src(), lib.fmt("{s}{s}{s}", .{ if (model.species.find(tag.species)) |s| s.scientific else "Unknown species", if (tag.detail != null) " · " else "", tag.detail orelse "" }), .{});
        lib.badge(item.photo.state);
        lib.label(@src(), lib.fmt("Agent's confidence {d} percent", .{@as(u32, @intFromFloat(@round(tag.confidence * 100)))}), .{});
        var track = dvui.box(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .h = 12 }, .background = true, .color_fill = .{ .color = theme.chip } });
        var bar = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = width * tag.confidence, .h = 12 }, .background = true, .color_fill = .{ .color = theme.red[0] } });
        bar.deinit();
        track.deinit();
        if (dvui.button(@src(), "Confirm", .{}, .{ .min_size_content = .{ .h = 44 } })) {
            var accepted = tag;
            accepted.accepted = .person;
            store.setTags(item.photo.id, &.{accepted}, .tagged, null, done);
            const kept = state.arena.allocator().dupe(model.Tag, &.{accepted}) catch return;
            item.tags = kept;
            item.photo.state = .tagged;
        }
        dvui.labelNoFmt(@src(), "Change species", .{}, .{ .min_size_content = .{ .h = 44 }, .background = true, .color_fill = .{ .color = theme.chip }, .color_text = .{ .color = theme.tab_off_ink }, .border = .all(2) });
        lib.label(@src(), "Other guesses", .{});
        for (item.tags[1..], 1..) |guess, i| {
            if (dvui.button(@src(), lib.fmt("{s}  {d} percent", .{ lib.logic.common(guess), @as(u32, @intFromFloat(@round(guess.confidence * 100))) }), .{}, .{ .id_extra = i, .min_size_content = .{ .h = 44 } })) {
                const kept = state.arena.allocator().dupe(model.Tag, item.tags) catch return;
                kept[i] = kept[0];
                kept[0] = guess;
                kept[0].accepted = .person;
                item.tags = kept;
                item.photo.state = .tagged;
                store.setTags(item.photo.id, kept, .tagged, null, done);
            }
        }
    } else lib.badge(item.photo.state);
    if (item.photo.state == .new or item.photo.state == .failed) {
        if (dvui.button(@src(), "Tag this", .{}, .{ .min_size_content = .{ .h = 44 }, .color_fill = .{ .color = theme.orange[0] } })) {
            if (state.tag_queue) |q| q.asked = item.photo.id;
        }
    }
    lib.label(@src(), lib.fmt("Seen: {s}", .{lib.day(item.photo)}), .{});
    lib.label(@src(), lib.fmt("Place: {s}{s}", .{ place orelse "No place", if (located) |point| switch (point.src) {
        .photo => " (from the photo)",
        .nearby => " (from a photo taken nearby)",
        .phone => " (from your phone at import)",
    } else "" }), .{});
    lib.label(@src(), lib.fmt("Camera: {s}", .{item.photo.camera orelse "Unknown"}), .{});
    var seen: usize = 0;
    if (item.tags.len > 0) for (state.items, 0..) |other, i| {
        if (i != index and (other.photo.state == .tagged or other.photo.state == .review) and other.tags.len > 0 and std.mem.eql(u8, item.tags[0].species, other.tags[0].species)) seen += 1;
    };
    lib.label(@src(), lib.fmt("Seen before: {d}", .{seen}), .{});
    if (item.tags.len > 0) {
        if (item.tags[0].note) |note| lib.label(@src(), note, .{});
    }
    if (dvui.button(@src(), if (item.photo.favorite) "Unfavorite" else "Favorite", .{}, .{ .min_size_content = .{ .h = 44 } })) {
        item.photo.favorite = !item.photo.favorite;
        store.setFavorite(item.photo.id, item.photo.favorite, null, done);
    }
}
