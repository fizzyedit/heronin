const std = @import("std");
const model = @import("model");
const wire = @import("tagger.zig");
pub const default_threshold: f32 = 0.85;
// Value-owned storage keeps this decision pure and safe to return without an allocator.
pub const Decision = struct { state: model.Photo.State, tags: [5]model.Tag = undefined, len: usize = 0 };
pub fn decide(agent: model.QueueItem.Agent, ours: ?wire.Answer, yours: ?wire.Answer, threshold: f32, now: i64) Decision {
    var result: Decision = .{ .state = .skipped };
    var tops: [2]?[]const u8 = .{ null, null };
    for ([_]?wire.Answer{ ours, yours }, 0..) |maybe, side| {
        if ((agent == .ours and side == 1) or (agent == .yours and side == 0)) continue;
        const answer = maybe orelse continue;
        var top: f32 = -1;
        for (answer.candidates) |c| {
            if (c.confidence > top) {
                tops[side] = c.species;
                top = c.confidence;
            }
            const tag: model.Tag = .{ .species = c.species, .confidence = c.confidence, .source = if (side == 0) .ours else .yours, .accepted = .auto, .at = now, .model = answer.model, .box = c.box, .detail = c.detail, .note = c.note };
            var pos: usize = 0;
            while (pos < result.len and !std.mem.eql(u8, result.tags[pos].species, c.species)) : (pos += 1) {}
            if (pos < result.len and result.tags[pos].confidence >= c.confidence) continue;
            if (pos == result.len) {
                if (result.len < 5) result.len += 1 else {
                    if (c.confidence <= result.tags[4].confidence) continue;
                    pos = 4;
                }
            }
            result.tags[pos] = tag;
            while (pos > 0 and result.tags[pos].confidence > result.tags[pos - 1].confidence) : (pos -= 1) std.mem.swap(model.Tag, &result.tags[pos], &result.tags[pos - 1]);
        }
    }
    const partial = agent == .both and (ours == null or yours == null);
    const disagree = agent == .both and (tops[0] == null or tops[1] == null or !std.mem.eql(u8, tops[0].?, tops[1].?));
    result.state = if (partial) .review else if (result.len == 0) .skipped else if (disagree or result.tags[0].confidence < threshold) .review else .tagged;
    return result;
}
