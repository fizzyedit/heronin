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

test "namedPlace covers photo GPS points" {
    var p = photo();
    p.fix = .{ .lat = 0, .lon = 0, .accuracy_m = 5, .at = 10 };
    try std.testing.expectEqual(null, if (p.place) |point| places.namedPlace(point, &saved) else null);
    p.place = .{ .lat = 0, .lon = 0 };
    try std.testing.expectEqualStrings("Wetland", places.namedPlace(p.place.?, &saved).?.name);
    p.place = .{ .lat = 0.01, .lon = 0 };
    try std.testing.expectEqual(null, places.namedPlace(p.place.?, &saved));
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
    p.place = .{ .lat = 0.1, .lon = 0.2 };
    p.fix = .{ .lat = 0.2, .lon = 0.3, .accuracy_m = 12, .at = 1700000000 };
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
    p.fix = .{ .lat = 0.3, .lon = 0.4, .accuracy_m = 20, .at = 8_800 };
    var near = photo();
    near.place = .{ .lat = 0.1, .lon = 0.2 };
    near.taken_at = 10_540;
    p.place = .{ .lat = 0.5, .lon = 0.6 };
    try std.testing.expectEqualDeep(places.Located{ .lat = 0.5, .lon = 0.6, .src = .photo }, places.placeOf(p, &.{near}).?);
    p.place = null;
    try std.testing.expectEqualDeep(places.Located{ .lat = 0.1, .lon = 0.2, .src = .nearby }, places.placeOf(p, &.{near}).?);
    near.taken_at = 10_660;
    try std.testing.expectEqual(places.Source.phone, places.placeOf(p, &.{near}).?.src);
    var earlier = near;
    earlier.taken_at = 9_900;
    earlier.place = .{ .lat = 0.7, .lon = 0.8 };
    near.taken_at = 10_200;
    try std.testing.expectEqual(@as(f64, 0.7), places.placeOf(p, &.{ near, earlier }).?.lat);
    near.taken_at = 10_100;
    try std.testing.expectEqual(@as(f64, 0.7), places.placeOf(p, &.{ near, earlier }).?.lat);
    try std.testing.expectEqual(@as(f64, 0.7), places.placeOf(p, &.{ earlier, near }).?.lat);
    earlier.place = null;
    earlier.fix = p.fix;
    try std.testing.expectEqual(@as(f64, 0.1), places.placeOf(p, &.{ earlier, near }).?.lat);
    try std.testing.expectEqual(places.Source.phone, places.placeOf(p, &.{earlier}).?.src);
    p.fix.?.at = 7_600;
    try std.testing.expectEqual(null, places.placeOf(p, &.{}));
    p.fix.?.at = 8_800;
    p.fix.?.accuracy_m = 500;
    try std.testing.expectEqual(null, places.placeOf(p, &.{}));
    p.fix.?.accuracy_m = 20;
    p.taken_at = null;
    try std.testing.expectEqual(null, places.placeOf(p, &.{near}));
    p.place = .{ .lat = 0.5, .lon = 0.6 };
    try std.testing.expectEqual(places.Source.photo, places.placeOf(p, &.{near}).?.src);
}

