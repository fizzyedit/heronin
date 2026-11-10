const std = @import("std");
const dvui = @import("dvui");
const model = @import("model");
const api = @import("../store.zig");
const lib = @import("library.zig");
fn done(_: ?*anyopaque, _: api.Error!void) void {}
pub fn draw(state: *lib.State, store: api.Store) void {
    if (dvui.button(@src(), "Back", .{}, .{ .tag = "heronin-picker-back", .min_size_content = .{ .h = 44 } })) {
        state.picking = false;
        return;
    }
    const search = dvui.textEntry(@src(), .{ .placeholder = "Search species", .text = .{ .internal = .{ .limit = 40 } } }, .{ .expand = .horizontal });
    const query = search.getText();
    search.deinit();
    var results: [8]model.Species = undefined;
    for (model.species.search(query, &results)) |picked| {
        const index = model.species.index(picked.code).?;
        if (dvui.button(@src(), picked.common, .{}, .{ .id_extra = index, .tag = lib.fmt("heronin-pick-{d}", .{index}), .expand = .horizontal, .min_size_content = .{ .h = 44 } })) {
            for (state.items) |*item| {
                if (!std.mem.eql(u8, item.photo.id, state.open.?)) continue;
                var buf: [5]model.Tag = undefined;
                buf[0] = .{ .species = picked.code, .confidence = 1, .source = .person, .accepted = .person, .at = lib.now(), .model = "" };
                var n: usize = 1;
                for (item.tags) |tag| {
                    if (n == buf.len) break;
                    if (std.mem.eql(u8, tag.species, picked.code)) continue;
                    buf[n] = tag;
                    n += 1;
                }
                store.setTags(item.photo.id, buf[0..n], .tagged, null, done);
                item.tags = state.arena.allocator().dupe(model.Tag, buf[0..n]) catch return;
                item.photo.state = .tagged;
                state.picking = false;
                return;
            }
        }
    }
}
