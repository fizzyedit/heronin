test {
    _ = @import("places_tests.zig");
}
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
    const sign = @import("sign_in.zig");
    defer sign.account.deinit();
    sign.account.state = .signed_out;
    try dvui.testing.settle(frame);
    try dvui.testing.expectVisible("heronin-sign-in");
    try dvui.testing.expectVisible("heronin-tabs");
    sign.account.failed = .popup;
    try dvui.testing.settle(frame);
    try dvui.testing.expectVisible("heronin-sign-in-note");
    sign.account.state = .signed_in;
    try dvui.testing.settle(frame);
    try std.testing.expect(dvui.tagGet("heronin-sign-in") == null);
    for (state.items) |item| {
        if (item.tags.len >= 2) {
            state.open = item.photo.id;
            break;
        }
    }
    try std.testing.expect(state.open != null);
    try dvui.testing.settle(frame);
    try dvui.testing.expectVisible("heronin-tabs");
    state.picking = true;
    try dvui.testing.settle(frame);
    try dvui.testing.expectVisible("heronin-tabs");
    try queue.add(&.{ "a.jpg", "b.jpg" }, &.{ try queue.allocator.dupe(u8, "a"), try queue.allocator.dupe(u8, "b") });
    while (queue.busy or for (queue.rows.items) |row| {
        if (row.state == .queued) break true;
    } else false) {
        queue.step(fake.store());
        fake.store().pump();
    }
    state.close();
    current = .species;
    state.segment = .seen;
    try dvui.testing.settle(frame);
    try dvui.testing.expectVisible("heronin-tabs");
    state.segment = .not_yet;
    try dvui.testing.settle(frame);
    try dvui.testing.expectVisible("heronin-tabs");
    state.segment = .by_place;
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
            const place = library.logic.placeText(@import("model").places.placeOf(item.photo, state.photos), state.places, null);
            const text = library.logic.tileMeta(dvui.currentWindow().arena(), item, place, library.day(item.photo));
            const meta = try dvui.testing.tagGet(library.fmt("tile-place-{d}", .{i}));
            try expectTextFits(text, dvui.Font.theme(.body).withSize(theme.size.meta), meta.rect);
        }
        const favorites = try dvui.testing.tagGet("heronin-filter-favorites");
        try std.testing.expect(favorites.rect.x >= 0 and favorites.rect.y >= 0);
        try std.testing.expect(favorites.rect.x + favorites.rect.w <= 390 * dvui.parentGet().screenRectScale(.{}).s);
        try std.testing.expect(favorites.rect.y + favorites.rect.h <= 844 * dvui.parentGet().screenRectScale(.{}).s);
        try dvui.testing.expectVisible("heronin-filter-favorites");
        var content = favorites.rect;
        const inset = 2 * (6 + 2) * dvui.parentGet().screenRectScale(.{}).s;
        content.w -= inset;
        content.h -= inset;
        try expectTextFits("Favorites", .find(.{ .family = theme.body_face, .size = 14, .weight = .bold }), content);
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
    @import("views/species.zig").draw(&state, species_now, fake.store(), &current);
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

