const std = @import("std");
const model = @import("model.zig");

pub fn distanceM(a: anytype, b: anytype) f64 {
    const radians = std.math.pi / 180.0;
    const dlat = (b.lat - a.lat) * radians;
    const dlon = (b.lon - a.lon) * radians;
    const h = std.math.pow(f64, @sin(dlat / 2), 2) + @cos(a.lat * radians) * @cos(b.lat * radians) * std.math.pow(f64, @sin(dlon / 2), 2);
    return 2 * 6371008.8 * std.math.asin(@sqrt(std.math.clamp(h, 0, 1)));
}

pub fn namedPlace(point: anytype, saved: []const model.Place) ?model.Place {
    var nearest: ?model.Place = null;
    var best = std.math.inf(f64);
    for (saved) |place| {
        const distance = distanceM(point, place);
        if (distance <= place.radius_m and distance < best) {
            nearest = place;
            best = distance;
        }
    }
    return nearest;
}

pub fn placeLabel(photo: model.Photo, saved: []const model.Place) ?[]const u8 {
    const point = photo.place orelse return null;
    return if (namedPlace(point, saved)) |place| place.name else "Unnamed place";
}

pub const Source = enum { photo, nearby, phone };
pub const Located = struct { lat: f64, lon: f64, src: Source };
pub fn placeOf(photo: model.Photo, others: []const model.Photo) ?Located {
    if (photo.place) |p| return .{ .lat = p.lat, .lon = p.lon, .src = .photo };
    const at = photo.taken_at orelse return null;
    var nearest: ?model.Photo = null;
    var best: u128 = 601;
    for (others) |other| {
        if (other.place == null) continue;
        const time = other.taken_at orelse continue;
        const delta = @abs(@as(i128, at) - time);
        if (delta < best or (delta == best and nearest != null and time < nearest.?.taken_at.?)) {
            nearest = other;
            best = delta;
        }
    }
    if (nearest) |other| {
        const p = other.place.?;
        return .{ .lat = p.lat, .lon = p.lon, .src = .nearby };
    }
    if (photo.fix) |fix| {
        if (fix.accuracy_m <= 200 and @abs(@as(i128, at) - fix.at) <= 1800) return .{ .lat = fix.lat, .lon = fix.lon, .src = .phone };
    }
    return null;
}

pub const Point = struct { lat: f64, lon: f64, at: ?i64, id: []const u8 };
pub const Cluster = struct { lat: f64, lon: f64, count: u32, place: ?u16, members: []usize };
fn pointBefore(points: []const Point, a: usize, b: usize) bool {
    const x = points[a];
    const y = points[b];
    if (x.at != y.at) return if (x.at) |at| y.at == null or at < y.at.? else false;
    return std.mem.order(u8, x.id, y.id) == .lt;
}
pub fn cluster(a: std.mem.Allocator, points: []const Point, saved: []const model.Place, radius_m: f64) ![]Cluster {
    const order = try a.alloc(usize, points.len);
    defer a.free(order);
    for (order, 0..) |*index, i| index.* = i;
    std.mem.sort(usize, order, points, pointBefore);
    var out: std.ArrayList(Cluster) = .empty;
    errdefer {
        for (out.items) |c| a.free(c.members);
        out.deinit(a);
    }
    for (order) |index| {
        const p = points[index];
        const named = namedPlace(p, saved);
        var chosen: ?usize = null;
        var best = std.math.inf(f64);
        for (out.items, 0..) |c, i| {
            if (named) |place| {
                if (c.place == place.id) {
                    chosen = i;
                    break;
                }
            } else if (c.place == null) {
                const d = distanceM(p, c);
                if (d <= radius_m and d < best) {
                    best = d;
                    chosen = i;
                }
            }
        }
        if (chosen == null) {
            const members = try a.alloc(usize, 0);
            errdefer a.free(members);
            try out.append(a, .{ .lat = if (named) |n| n.lat else p.lat, .lon = if (named) |n| n.lon else p.lon, .count = 0, .place = if (named) |n| n.id else null, .members = members });
            chosen = out.items.len - 1;
        }
        const c = &out.items[chosen.?];
        c.members = try a.realloc(c.members, c.members.len + 1);
        c.members[c.members.len - 1] = index;
        c.count += 1;
        if (c.place == null) {
            var x: f64 = 0;
            var y: f64 = 0;
            var z: f64 = 0;
            for (c.members) |m| {
                const lat = points[m].lat * std.math.pi / 180;
                const lon = points[m].lon * std.math.pi / 180;
                x += @cos(lat) * @cos(lon);
                y += @cos(lat) * @sin(lon);
                z += @sin(lat);
            }
            c.lat = std.math.atan2(z, @sqrt(x * x + y * y)) * 180 / std.math.pi;
            c.lon = std.math.atan2(y, x) * 180 / std.math.pi;
        }
    }
    std.mem.sort(Cluster, out.items, points, struct {
        fn less(ps: []const Point, x: Cluster, y: Cluster) bool {
            if (x.count != y.count) return x.count > y.count;
            if ((x.place == null) != (y.place == null)) return x.place != null;
            return pointBefore(ps, x.members[0], y.members[0]);
        }
    }.less);
    return out.toOwnedSlice(a);
}
