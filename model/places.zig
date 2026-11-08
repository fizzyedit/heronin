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