fn countedHerons() !u32 {
    const model = @import("model");
    var photos: [60]model.Photo = undefined;
    var tags: [60][]const model.Tag = undefined;
    for (state.items, 0..) |item, i| {
        photos[i] = item.photo;
        tags[i] = item.tags;
    }
    const entries = try model.life_list.build(std.testing.allocator, photos[0..state.items.len], tags[0..state.items.len]);
    defer std.testing.allocator.free(entries);
    for (entries) |entry| if (std.mem.eql(u8, entry.species.code, "grbher3")) return entry.count;
    return 0;
}
fn tap(tag: []const u8) !void {
    try dvui.testing.moveTo(tag);
    try dvui.testing.click(.left);
    try dvui.testing.settle(frame);
}
test "picker saves a review photo and increases the Seen count" {
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
    fake.store().pump();
    const before = try countedHerons();
    var selected: usize = 0;
    for (state.items, 0..) |item, i| if (item.photo.state == .review) {
        selected = i;
        state.open = item.photo.id;
        break;
    };
    state.picking = true;
    try dvui.testing.settle(frame);
    try tap("heronin-picker-back");
    try std.testing.expect(!state.picking and state.open != null);
    state.picking = true;
    try dvui.testing.settle(frame);
    try tap("heronin-pick-0");
    try std.testing.expect(!state.picking and state.open != null);
    try std.testing.expectEqual(before + 1, try countedHerons());
    fake.store().pump();
    state.close();
    fake.store().list(null, 60, &state, library.State.listed);
    fake.store().pump();
    const item = state.items[selected];
    try std.testing.expectEqual(.tagged, item.photo.state);
    try std.testing.expectEqualStrings("grbher3", item.tags[0].species);
    try std.testing.expectEqual(.person, item.tags[0].source);
    try std.testing.expectEqual(.person, item.tags[0].accepted);
    try std.testing.expectEqual(before + 1, try countedHerons());
}
test "Seen row opens only its counted photos and its chip returns to All" {
    var testing = try dvui.testing.init(.{ .window_size = .{ .w = 390, .h = 844 } });
    defer testing.deinit();
    fake = try .init(std.testing.allocator);
    defer fake.deinit();
    state = .{};
    defer state.arena.deinit();
    queue = .{ .allocator = std.testing.allocator };
    defer queue.deinit();
    current = .species;
    fake.store().list(null, 60, &state, library.State.listed);
    fake.store().pump();
    try dvui.testing.settle(frame);
    try tap("heronin-seen-0");
    try std.testing.expectEqual(.library, current);
    try dvui.testing.expectVisible("heronin-species-chip");
    for (state.items, 0..) |item, i| {
        const tile = dvui.tagGet(library.fmt("tile-title-{d}", .{i}));
        try std.testing.expectEqual(library.logic.matches(item, .species, "grbher3"), tile != null);
    }
    const chosen = state.species.?;
    state.stale = true;
    try std.testing.expect(state.reloadBetweenJobs(fake.store(), false, true));
    fake.store().pump();
    try std.testing.expect(state.species.?.ptr == chosen.ptr);
    try std.testing.expect(state.species.?.ptr == @import("model").species.table[0].code.ptr);
    try dvui.testing.settle(frame);
    try tap("heronin-species-chip");
    try std.testing.expectEqual(.all, state.filter);
    try std.testing.expect(state.species == null);
    for (state.items, 0..) |_, i| try std.testing.expect(dvui.tagGet(library.fmt("tile-title-{d}", .{i})) != null);
}

test "By place rows select only their member species and clear on places reload" {
    var testing = try dvui.testing.init(.{ .window_size = .{ .w = 390, .h = 844 } });
    defer testing.deinit();
    fake = try .init(std.testing.allocator);
    defer fake.deinit();
    state = .{};
    defer state.arena.deinit();
    queue = .{ .allocator = std.testing.allocator };
    defer queue.deinit();
    fake.store().list(null, 60, &state, library.State.listed);
    fake.store().places(&state, library.State.placed);
    fake.store().pump();
    current = .species;
    state.segment = .by_place;
    try dvui.testing.settle(frame);
    try dvui.testing.expectVisible("heronin-place-0");
    const places = library.places_client;
    defer places.names.deinit();
    _ = try dvui.testing.step(struct {
        fn frame() !dvui.App.Result {
            const view = @import("views/places.zig");
            for (view.groups(&state).clusters) |c| if (c.place == null) {
                places.names.answers = try places.names.arena.allocator().alloc(places.Answer, 1);
                places.names.answers[0] = .{ .lat = c.lat, .lon = c.lon };
                places.done(&places.names, .{ .status = 200, .body = try places.names.arena.allocator().dupe(u8, "{\"name\":\"Sea Mount\"}") });
                try std.testing.expectEqualStrings("near Sea Mount", view.name(&state, c));
                break;
            };
            return .ok;
        }
    }.frame);
    try dvui.testing.settle(frame);
    _ = try dvui.testing.step(placeChecksFrame);
    try tap("heronin-place-0");
    try std.testing.expectEqual(@as(?usize, 0), state.at_cluster);
    try std.testing.expectEqual(.seen, state.segment);
    try dvui.testing.expectVisible("heronin-place-chip");
    try tap("heronin-place-chip");
    try std.testing.expectEqual(null, state.at_cluster);
    state.at_cluster = 0;
    fake.store().places(&state, library.State.placed);
    fake.store().pump();
    try std.testing.expectEqual(null, state.at_cluster);
}

