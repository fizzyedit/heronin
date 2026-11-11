const std = @import("std");
const model = @import("model");
const wire = @import("tagger.zig");
const prompt = "You identify wild birds in a photo for a birder's life list. Report each bird species you can see, most likely first, at most 5, by eBird species code and English common name. Confidence is your probability that the species is right. If no bird is visible, report no candidates. Never guess a species you cannot see.";
const Text = struct { type: []const u8 = "string", description: []const u8 };
const Limited = struct { type: []const u8 = "string", maxLength: u8, description: []const u8 };
const schema = .{ .type = "object", .required = .{"candidates"}, .properties = .{ .candidates = .{ .type = "array", .maxItems = 5, .items = .{
    .type = "object",
    .required = .{ "species", "common", "confidence" },
    .properties = .{
        .species = Text{ .description = "eBird species code" },
        .common = Text{ .description = "English common name" },
        .confidence = .{ .type = "number", .minimum = 0, .maximum = 1 },
        .detail = Limited{ .maxLength = 40, .description = "e.g. adult male" },
        .note = Limited{ .maxLength = 110, .description = "why" },
    },
} } } };
const Item = struct { species: []const u8, common: []const u8 = "", confidence: f32, detail: ?[]const u8 = null, note: ?[]const u8 = null };
const Message = struct { model: []const u8, content: []const struct { type: []const u8, name: ?[]const u8 = null, input: ?struct { candidates: []const Item } = null } };
pub const Claude = struct {
    io: std.Io,
    config: Config,
    post: Post = real,
    pub const Config = struct { key: []const u8, model: []const u8 = "claude-sonnet-5-5", url: []const u8 = "https://api.anthropic.com/v1/messages" };
    pub const Reply = struct { status: u16, body: []const u8 };
    pub const Post = struct { ctx: ?*anyopaque, postFn: *const fn (?*anyopaque, *Claude, std.mem.Allocator, []const u8) anyerror!Reply };
    pub const real: Post = .{ .ctx = null, .postFn = send };
    pub fn headers(key: []const u8) [3]std.http.Header {
        return .{ .{ .name = "x-api-key", .value = key }, .{ .name = "anthropic-version", .value = "2023-06-01" }, .{ .name = "content-type", .value = "application/json" } };
    }
    pub fn tagger(self: *Claude) wire.Tagger {
        return .{ .ctx = self, .tagFn = tag };
    }
    fn mediaType(image: []const u8) ![]const u8 {
        if (image.len == 0) return error.NoImage;
        if (std.mem.startsWith(u8, image, "/9j/")) return "image/jpeg";
        if (std.mem.startsWith(u8, image, "iVBOR")) return "image/png";
        return error.UnsupportedImage;
    }
    pub fn body(allocator: std.mem.Allocator, name: []const u8, request: wire.Request) ![]u8 {
        var facts: std.Io.Writer.Allocating = .init(allocator);
        defer facts.deinit();
        if (request.taken_at) |at| if (at >= 0) {
            const day = (std.time.epoch.EpochSeconds{ .secs = @intCast(at) }).getEpochDay().calculateYearDay();
            const date = day.calculateMonthDay();
            try facts.writer.print("Taken {d}-{d:0>2}-{d:0>2}.", .{ day.year, date.month.numeric(), date.day_index + 1 });
        };
        if (request.place) |place| try facts.writer.print("{s}Near latitude {d:.2}, longitude {d:.2}.", .{ if (facts.written().len > 0) " " else "", place.lat, place.lon });
        if (facts.written().len == 0) try facts.writer.writeAll("No date or place.");
        return std.json.Stringify.valueAlloc(allocator, .{
            .model = name,
            .max_tokens = 1024,
            .system = prompt,
            .tools = .{.{ .name = "birds", .description = "Report the bird species in the photo.", .input_schema = schema }},
            .tool_choice = .{ .type = "tool", .name = "birds" },
            .messages = .{.{ .role = "user", .content = .{
                .{ .type = "image", .source = .{ .type = "base64", .media_type = try mediaType(request.image), .data = request.image } },
                .{ .type = "text", .text = facts.written() },
            } }},
        }, .{});
    }
    fn tag(ctx: *anyopaque, allocator: std.mem.Allocator, request: wire.Request) !wire.Answer {
        const self: *Claude = @ptrCast(@alignCast(ctx));
        return answer(allocator, try self.post.postFn(self.post.ctx, self, allocator, try body(allocator, self.config.model, request)));
    }
    fn answer(allocator: std.mem.Allocator, reply: Reply) !wire.Answer {
        switch (reply.status) {
            200 => {},
            401, 403 => return refuse(error.Unauthorized, "claude refused the key"),
            429, 500...599 => return refuse(error.Unavailable, "claude busy"),
            else => return refuse(error.BadAnswer, "claude answer unreadable"),
        }
        const message = std.json.parseFromSliceLeaky(Message, allocator, reply.body, .{ .ignore_unknown_fields = true }) catch return refuse(error.BadAnswer, "claude answer unreadable");
        const items = for (message.content) |block| {
            if (std.mem.eql(u8, block.type, "tool_use") and std.mem.eql(u8, block.name orelse "", "birds")) if (block.input) |input| break input.candidates;
        } else return refuse(error.BadAnswer, "claude answer unreadable");
        const candidates = try allocator.alloc(wire.Candidate, items.len);
        for (candidates, items) |*candidate, item| {
            var code = item.species;
            if (model.species.find(code) == null) for (model.species.table) |species| if (std.ascii.eqlIgnoreCase(species.common, item.common)) {
                code = species.code;
            };
            candidate.* = .{ .species = code, .confidence = item.confidence, .detail = item.detail, .note = item.note };
        }
        return .{ .candidates = candidates, .model = message.model };
    }
    fn refuse(err: anyerror, reason: []const u8) anyerror {
        std.log.warn("{s}", .{reason});
        return err;
    }
    fn send(_: ?*anyopaque, self: *Claude, allocator: std.mem.Allocator, payload: []const u8) !Reply {
        var client: std.http.Client = .{ .allocator = allocator, .io = self.io };
        defer client.deinit();
        var response = std.Io.Writer.fixed(try allocator.alloc(u8, 64 * 1024));
        const result = client.fetch(.{ .location = .{ .url = self.config.url }, .method = .POST, .payload = payload, .redirect_behavior = .not_allowed, .headers = .{ .content_type = .omit }, .extra_headers = &headers(self.config.key), .response_writer = &response }) catch |err| {
            if (err == error.WriteFailed) return refuse(error.BadAnswer, "claude answer unreadable");
            return refuse(err, "claude unreachable");
        };
        return .{ .status = @backingInt(result.status), .body = response.buffered() };
    }
};
