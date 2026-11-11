pub const places_client = @import("../places_client.zig");
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const model = @import("model");
const api = @import("../store.zig");
const theme = @import("../theme.zig");
pub const logic = @import("../library_logic.zig");
pub fn photoPlace(photo: model.Photo, photos: []const model.Photo, saved: []const model.Place) ?[]const u8 {
    const located = model.places.placeOf(photo, photos);
    return logic.placeText(dvui.currentWindow().arena(), located, saved, if (located) |point| places_client.near(&places_client.names, point) else null);
}
pub const State = struct {
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    items: []api.Item = &.{},
    places: []model.Place = &.{},
    thumbs: [60]Thumb = @splat(.{}),
    requested: bool = false,
    stale: bool = false,
    photos: []model.Photo = &.{},
    segment: enum { seen, not_yet, by_place } = .seen,
    at_cluster: ?usize = null,
    renaming: ?usize = null,
    rename_failed: bool = false,
    filter: logic.Filter = .all,
    open: ?[]const u8 = null,
    species: ?[]const u8 = null,
    picking: bool = false,
    tag_queue: ?*@import("../tag_queue.zig").TagQueue = null,
    pub const Thumb = struct {
        owner: *State = undefined,
        wash: u8 = 0,
        image: []const u8 = &.{},
    };
    pub fn close(self: *State) void {
        self.open = null;
        self.picking = false;
    }
    pub fn reloadBetweenJobs(self: *State, store: api.Store, busy: bool, in_library: bool) bool {
        if (busy or !in_library or self.open != null or !self.stale) return false;
        self.reload(store);
        return true;
    }
    pub fn reload(self: *State, store: api.Store) void {
        std.debug.assert(self.open == null);
        _ = self.arena.reset(.retain_capacity);
        self.at_cluster = null;
        self.renaming = null;
        self.items = &.{};
        self.places = &.{};
        self.photos = &.{};
        self.requested = false;
        self.thumbs = @splat(.{});
        self.stale = false;
        dvui.refresh(null, @src(), null);
        store.list(null, 60, self, listed);
        store.places(self, placed);
    }
    pub fn thumbnail(ctx: ?*anyopaque, result: api.Error!api.Thumbnail) void {
        const thumb: *Thumb = @ptrCast(@alignCast(ctx.?));
        switch (result catch return) {
            .wash => |w| thumb.wash = w % 6,
            .encoded => |bytes| {
                thumb.image = thumb.owner.arena.allocator().dupe(u8, bytes) catch return;
            },
        }
    }

    pub fn listed(ctx: ?*anyopaque, result: api.Error![]const api.Item) void {
        const self: *State = @ptrCast(@alignCast(ctx.?));
        self.items = copy(api.Item, self.arena.allocator(), result catch return) catch return;
        self.photos = self.arena.allocator().alloc(model.Photo, self.items.len) catch return;
        for (self.items, self.photos) |item, *photo| photo.* = item.photo;
        self.requested = false;
    }
    pub fn placed(ctx: ?*anyopaque, result: api.Error![]const model.Place) void {
        const self: *State = @ptrCast(@alignCast(ctx.?));
        self.at_cluster = null;
        self.renaming = null;
        self.places = copy(model.Place, self.arena.allocator(), result catch return) catch return;
    }
};
fn copy(comptime T: type, a: std.mem.Allocator, values: []const T) ![]T {
    const out = try a.dupe(T, values);
    for (out) |*v| inline for (@typeInfo(T).@"struct".field_names) |name| {
        const V = @FieldType(T, name);
        if (V == []const u8) @field(v, name) = try a.dupe(u8, @field(v, name)) else if (V == ?[]const u8) {
            if (@field(v, name)) |s| @field(v, name) = try a.dupe(u8, s);
        } else if (V == model.Photo) {
            @field(v, name) = (try copy(model.Photo, a, &.{@field(v, name)}))[0];
        } else if (V == []const model.Tag) @field(v, name) = try copy(model.Tag, a, @field(v, name));
    };
    return out;
}
pub fn fmt(comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), format, args) catch unreachable;
}
pub fn label(src: std.builtin.SourceLocation, text: []const u8, opts: dvui.Options) void {
    var layout = dvui.textLayout(src, .{}, opts.override(.{ .expand = .horizontal, .background = false, .padding = .all(0) }));
    layout.addText(text, .{});
    layout.deinit();
}
pub fn species(text: []const u8, size: f32) void {
    // TODO(font): Zilla Slab for species names, a later job adds the asset
    label(@src(), text, .{ .tag = fmt("heronin-species-{x}", .{dvui.parentGet().data().id}), .font = .find(.{ .family = theme.species_face, .size = size, .weight = .bold }), .color_text = .{ .color = theme.red[0] } });
}
pub fn badge(state: model.Photo.State) void {
    const style = switch (state) {
        .new => theme.waiting,
        .tagging => theme.working,
        .tagged => theme.tagged,
        .review => theme.review,
        .failed => theme.failed,
        .skipped => theme.other,
    };
    dvui.labelNoFmt(@src(), logic.statusWord(state), .{}, .{ .background = true, .color_fill = .{ .color = style.fill }, .color_text = .{ .color = style.ink } });
}
pub fn now() i64 {
    return @intCast(@divFloor(std.Io.Clock.real.now(dvui.io).nanoseconds, 1_000_000_000));
}
pub fn day(photo: model.Photo) []const u8 {
    return if (photo.taken_at) |at| logic.dayLabel(dvui.currentWindow().arena().alloc(u8, 40) catch unreachable, at, now(), 0) else "Unknown date";
}
pub fn draw(state: *State) void {
    var heading = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    dvui.labelNoFmt(@src(), "Heronin", .{}, .{ .font = dvui.Font.theme(.title), .color_text = .{ .color = theme.red[0] } });
    var tagging: usize = 0;
    for (state.items) |item| {
        if (item.photo.state == .tagging) tagging += 1;
    }
    if (tagging > 0) dvui.label(@src(), "Agent is tagging {d}", .{tagging}, .{ .background = true, .corners = .all(20), .color_fill = .{ .color = theme.chip } });
    heading.deinit();
    var filters = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal });
    if (state.filter == .species) {
        const chosen = model.species.find(state.species.?).?;
        if (dvui.button(@src(), fmt("{s} ×", .{chosen.common}), .{}, .{ .id_extra = 4, .tag = "heronin-species-chip", .min_size_content = .{ .h = 44 }, .background = true, .color_fill = .{ .color = theme.red[0] }, .color_text = .{ .color = theme.card } })) {
            state.filter = .all;
            state.species = null;
        }
    }
    inline for (.{ "All", "Tagged", "Needs review", "Favorites" }, 0..) |title, i| {
        const chosen = @backingInt(state.filter) == i;
        if (dvui.button(@src(), title, .{}, .{ .id_extra = i, .tag = ([_][]const u8{ "heronin-filter-all", "heronin-filter-tagged", "heronin-filter-review", "heronin-filter-favorites" })[i], .margin = .all(6), .font = .find(.{ .family = theme.body_face, .size = 14, .weight = .bold }), .min_size_content = .{ .h = 44 }, .border = .all(2), .corners = .all(22), .color_fill = .{ .color = if (chosen) theme.red[0] else theme.card }, .color_fill_hover = .{ .color = if (chosen) theme.red[0] else theme.card }, .color_fill_press = .{ .color = if (chosen) theme.red[0] else theme.card }, .color_text = .{ .color = if (chosen) theme.card else theme.red[0] }, .color_border = .{ .color = theme.red[0] } })) state.filter = @fromBackingInt(@intCast(i));
    }
    filters.deinit();
    var scroll = core.widgets.ScrollArea.init(@src(), .{ .horizontal = .none }, .{ .expand = .both });
    defer scroll.deinit();
    const width = dvui.parentGet().data().rect.w;
    const count = @min(60, if (width < 600) @as(usize, 2) else 3 + @as(usize, @intFromFloat((width - 600) / 300)));
    const col_w = @max(44, (width - 12 * @as(f32, @floatFromInt(count - 1))) / @as(f32, @floatFromInt(count)));
    var heights: [60]f32 = undefined;
    var columns: [60]f32 = @splat(0);
    var positions: [60]usize = undefined;
    for (state.items, 0..) |item, i| heights[i] = if (logic.matches(item, state.filter, state.species)) @max(44, col_w * @as(f32, @floatFromInt(item.photo.h)) / @as(f32, @floatFromInt(item.photo.w))) else 0;
    logic.placeTiles(heights[0..state.items.len], columns[0..count], positions[0..state.items.len]);
    var grid = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer grid.deinit();
    for (0..count) |col| {
        var column = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = col, .min_size_content = .{ .w = col_w }, .max_size_content = .width(col_w), .margin = .{ .w = if (col + 1 == count) 0 else 12 } });
        defer column.deinit();
        for (state.items, 0..) |item, i| {
            if (!logic.matches(item, state.filter, state.species) or positions[i] != col) continue;
            var tile: dvui.ButtonWidget = undefined;
            tile.init(@src(), .{}, .{ .id_extra = i, .expand = .horizontal, .padding = .all(0), .border = .all(2), .margin = .{ .h = 12 }, .color_border = .{ .color = theme.border }, .color_fill = .{ .color = theme.card } });
            tile.processEvents();
            tile.drawBackground();
            var contents = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = .{ .x = 8, .y = 6, .w = 8, .h = 8 } });
            var image = dvui.box(@src(), .{}, .{
                .tag = fmt("tile-box-{d}", .{i}),
                .expand = .horizontal,
                .min_size_content = .{ .h = heights[i] },
                .background = true,
                .color_fill = .{ .color = theme.washes[state.thumbs[i].wash] },
            });
            thumbnailImage(state.thumbs[i], item.photo.id, fmt("tile-image-{d}", .{i}));
            badge(item.photo.state);
            image.deinit();
            label(@src(), logic.tileTitle(item), .{ .tag = fmt("tile-title-{d}", .{i}), .font = .find(.{ .family = theme.species_face, .size = theme.size.tile_species, .weight = .bold }), .color_text = .{ .color = theme.red[0] } });
            const place = photoPlace(item.photo, state.photos, state.places);
            label(@src(), logic.tileMeta(dvui.currentWindow().arena(), item, place, day(item.photo)), .{ .tag = fmt("tile-place-{d}", .{i}), .font = dvui.Font.theme(.body).withSize(theme.size.meta), .color_text = .{ .color = theme.tab_off_ink } });
            contents.deinit();
            if (tile.clicked()) state.open = item.photo.id;
            tile.deinit();
        }
    }
}

pub fn thumbnailImage(thumb: State.Thumb, id: []const u8, tag: []const u8) void {
    if (thumb.image.len == 0) return;
    _ = dvui.image(@src(), .{
        .source = .{ .imageFile = .{ .bytes = thumb.image, .name = id } },
        .shrink = .ratio,
    }, .{
        .rect = .{},
        .expand = .both,
        .tag = tag,
        .corners = dvui.parentGet().data().options.corners,
    });
}