fn placeChecksFrame() !dvui.App.Result {
    _ = try frame();
    const view = @import("views/places.zig");
    const model = @import("model");
    const groups = view.groups(&state);
    var named_species: usize = 0;
    for (groups.clusters) |c| {
        const entries = groups.entries(&state, c);
        var photos: u32 = 0;
        for (entries) |e| {
            photos += e.count;
            if (c.place != null) {
                try std.testing.expect(view.matches(groups, &state, e.species.code, view.name(&state, c)));
                named_species += 1;
            }
            var expected: u32 = 0;
            for (c.members) |m| {
                const item = state.items[groups.items[m]];
                if (model.life_list.counted(item.photo, item.tags)) |sp| {
                    if (std.mem.eql(u8, sp.code, e.species.code)) expected += 1;
                }
            }
            try std.testing.expectEqual(expected, e.count);
        }
        try std.testing.expect(photos <= c.count);
    }
    try std.testing.expect(named_species > 0);
    try std.testing.expect(!view.matches(groups, &state, "grbher3", "Unnamed place"));
    return .ok;
}

test "Connect fields keep their chip fill height and text ink" {
    var testing = try dvui.testing.init(.{ .window_size = .{ .w = 390, .h = 844 } });
    defer testing.deinit();
    const draw = struct {
        fn frame() !dvui.App.Result {
            var tab: @import("views/tabs.zig").Tab = .agent;
            var settings: @import("tag_queue.zig").Settings = .{};
            @import("views/agent.zig").page(&tab, &settings);
            if (dvui.debug.widget_id != .undef) {
                const opts = dvui.debug.target_wd.?.options;
                try std.testing.expect(opts.background.?);
                try std.testing.expectEqual(theme.chip, opts.color_fill.?.color);
                try std.testing.expectEqual(theme.ink, opts.color_text.?.color);
                try std.testing.expect(opts.min_size_content.?.h >= 44);
            }
            return .ok;
        }
    }.frame;
    const sign = @import("sign_in.zig");
    defer sign.account.deinit();
    sign.account.state = .signed_in;
    dvui.debug.widget_id = .undef;
    try dvui.testing.settle(draw);
    try dvui.testing.expectVisible("heronin-sign-out");
    defer dvui.debug.widget_id = .undef;
    for ([_][]const u8{ "heronin-connect-address", "heronin-connect-key", "heronin-connect-save" }) |tag| {
        dvui.debug.widget_id = (try dvui.testing.tagGet(tag)).id;
        try dvui.testing.settle(draw);
    }
}

var agent_settings: @import("tag_queue.zig").Settings = .{};
fn agentFrame() !dvui.App.Result {
    var tab: @import("views/tabs.zig").Tab = .agent;
    @import("views/agent.zig").page(&tab, &agent_settings);
    return .ok;
}
fn agentTap(tag: []const u8) !void {
    try dvui.testing.moveTo(tag);
    try dvui.testing.click(.left);
    try dvui.testing.settle(agentFrame);
}
const http = @import("core").vfs.http;
var agent_done: http.DoneFn = undefined;
fn agentRequest(_: *anyopaque, _: std.mem.Allocator, _: http.Request, cb: http.DoneFn, _: ?*anyopaque) @import("core").vfs.Error!http.Job {
    agent_done = cb;
    return .{ .id = 1 };
}
fn agentCancel(_: *anyopaque, _: http.Job) void {}
fn agentPump(_: *anyopaque) void {}
test "Connect shows address key and save; your own agent waits for a saved address" {
    var testing = try dvui.testing.init(.{ .window_size = .{ .w = 390, .h = 844 } });
    defer testing.deinit();
    const yours = @import("agent_settings.zig");
    defer yours.deinit();
    try dvui.testing.settle(agentFrame);
    try agentTap("heronin-agent-1");
    try std.testing.expectEqual(.ours, agent_settings.agent);
    yours.allocator = std.testing.allocator;
    yours.load(.{ .ptr = &agent_settings, .vtable = &.{ .request = agentRequest, .cancel = agentCancel, .pump = agentPump } }, "");
    agent_done(null, .{ .status = 200, .body = try std.testing.allocator.dupe(u8, "{\"address\":\"https://agent.example.invalid\",\"wrap\":true,\"model\":\"m\",\"has_key\":true}") });
    try agentTap("heronin-agent-1");
    try std.testing.expectEqual(.yours, agent_settings.agent);
    try dvui.testing.expectVisible("heronin-connect-model");
}

