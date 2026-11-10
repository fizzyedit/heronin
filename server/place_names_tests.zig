const std = @import("std");
const G = @import("place_names.zig").Gazetteer;
const t = std.testing;
pub fn fixture(a: std.mem.Allocator) !G {
    var dir = t.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "sea.txt", .data = @embedFile("gazetteer_fixture") });
    return G.load(a, t.io, try dir.dir.realPathFileAlloc(t.io, "sea.txt", a));
}
test "gazetteer range preference classes UTF8 and antimeridian" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const g = try fixture(arena.allocator());
    try t.expectEqual(@as(usize, 7), g.features.len);
    try t.expectEqualStrings("Edge", g.nearest(0, 0).?);
    try t.expect(g.nearest(0, 0.09) == null);
    try t.expectEqualStrings("Sea Mount", g.nearest(60, -30).?);
    try t.expectEqualStrings("Other Town", g.nearest(60, -29.9).?);
    try t.expectEqualStrings("Dateline", g.nearest(0, -179.99).?);
    for (g.features) |f| if (f.lon > 0.08 and f.lon < 0.1) {
        try t.expectEqual(@as(usize, 39), f.name.len);
        try t.expect(std.unicode.utf8ValidateSlice(f.name));
    };
    try t.expect((try G.load(arena.allocator(), t.io, "absent-gazetteer-file.txt")).nearest(0, 0) == null);
}
