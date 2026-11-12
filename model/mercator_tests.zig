const std = @import("std");
const m = @import("model").mercator;
const t = std.testing;
const Point = struct { lat: f64, lon: f64 };
test "mercator world pixels and OSM tile" {
    try t.expectEqualDeep(m.Px{ .x = 1024, .y = 1024 }, m.worldPx(3, 0, 0));
    const p = m.worldPx(12, 60.1234, -29.8765);
    try t.expectEqual(@as(f64, 1708), @floor(p.x / 256));
    try t.expectEqual(@as(f64, 1186), @floor(p.y / 256));
    try t.expectApproxEqAbs(@as(f64, 0), m.worldPx(3, 90, 0).y, 0.00001);
}
test "mercator fit chooses zoom and box center" {
    const one = [_]Point{.{ .lat = 60.1234, .lon = -29.8765 }};
    const fitted = m.fit(&one, 390, 600, 32);
    try t.expectEqual(@as(u5, 16), fitted.z);
    try t.expectEqualDeep(m.worldPx(16, one[0].lat, one[0].lon), fitted.center);
    try t.expectEqual(@as(u5, 3), m.fit(&[_]Point{}, 390, 600, 32).z);
    const pair = [_]Point{ .{ .lat = 60, .lon = -30 }, .{ .lat = 60, .lon = -29.99 } };
    const f = m.fit(&pair, 390, 600, 32);
    const span = m.worldPx(f.z, pair[1].lat, pair[1].lon).x - m.worldPx(f.z, pair[0].lat, pair[0].lon).x;
    try t.expect(span + 64 <= 390 and 2 * span + 64 > 390);
    const wide = [_]Point{ .{ .lat = 0, .lon = -179.5 }, .{ .lat = 0, .lon = 179.5 } };
    const across = m.fit(&wide, 390, 600, 32);
    try t.expectEqual(@as(u5, 3), across.z);
    try t.expectEqual(@as(f64, 1024), across.center.x);
}
test "mercator tile ranges clamp at world edges" {
    try t.expectEqualDeep(m.Range{ .x0 = 1, .x1 = 3, .y0 = 0, .y1 = 2 }, m.tiles(3, 300, 0, 500, 600));
    try t.expectEqualDeep(m.Range{ .x0 = 0, .x1 = 0, .y0 = 7, .y1 = 7 }, m.tiles(3, -900, 4000, 100, 100));
}
