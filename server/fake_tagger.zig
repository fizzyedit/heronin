const std = @import("std");
const model = @import("model");
const wire = @import("tagger.zig");
pub const Fake = struct {
    fail: bool = false,
    pub fn tagger(self: *Fake) wire.Tagger {
        return .{ .ctx = self, .tagFn = tag };
    }
    fn tag(ctx: *anyopaque, allocator: std.mem.Allocator, request: wire.Request) !wire.Answer {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        if (self.fail) return error.Unavailable;
        const fixtures = try std.json.parseFromSlice(std.json.Value, allocator, @embedFile("fake_tags"), .{ .allocate = .alloc_always });
        defer fixtures.deinit();
        const hex = std.fmt.bytesToHex(request.md5.bytes, .lower);
        if (fixtures.value.object.get(&hex)) |value| return .{ .candidates = try std.json.parseFromValueLeaky([]wire.Candidate, allocator, value, .{ .allocate = .alloc_always }), .model = "fake" };
        const candidates = try allocator.alloc(wire.Candidate, 1);
        const seed = request.md5.bytes[0];
        candidates[0] = .{ .species = model.species.table[seed % model.species.table.len].code, .confidence = 0.5 + @as(f32, @floatFromInt(seed % 46)) / 100 };
        return .{ .candidates = candidates, .model = "fake" };
    }
};