fn freeClusters(cs: []places.Cluster) void {
    for (cs) |c| std.testing.allocator.free(c.members);
    std.testing.allocator.free(cs);
}
fn clusterPoint(lat: f64, lon: f64, at: ?i64, id: []const u8) places.Point {
    return .{ .lat = lat, .lon = lon, .at = at, .id = id };
}
test "cluster joins nearby points, separates distant ones and crosses antimeridian" {
    const close = try places.cluster(std.testing.allocator, &.{ clusterPoint(0, 0, 1, "a"), clusterPoint(0.00045, 0, 2, "b") }, &.{}, 150);
    defer freeClusters(close);
    try std.testing.expectEqual(@as(usize, 1), close.len);
    const far = try places.cluster(std.testing.allocator, &.{ clusterPoint(0, 0, 1, "a"), clusterPoint(0.0045, 0, 2, "b") }, &.{}, 150);
    defer freeClusters(far);
    try std.testing.expectEqual(@as(usize, 2), far.len);
    const seam = try places.cluster(std.testing.allocator, &.{ clusterPoint(0.0105, 179.9995, 1, "a"), clusterPoint(0.0105, -179.9995, 2, "b") }, &.{}, 150);
    defer freeClusters(seam);
    try std.testing.expectEqual(@as(usize, 1), seam.len);
    try std.testing.expect(@abs(seam[0].lon) > 179.9);
}
test "cluster named coverage wins over nearer unnamed centre and retains saved centre" {
    const ps = [_]places.Point{ clusterPoint(0.0015, 0, 1, "a"), clusterPoint(0.0013, 0, 2, "b") };
    const cs = try places.cluster(std.testing.allocator, &ps, saved[0..1], 150);
    defer freeClusters(cs);
    try std.testing.expectEqual(@as(usize, 2), cs.len);
    try std.testing.expectEqual(@as(?u16, 1), cs[0].place);
    try std.testing.expectEqual(@as(f64, 0), cs[0].lat);
    try std.testing.expectEqual(@as(f64, 0), cs[0].lon);
}
test "cluster null dates follow dated points and shuffles preserve members and means" {
    const ps = [_]places.Point{ clusterPoint(0, 0, 1, "b"), clusterPoint(0.0024, 0, 2, "c"), clusterPoint(0.0011, 0, null, "a") };
    const expected = try places.cluster(std.testing.allocator, &ps, &.{}, 150);
    defer freeClusters(expected);
    try std.testing.expectEqual(@as(u32, 2), expected[0].count);
    try std.testing.expectEqualStrings("b", ps[expected[0].members[0]].id);
    try std.testing.expectEqualStrings("a", ps[expected[0].members[1]].id);
    for ([_][3]usize{ .{ 2, 0, 1 }, .{ 1, 2, 0 }, .{ 0, 2, 1 } }) |order| {
        const shuffled = [_]places.Point{ ps[order[0]], ps[order[1]], ps[order[2]] };
        const actual = try places.cluster(std.testing.allocator, &shuffled, &.{}, 150);
        defer freeClusters(actual);
        try std.testing.expectEqual(expected.len, actual.len);
        for (expected, actual) |e, a| {
            try std.testing.expectApproxEqAbs(e.lat, a.lat, 1e-9);
            try std.testing.expectApproxEqAbs(e.lon, a.lon, 1e-9);
            try std.testing.expectEqual(e.count, a.count);
            try std.testing.expectEqual(e.place, a.place);
            for (e.members, a.members) |em, am| try std.testing.expectEqualStrings(ps[em].id, shuffled[am].id);
        }
    }
}
test "cluster sorts by count then named and naming a tight group preserves its count" {
    const ps = [_]places.Point{ clusterPoint(0.01, 0, 1, "a"), clusterPoint(0.0101, 0, 2, "b"), clusterPoint(0.0102, 0, 3, "c"), clusterPoint(0, 0, 4, "d"), clusterPoint(0.02, 0, 0, "e") };
    const cs = try places.cluster(std.testing.allocator, &ps, saved[0..1], 150);
    defer freeClusters(cs);
    try std.testing.expectEqual(@as(u32, 3), cs[0].count);
    try std.testing.expectEqual(@as(?u16, 1), cs[1].place);
    try std.testing.expectEqual(@as(?u16, null), cs[2].place);
    const named = [_]model.Place{.{ .id = 3, .name = "Point", .lat = cs[0].lat, .lon = cs[0].lon }};
    const again = try places.cluster(std.testing.allocator, ps[0..3], &named, 150);
    defer freeClusters(again);
    try std.testing.expectEqual(@as(u32, 3), again[0].count);
    try std.testing.expectEqual(@as(?u16, 3), again[0].place);
}
