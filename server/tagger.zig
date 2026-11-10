const std = @import("std");
const model = @import("model");
pub const Request = struct {
    md5: model.Md5,
    image: []const u8,
    taken_at: ?i64 = null,
    place: ?struct { lat: f64, lon: f64 } = null,
    agent: model.QueueItem.Agent,
    auto_accept: bool,
};
pub const Response = struct { state: model.Photo.State, tags: []const model.Tag };
pub const Candidate = struct { species: model.SpeciesCode, confidence: f32, box: ?model.Box = null, detail: ?[]const u8 = null, note: ?[]const u8 = null };
pub const Answer = struct { candidates: []Candidate, model: []const u8 };
pub const Tagger = struct {
    ctx: *anyopaque,
    tagFn: *const fn (*anyopaque, std.mem.Allocator, Request) anyerror!Answer,
    pub fn tag(self: Tagger, allocator: std.mem.Allocator, request: Request) !Answer {
        return clean(try self.tagFn(self.ctx, allocator, request));
    }
};
fn cut(text: ?[]const u8, limit: usize) ?[]const u8 {
    const s = text orelse return null;
    var n = @min(s.len, limit);
    while (n < s.len and n > 0 and s[n] & 0xc0 == 0x80) n -= 1;
    return s[0..n];
}
pub fn clean(answer: Answer) Answer {
    var n: usize = 0;
    for (answer.candidates) |candidate| {
        if (model.species.find(candidate.species) == null) continue;
        var c = candidate;
        c.confidence = if (std.math.isNan(c.confidence)) 0 else std.math.clamp(c.confidence, 0, 1);
        c.detail = cut(c.detail, 40);
        c.note = cut(c.note, 110);
        answer.candidates[n] = c;
        n += 1;
    }
    std.mem.sort(Candidate, answer.candidates[0..n], {}, struct {
        fn higher(_: void, x: Candidate, y: Candidate) bool {
            return x.confidence > y.confidence;
        }
    }.higher);
    return .{ .candidates = answer.candidates[0..@min(n, 5)], .model = answer.model };
}
