const std = @import("std");
const model = @import("model");
const places = model.places;
const species = model.species;
const Point = struct { lat: f64, lon: f64 };
const saved = [_]model.Place{
    .{ .id = 1, .name = "Wetland", .lat = 0, .lon = 0 },
    .{ .id = 2, .name = "Pond", .lat = 0.001, .lon = 0 },
};

fn photo() model.Photo {
    return .{ .id = "bird", .name = "bird.jpg", .md5 = .{ .bytes = @splat(0) }, .w = 1, .h = 1, .bytes = 1 };
}

fn roundTrip(comptime T: type, value: T) !void {
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, value, .{});
    defer std.testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(T, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualDeep(value, parsed.value);
}

test "distanceM measures latitude and crosses the antimeridian" {
    try std.testing.expectApproxEqAbs(@as(f64, 111.2), places.distanceM(Point{ .lat = 0, .lon = 0 }, Point{ .lat = 0.001, .lon = 0 }), 0.5);
    try std.testing.expect(places.distanceM(Point{ .lat = 0, .lon = 179.9995 }, Point{ .lat = 0, .lon = -179.9995 }) < 200);
    try std.testing.expectApproxEqAbs(@as(f64, std.math.pi * 6371008.8), places.distanceM(Point{ .lat = 0, .lon = 0 }, Point{ .lat = 0, .lon = 180 }), 0.01);
}

test "namedPlace uses radius and selects the nearest covering place" {
    try std.testing.expectEqual(@as(u16, 1), places.namedPlace(Point{ .lat = 0.00134, .lon = 0 }, saved[0..1]).?.id);
    try std.testing.expectEqual(null, places.namedPlace(Point{ .lat = 0.00136, .lon = 0 }, saved[0..1]));
    const point: model.Fix = .{ .lat = 0.0009, .lon = 0, .accuracy_m = 5, .at = 10 };
    try std.testing.expectEqual(@as(u16, 2), places.namedPlace(point, &saved).?.id);
    try std.testing.expectEqual(null, places.namedPlace(point, &.{}));
    try std.testing.expectEqual(@as(f64, 0), places.distanceM(saved[0], saved[0]));
}

test "placeLabel uses only photo GPS and names covered points" {
    var p = photo();
    p.fix = .{ .lat = 0, .lon = 0, .accuracy_m = 5, .at = 10 };
    try std.testing.expectEqual(null, places.placeLabel(p, &saved));
    p.place = .{ .lat = 0, .lon = 0 };
    try std.testing.expectEqualStrings("Wetland", places.placeLabel(p, &saved).?);
    p.place = .{ .lat = 1, .lon = 0 };
    try std.testing.expectEqualStrings("Unnamed place", places.placeLabel(p, &saved).?);
}

test "namedPlace includes the radius boundary and skips nearer uncovered places" {
    const point = Point{ .lat = 0, .lon = 0 };
    const candidates = [_]model.Place{
        .{ .id = 1, .name = "Small", .lat = 0.0001, .lon = 0, .radius_m = 1 },
        .{ .id = 2, .name = "Large", .lat = 0.001, .lon = 0, .radius_m = 200 },
    };
    try std.testing.expectEqual(@as(u16, 2), places.namedPlace(point, &candidates).?.id);
    const boundary = [_]model.Place{.{ .id = 3, .name = "Origin", .lat = 0, .lon = 0, .radius_m = 0 }};
    try std.testing.expectEqual(@as(u16, 3), places.namedPlace(point, &boundary).?.id);
}

test "Photo with phone fix and saved Place round-trip through JSON" {
    var p = photo();
    p.place = .{ .lat = 41.1, .lon = -87.2 };
    p.fix = .{ .lat = 41.2, .lon = -87.3, .accuracy_m = 12, .at = 1700000000 };
    try roundTrip(model.Photo, p);
    try roundTrip(model.Place, saved[0]);
    try std.testing.expectEqual(null, photo().fix);
}

test "species table contains twelve unique species available through find" {
    try std.testing.expectEqual(@as(usize, 12), species.table.len);
    for (species.table, 0..) |entry, i| {
        try std.testing.expectEqualDeep(entry, species.find(entry.code).?);
        for (species.table[0..i]) |previous| try std.testing.expect(!std.mem.eql(u8, entry.code, previous.code));
    }
    try std.testing.expectEqualStrings("Great Blue Heron", species.find("grbher3").?.common);
    try std.testing.expectEqualStrings("Pandion haliaetus", species.find("osprey").?.scientific);
    try std.testing.expectEqual(null, species.find("unknown"));
}

test "placeOf prefers own GPS, then nearest own neighbour GPS, then an accurate timely fix" {
    var p = photo();
    try std.testing.expectEqual(null, places.placeOf(p, &.{}));
    p.taken_at = 10_000;
    p.fix = .{ .lat = 3, .lon = 4, .accuracy_m = 20, .at = 8_800 };
    var near = photo();
    near.place = .{ .lat = 1, .lon = 2 };
    near.taken_at = 10_540;
    p.place = .{ .lat = 5, .lon = 6 };
    try std.testing.expectEqualDeep(places.Located{ .lat = 5, .lon = 6, .src = .photo }, places.placeOf(p, &.{near}).?);
    p.place = null;
    try std.testing.expectEqualDeep(places.Located{ .lat = 1, .lon = 2, .src = .nearby }, places.placeOf(p, &.{near}).?);
    near.taken_at = 10_660;
    try std.testing.expectEqual(places.Source.phone, places.placeOf(p, &.{near}).?.src);
    var earlier = near;
    earlier.taken_at = 9_900;
    earlier.place = .{ .lat = 7, .lon = 8 };
    near.taken_at = 10_200;
    try std.testing.expectEqual(@as(f64, 7), places.placeOf(p, &.{ near, earlier }).?.lat);
    near.taken_at = 10_100;
    try std.testing.expectEqual(@as(f64, 7), places.placeOf(p, &.{ near, earlier }).?.lat);
    try std.testing.expectEqual(@as(f64, 7), places.placeOf(p, &.{ earlier, near }).?.lat);
    earlier.place = null;
    earlier.fix = p.fix;
    try std.testing.expectEqual(@as(f64, 1), places.placeOf(p, &.{ earlier, near }).?.lat);
    try std.testing.expectEqual(places.Source.phone, places.placeOf(p, &.{earlier}).?.src);
    p.fix.?.at = 7_600;
    try std.testing.expectEqual(null, places.placeOf(p, &.{}));
    p.fix.?.at = 8_800;
    p.fix.?.accuracy_m = 500;
    try std.testing.expectEqual(null, places.placeOf(p, &.{}));
    p.fix.?.accuracy_m = 20;
    p.taken_at = null;
    try std.testing.expectEqual(null, places.placeOf(p, &.{near}));
    p.place = .{ .lat = 5, .lon = 6 };
    try std.testing.expectEqual(places.Source.photo, places.placeOf(p, &.{near}).?.src);
}
