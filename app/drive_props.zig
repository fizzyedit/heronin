const std = @import("std");
const model = @import("model");
const Tag = model.Tag;
const fmt = std.fmt.allocPrint;
const alternates = [_][]const u8{ "alt1", "alt2", "alt3", "alt4" };
pub const Decoded = struct {
    tags: []Tag = &.{},
    state: ?model.Photo.State = null,
    favorite: bool = false,
};
fn cut(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = @min(s.len, max);
    const end = n -| 3;
    while (n > end and !std.unicode.utf8ValidateSlice(s[0..n])) : (n -= 1) {}
    return s[0..n];
}
pub fn encodeTags(
    a: std.mem.Allocator,
    tags: []const Tag,
    state: model.Photo.State,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const tmp = arena.allocator();
    var obj: std.json.ObjectMap = .{};
    var keys = std.mem.tokenizeScalar(u8, "sp cf src acc at md bx dt nt alt1 alt2 alt3 alt4", ' ');
    while (keys.next()) |key| {
        try obj.put(tmp, key, .null);
    }
    try obj.put(tmp, "st", .{ .string = @tagName(state) });
    if (tags.len > 0) {
        const t = tags[0];
        try obj.put(tmp, "sp", .{ .string = t.species });
        const cf = try fmt(tmp, "{d:.3}", .{t.confidence});
        try obj.put(tmp, "cf", .{ .string = cf });
        try obj.put(tmp, "src", .{ .string = @tagName(t.source) });
        try obj.put(tmp, "acc", .{ .string = @tagName(t.accepted) });
        try obj.put(tmp, "at", .{ .string = try fmt(tmp, "{d}", .{t.at}) });
        try obj.put(tmp, "md", .{ .string = cut(t.model, 64) });
        if (t.box) |b| {
            const bx = try fmt(tmp, "{d:.3} {d:.3} {d:.3} {d:.3}", .{ b.x, b.y, b.w, b.h });
            try obj.put(tmp, "bx", .{ .string = bx });
        }
        if (t.detail) |s| try obj.put(tmp, "dt", .{ .string = cut(s, 40) });
        if (t.note) |s| try obj.put(tmp, "nt", .{ .string = cut(s, 110) });
        for (tags[1..@min(tags.len, 5)], 0..) |g, i| {
            const values = .{ g.species, g.confidence, @tagName(g.source), @tagName(g.accepted) };
            const alt = try fmt(tmp, "{s} {d:.3} {s} {s}", values);
            try obj.put(tmp, alternates[i], .{ .string = alt });
        }
    }
    return std.json.Stringify.valueAlloc(a, std.json.Value{ .object = obj }, .{});
}
pub fn encodeFavorite(on: bool) []const u8 {
    return if (on) "{\"fav\":\"1\"}" else "{\"fav\":null}";
}
fn string(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}
fn parts(s: []const u8) ?[4][]const u8 {
    var it = std.mem.splitScalar(u8, s, ' ');
    var out: [4][]const u8 = undefined;
    for (&out) |*p| p.* = it.next() orelse return null;
    return if (it.next() == null) out else null;
}
pub fn decode(a: std.mem.Allocator, props: []const u8) Decoded {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), props, .{}) catch
        return .{};
    if (v != .object) return .{};
    const obj = v.object;
    var out: Decoded = .{
        .state = std.meta.stringToEnum(model.Photo.State, string(obj, "st") orelse ""),
        .favorite = std.mem.eql(u8, string(obj, "fav") orelse "", "1"),
    };
    const sp = string(obj, "sp") orelse return out;
    const tags = a.alloc(Tag, 5) catch return out;
    var t: Tag = .{
        .species = a.dupe(u8, sp) catch return out,
        .confidence = std.fmt.parseFloat(f32, string(obj, "cf") orelse "") catch 0,
        .source = std.meta.stringToEnum(Tag.Source, string(obj, "src") orelse "") orelse .ours,
        .accepted = std.meta.stringToEnum(Tag.Accepted, string(obj, "acc") orelse "") orelse .auto,
        .at = std.fmt.parseInt(i64, string(obj, "at") orelse "", 10) catch 0,
        .model = a.dupe(u8, string(obj, "md") orelse "") catch return out,
    };
    if (string(obj, "bx")) |s| box: {
        const p = parts(s) orelse break :box;
        t.box = .{
            .x = std.fmt.parseFloat(f32, p[0]) catch break :box,
            .y = std.fmt.parseFloat(f32, p[1]) catch break :box,
            .w = std.fmt.parseFloat(f32, p[2]) catch break :box,
            .h = std.fmt.parseFloat(f32, p[3]) catch break :box,
        };
    }
    if (string(obj, "dt")) |s| t.detail = a.dupe(u8, s) catch return out;
    if (string(obj, "nt")) |s| t.note = a.dupe(u8, s) catch return out;
    tags[0] = t;
    var n: usize = 1;
    for (alternates) |key| {
        const p = parts(string(obj, key) orelse continue) orelse continue;
        const cf = std.fmt.parseFloat(f32, p[1]) catch continue;
        const src = std.meta.stringToEnum(Tag.Source, p[2]) orelse continue;
        const acc = std.meta.stringToEnum(Tag.Accepted, p[3]) orelse continue;
        tags[n] = .{
            .species = a.dupe(u8, p[0]) catch continue,
            .confidence = cf,
            .source = src,
            .accepted = acc,
            .at = t.at,
            .model = t.model,
        };
        n += 1;
    }
    out.tags = tags[0..n];
    return out;
}
