const std = @import("std");
pub const tile_px = 256;
pub const min_zoom = 3;
pub const max_zoom = 16;
const latitude_limit = 85.0511287798;
pub const Px = struct { x: f64, y: f64 };
pub const Fit = struct { z: u5, center: Px };
pub const Range = struct { x0: u32, x1: u32, y0: u32, y1: u32 };
pub fn worldPx(z: u5, lat: f64, lon: f64) Px {
    const size = tile_px * @as(f64, @floatFromInt(@as(u64, 1) << z));
    const sine = @sin(std.math.clamp(lat, -latitude_limit, latitude_limit) * std.math.pi / 180);
    return .{ .x = (lon + 180) / 360 * size, .y = @max(0, (0.5 - @log((1 + sine) / (1 - sine)) / (4 * std.math.pi)) * size) };
}
pub fn fit(points: anytype, w: f64, h: f64, margin_px: f64) Fit {
    var z: u5 = max_zoom;
    if (points.len == 0) return .{ .z = min_zoom, .center = worldPx(min_zoom, 0, 0) };
    while (true) : (z -= 1) {
        var low = Px{ .x = std.math.inf(f64), .y = std.math.inf(f64) };
        var high = Px{ .x = -std.math.inf(f64), .y = -std.math.inf(f64) };
        for (points) |point| {
            const p = worldPx(z, point.lat, point.lon);
            low = .{ .x = @min(low.x, p.x), .y = @min(low.y, p.y) };
            high = .{ .x = @max(high.x, p.x), .y = @max(high.y, p.y) };
        }
        if (z == min_zoom or (high.x - low.x + 2 * margin_px <= w and high.y - low.y + 2 * margin_px <= h)) return .{ .z = z, .center = .{ .x = (low.x + high.x) / 2, .y = (low.y + high.y) / 2 } };
    }
}
fn edge(z: u5, value: f64) u32 {
    const last = (@as(u64, 1) << z) - 1;
    return @intFromFloat(@min(@as(f64, @floatFromInt(last)), @max(0, @floor(value / tile_px))));
}
pub fn tiles(z: u5, left: f64, top: f64, w: f64, h: f64) Range {
    return .{ .x0 = edge(z, left), .x1 = edge(z, left + w), .y0 = edge(z, top), .y1 = edge(z, top + h) };
}
