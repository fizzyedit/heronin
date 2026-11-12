const std = @import("std");
const m = @import("model");
const theme = @import("theme");
fn roundTrip(comptime T: type, value: T) !void {
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, value, .{});
    defer std.testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(T, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualDeep(value, parsed.value);
}
test "Photo JSON round-trip preserves every field and lowercase md5 wire format" {
    const photo: m.Photo = .{ .id = "drive-id", .md5 = .{ .bytes = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 254, 255 } }, .name = "bird.jpg", .taken_at = 1700000000, .place = .{ .lat = 41.1, .lon = -87.2 }, .camera = "Camera", .w = 4000, .h = 3000, .bytes = 123456, .favorite = true, .state = .review };
    try roundTrip(m.Photo, photo);
    try roundTrip(m.Photo, .{ .id = "empty", .md5 = .{ .bytes = @splat(0) }, .name = "empty.jpg", .w = 1, .h = 1, .bytes = 1 });
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, photo.md5, .{});
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("\"000102030405060708090a0b0c0dfeff\"", json);
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(m.Md5));
}
test "md5 rejects invalid wire values" {
    for ([_][]const u8{ "\"abcd\"", "\"000102030405060708090A0B0C0DFEFF\"", "\"z00102030405060708090a0b0c0dfeff\"" }) |json| {
        try std.testing.expectError(error.InvalidCharacter, std.json.parseFromSlice(m.Md5, std.testing.allocator, json, .{}));
    }
}
test "Tag JSON round-trip includes optional annotations and source variants" {
    try roundTrip(m.Tag, .{ .species = "comgal1", .confidence = 0.75, .source = .ours, .accepted = .auto, .at = 1700000001, .model = "bird-v1", .box = .{ .x = 0.1, .y = 0.2, .w = 0.3, .h = 0.4 }, .detail = "adult male", .note = "Distinctive markings" });
    try roundTrip(m.Tag, .{ .species = "amecro", .confidence = 1, .source = .person, .accepted = .person, .at = 1700000002, .model = "" });
}
test "Species JSON round-trip supports seven-character codes" {
    try roundTrip(m.Species, .{ .code = "comgal1", .common = "Common Gallinule", .scientific = "Gallinula galeata", .family = "Rallidae", .order = "Gruiformes" });
}
fn assertOpaque(value: anytype) !void {
    const T = @TypeOf(value);
    if (T == theme.Color) {
        try std.testing.expectEqual(@as(u8, 255), value.a);
    } else switch (@typeInfo(T)) {
        .array => for (value) |item| try assertOpaque(item),
        .@"struct" => inline for (@typeInfo(T).@"struct".field_names) |name| try assertOpaque(@field(value, name)),
        else => @compileError("unexpected palette role"),
    }
}
test "every named palette role is set and opaque" {
    inline for (.{ "paper", "card", "ink", "border", "chip", "tab_off_ink", "orange", "red", "mustard", "brown", "olive", "washes", "tagged", "review", "working", "waiting", "other", "failed" }) |name| try assertOpaque(@field(theme, name));
}
test "light theme maps every DVUI color field to an opaque role" {
    const t = theme.light(.{ .name = "base", .dark = true, .focus = theme.ink, .fill = theme.ink, .text = theme.ink, .border = theme.ink, .font_body = .find(.{ .family = "Nunito", .size = 16 }), .font_title = .find(.{ .family = "Nunito", .size = 16 }), .font_heading = .find(.{ .family = "Nunito", .size = 16 }), .font_mono = .find(.{ .family = "Nunito", .size = 16 }) });
    try std.testing.expect(!t.dark);
    inline for (.{ "fill", "text", "border", "focus" }) |name| try assertOpaque(@field(t, name));
    inline for (.{ "fill_hover", "fill_press", "text_hover", "text_press", "text_select" }) |name| try assertOpaque(@field(t, name).?);
    inline for (.{ "window", "control", "highlight", "err", "app1", "app2", "app3" }) |name| {
        const style = @field(t, name);
        inline for (.{ "fill", "fill_hover", "fill_press", "text", "text_hover", "text_press", "border" }) |field| try assertOpaque(@field(style, field).?);
    }
}

test {
    _ = @import("places_tests.zig");
    _ = @import("life_list_tests.zig");
}
test {
    _ = @import("mercator_tests.zig");
}
