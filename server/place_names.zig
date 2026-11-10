const std = @import("std");
pub const Gazetteer = struct {
    pub const Feature = struct { lat: f32, lon: f32, class: u8, name: []const u8, order: usize };
    features: []const Feature = &.{},
    pub fn load(a: std.mem.Allocator, io: std.Io, path: []const u8) !Gazetteer {
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.info("no gazetteer, place names off", .{});
                return .{};
            },
            else => return err,
        };
        defer file.close(io);
        var buffer: [8192]u8 = undefined;
        var reader = file.reader(io, &buffer);
        var line: std.Io.Writer.Allocating = .init(a);
        defer line.deinit();
        var features: std.ArrayList(Feature) = .empty;
        while (true) {
            line.clearRetainingCapacity();
            const end = blk: {
                _ = reader.interface.streamDelimiter(&line.writer, '\n') catch |err| switch (err) {
                    error.EndOfStream => break :blk true,
                    else => return err,
                };
                reader.interface.toss(1);
                break :blk false;
            };
            var columns = std.mem.splitScalar(u8, std.mem.trimEnd(u8, line.written(), "\r"), '\t');
            var fields: [7][]const u8 = undefined;
            for (&fields) |*field| field.* = columns.next() orelse break else {
                const lat = std.fmt.parseFloat(f32, fields[4]) catch continue;
                const lon = std.fmt.parseFloat(f32, fields[5]) catch continue;
                if (!std.math.isFinite(lat) or !std.math.isFinite(lon) or @abs(lat) > 90 or @abs(lon) > 180 or fields[6].len != 1 or std.mem.indexOfScalar(u8, "PLHT", fields[6][0]) == null or fields[1].len == 0 or !std.unicode.utf8ValidateSlice(fields[1])) continue;
                var len = @min(fields[1].len, 40);
                while (!std.unicode.utf8ValidateSlice(fields[1][0..len])) len -= 1;
                try features.append(a, .{ .lat = lat, .lon = lon, .class = fields[6][0], .name = try a.dupe(u8, fields[1][0..len]), .order = features.items.len });
            }
            if (end) break;
        }
        std.mem.sort(Feature, features.items, {}, struct {
            fn less(_: void, x: Feature, y: Feature) bool {
                return x.lat < y.lat;
            }
        }.less);
        return .{ .features = try features.toOwnedSlice(a) };
    }
    pub fn nearest(self: Gazetteer, lat: f64, lon: f64) ?[]const u8 {
        var lo: usize = 0;
        var hi = self.features.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.features[mid].lat < lat - 0.046) lo = mid + 1 else hi = mid;
        }
        var found = [_]?Feature{ null, null };
        var limits = [_]f64{ 5000, 1000 };
        for (self.features[lo..]) |f| {
            if (f.lat > lat + 0.046) break;
            const d = @import("model").places.distanceM(.{ .lat = lat, .lon = lon }, .{ .lat = @as(f64, f.lat), .lon = @as(f64, f.lon) });
            for (&limits, &found, 0..) |*limit, *best, i| if ((i == 0 or f.class != 'P') and d <= limit.* and (d < limit.* or best.* == null or f.order < best.*.?.order)) {
                limit.* = d;
                best.* = f;
            };
        }
        return if (found[1] orelse found[0]) |f| f.name else null;
    }
};
