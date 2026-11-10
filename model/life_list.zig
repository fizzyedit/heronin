const std = @import("std");
const model = @import("model.zig");
/// Photo ids borrow the input and must not outlive its frame.
pub const Entry = struct { species: model.Species, first_at: ?i64, first: []const u8, best: []const u8, count: u32 };
pub fn counted(photo: model.Photo, tags: []const model.Tag) ?model.Species {
    if (photo.state != .tagged or tags.len == 0 or tags[0].accepted == .rejected) return null;
    return model.species.find(tags[0].species);
}
pub fn build(a: std.mem.Allocator, photos: []const model.Photo, tags: []const []const model.Tag) ![]Entry {
    var entries: [model.species.table.len]Entry = undefined;
    var len: usize = 0;
    for (model.species.table) |species| {
        var first: ?usize = null;
        var best: usize = 0;
        var count: u32 = 0;
        for (photos, tags, 0..) |photo, ts, i| {
            const s = counted(photo, ts) orelse continue;
            if (!std.mem.eql(u8, s.code, species.code)) continue;
            if (first == null) {
                first = i;
                best = i;
            }
            const f = photos[first.?];
            if (dateOrder(photo.taken_at, f.taken_at) == .lt or (photo.taken_at == f.taken_at and std.mem.order(u8, photo.id, f.id) == .lt)) first = i;
            const b = photos[best];
            if (better(photo, ts[0], b, tags[best][0])) best = i;
            count += 1;
        }
        if (first) |f| {
            entries[len] = .{ .species = species, .first_at = photos[f].taken_at, .first = photos[f].id, .best = photos[best].id, .count = count };
            len += 1;
        }
    }
    return a.dupe(Entry, entries[0..len]);
}
// Null dates sort last for first; best handles null as oldest explicitly.
fn dateOrder(a: ?i64, b: ?i64) std.math.Order {
    if (a == null) return if (b == null) .eq else .gt;
    if (b == null) return .lt;
    return std.math.order(a.?, b.?);
}
pub fn notYet(entries: []const Entry, out: []model.Species) []model.Species {
    var n: usize = 0;
    for (model.species.table) |s| {
        for (entries) |e| {
            if (std.mem.eql(u8, e.species.code, s.code)) break;
        } else {
            out[n] = s;
            n += 1;
        }
    }
    return out[0..n];
}
pub fn newThisWeek(entries: []const Entry, now: i64, out: []usize) []usize {
    var n: usize = 0;
    for (entries, 0..) |e, i| {
        const at = e.first_at orelse continue;
        const age = @as(i128, now) - at;
        if (age < 0 or age > 7 * 86400) continue;
        var j = n;
        while (j > 0 and entries[out[j - 1]].first_at.? < at) : (j -= 1) out[j] = out[j - 1];
        out[j] = i;
        n += 1;
    }
    return out[0..n];
}

fn better(photo: model.Photo, tag: model.Tag, b_photo: model.Photo, b_tag: model.Tag) bool {
    if (tag.confidence != b_tag.confidence) return tag.confidence > b_tag.confidence;
    if (photo.taken_at != b_photo.taken_at) return if (photo.taken_at) |at| b_photo.taken_at == null or at > b_photo.taken_at.? else false;
    return std.mem.lessThan(u8, photo.id, b_photo.id);
}
