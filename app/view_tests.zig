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
    state.open = null;
    current = .species;
    state.segment = .seen;
    try dvui.testing.settle(frame);
    try dvui.testing.expectVisible("heronin-tabs");
    state.segment = .not_yet;
    try dvui.testing.settle(frame);
    try dvui.testing.expectVisible("heronin-tabs");
    current = .add;
    try dvui.testing.settle(frame);
    try dvui.testing.expectVisible("heronin-tabs");
}

const theme = @import("theme.zig");
var check_library_text = false;
fn readableFrame() !dvui.App.Result {
    _ = try frame();
    if (check_library_text) {
        for (state.items, 0..) |item, i| {
            const title = try dvui.testing.tagGet(library.fmt("tile-title-{d}", .{i}));
            try expectTextFits(library.logic.tileTitle(item), .find(.{ .family = theme.species_face, .size = theme.size.tile_species, .weight = .bold }), title.rect);
            const place = library.logic.placeText(@import("model").places.placeOf(item.photo, state.photos), state.places);
            const text = library.fmt("{s}{s}{s}", .{ library.day(item.photo), if (place != null or item.photo.state == .review) " · " else "", if (item.photo.state == .review) library.fmt("{d} guesses", .{item.tags.len}) else place orelse "" });
            const meta = try dvui.testing.tagGet(library.fmt("tile-place-{d}", .{i}));
            try expectTextFits(text, dvui.Font.theme(.body).withSize(theme.size.meta), meta.rect);
        }
        const favorites = try dvui.testing.tagGet("Favorites");
        try std.testing.expect(favorites.rect.x >= 0 and favorites.rect.y >= 0);
        try std.testing.expect(favorites.rect.x + favorites.rect.w <= 390 * dvui.parentGet().screenRectScale(.{}).s);
        try std.testing.expect(favorites.rect.y + favorites.rect.h <= 844 * dvui.parentGet().screenRectScale(.{}).s);
        try dvui.testing.expectVisible("Favorites");
    }
    return .ok;
}
fn expectTextFits(text: []const u8, font: dvui.Font, rect: dvui.Rect.Physical) !void {
    // Measure the complete text, including anything a LabelWidget would
    // replace with ellipsis. Wrapped text must have room for all its glyphs.
    const measured = font.textSize(text);
    const scale = dvui.parentGet().screenRectScale(.{}).s;
    const width = rect.w / scale;
    const height = rect.h / scale;
    try std.testing.expect(rect.w > 0);
    const rows = @max(1, @floor((height + 0.5) / font.textSize("").h));
    try std.testing.expect(measured.w <= width * rows + 0.5);
}
test "library text wraps and Favorites stays inside a phone window" {
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
    check_library_text = false;
    try dvui.testing.settle(readableFrame);
    check_library_text = true;
    defer check_library_text = false;
    _ = try dvui.testing.step(readableFrame);
}

var species_now: i64 = 0;
fn speciesFrame() !dvui.App.Result {
    @import("views/species.zig").draw(&state, species_now);
    return .ok;
}
test "life list banner uses the supplied time" {
    var testing = try dvui.testing.init(.{ .window_size = .{ .w = 390, .h = 844 } });
    defer testing.deinit();
    fake = try .init(std.testing.allocator);
    defer fake.deinit();
    state = .{};
    defer state.arena.deinit();
    fake.store().list(null, 60, &state, library.State.listed);
    fake.store().places(&state, library.State.placed);
    fake.store().pump();
    const model = @import("model");
    var photos: [60]model.Photo = undefined;
    var tags: [60][]const model.Tag = undefined;
    for (state.items, 0..) |item, i| {
        photos[i] = item.photo;
        tags[i] = item.tags;
    }
    const entries = try model.life_list.build(std.testing.allocator, photos[0..state.items.len], tags[0..state.items.len]);
    defer std.testing.allocator.free(entries);
    var latest: ?i64 = null;
    for (entries) |e| if (e.first_at) |at| {
        latest = @max(latest orelse at, at);
    };
    try std.testing.expect(latest != null);
    species_now = latest.? + 86400;
    try dvui.testing.settle(speciesFrame);
    try dvui.testing.expectVisible("heronin-new-week");
}