test "signed out Agent page shows Sign in without duplicate widget ids" {
    var testing = try dvui.testing.init(.{ .window_size = .{ .w = 390, .h = 844 } });
    defer testing.deinit();
    const sign = @import("sign_in.zig");
    defer sign.account.deinit();
    sign.account.state = .signed_out;
    try dvui.testing.settle(struct {
        fn frame() !dvui.App.Result {
            var tab: @import("views/tabs.zig").Tab = .agent;
            var settings: @import("tag_queue.zig").Settings = .{};
            @import("views/agent.zig").page(&tab, &settings);
            return .ok;
        }
    }.frame);
    try dvui.testing.expectVisible("heronin-sign-in");
    try dvui.testing.expectVisible("heronin-tabs");
}

var rename_row: usize = 0;
var rename_member: usize = 0;
fn renameChecks() !dvui.App.Result {
    _ = try frame();
    const view = @import("views/places.zig");
    const groups = view.groups(&state);
    for (groups.clusters, 0..) |c, i| if (c.place == null) {
        rename_row = i;
        rename_member = groups.items[c.members[0]];
        const places = library.places_client;
        places.names.answers = try places.names.arena.allocator().alloc(places.Answer, 1);
        places.names.answers[0] = .{ .lat = c.lat, .lon = c.lon };
        places.done(&places.names, .{ .status = 200, .body = try places.names.arena.allocator().dupe(u8, "{\"name\":\"Sea Mount\"}") });
        break;
    };
    return .ok;
}
test "rename unnamed and saved places without selecting; cancel and near prefill" {
    var testing = try dvui.testing.init(.{ .window_size = .{ .w = 390, .h = 844 } });
    defer testing.deinit();
    fake = try .init(std.testing.allocator);
    defer fake.deinit();
    state = .{};
    defer state.arena.deinit();
    defer library.places_client.names.deinit();
    queue = .{ .allocator = std.testing.allocator };
    defer queue.deinit();
    fake.store().list(null, 60, &state, library.State.listed);
    fake.store().places(&state, library.State.placed);
    fake.store().pump();
    current = .species;
    state.segment = .by_place;
    _ = try dvui.testing.step(renameChecks);
    try dvui.testing.settle(frame);
    var tag_buf: [50]u8 = undefined;
    const tag = try std.fmt.bufPrint(&tag_buf, "heronin-rename-{d}", .{rename_row});
    try tap(tag);
    try tap("heronin-rename-save");
    fake.store().pump();
    try dvui.testing.settle(frame);
    try std.testing.expectEqualStrings("Sea Mount", state.places[2].name);
    try tap(tag);
    try tap("heronin-rename-entry");
    try dvui.testing.pressKey(.a, .lcontrol);
    try dvui.testing.writeText("Point");
    try dvui.testing.settle(frame);
    try tap("heronin-rename-save");
    try std.testing.expectEqual(null, state.at_cluster);
    try std.testing.expectEqual(.by_place, state.segment);
    fake.store().pump();
    try dvui.testing.settle(frame);
    try std.testing.expectEqualStrings("Point", state.places[2].name);
    try std.testing.expectEqualStrings("Point", library.logic.placeText(@import("model").places.placeOf(state.items[rename_member].photo, state.photos), state.places, null).?);
    current = .library;
    state.open = state.items[rename_member].photo.id;
    try dvui.testing.settle(frame);
    state.close();
    current = .species;
    try dvui.testing.settle(frame);
    try tap("heronin-rename-0");
    try tap("heronin-rename-entry");
    try dvui.testing.pressKey(.a, .lcontrol);
    try dvui.testing.writeText("Garden");
    try dvui.testing.settle(frame);
    try tap("heronin-rename-save");
    fake.store().pump();
    try dvui.testing.settle(frame);
    try std.testing.expectEqual(@as(usize, 3), state.places.len);
    try std.testing.expectEqual(@as(u16, 1), state.places[0].id);
    try std.testing.expectEqualStrings("Garden", state.places[0].name);
    try tap("heronin-rename-0");
    try tap("heronin-rename-cancel");
    fake.store().pump();
    try std.testing.expectEqualStrings("Garden", fake.saved[0].name);
}
