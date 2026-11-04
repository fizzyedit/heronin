//! Heronin data model (plan 2.3). Types and doc comments only: no logic beyond the md5 JSON hooks.
pub const SpeciesCode = []const u8; // eBird species code: usually 6 letters, some have 7 ("comgal1"), so not [6]u8
pub const Place = struct { lat: f64, lon: f64 }; // degrees, WGS84
pub const Box = struct { x: f32, y: f32, w: f32, h: f32 }; // 0..1 of the image, origin top left

pub const Photo = struct {
    id: []const u8, // Drive file id
    md5: Md5, // Drive's md5Checksum
    name: []const u8, // file name
    taken_at: ?i64 = null, // unix seconds, UTC
    place: ?Place = null,
    camera: ?[]const u8 = null,
    w: u32,
    h: u32, // pixels
    bytes: u64,
    favorite: bool = false,
    state: State = .new,
    pub const State = enum { new, tagging, tagged, review, failed, skipped };
};
/// 16 bytes in memory; on the wire 32 lowercase hex chars (the form Drive returns).
/// Implement jsonStringify/jsonParse on this one type.
pub const Md5 = struct {
    bytes: [16]u8,
    pub fn jsonStringify(self: Md5, writer: anytype) !void {
        try writer.write(@import("std").fmt.bytesToHex(self.bytes, .lower));
    }
    pub fn jsonParse(allocator: @import("std").mem.Allocator, source: anytype, options: @import("std").json.ParseOptions) !Md5 {
        const std = @import("std");
        const hex = try std.json.innerParse([]const u8, allocator, source, options);
        if (hex.len != 32) return error.InvalidCharacter;
        var result: Md5 = undefined;
        for (hex) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return error.InvalidCharacter;
        _ = std.fmt.hexToBytes(&result.bytes, hex) catch return error.InvalidCharacter;
        return result;
    }
};

pub const Tag = struct {
    species: SpeciesCode,
    confidence: f32, // 0..1
    source: Source,
    accepted: Accepted,
    at: i64, // unix seconds, UTC: when the tag was made
    model: []const u8, // id of the model or agent that tagged it; "" when source == .person
    box: ?Box = null,
    detail: ?[]const u8 = null, // <= 40 bytes ("adult male"); doc comment only, not enforced in K1
    note: ?[]const u8 = null, // <= 110 bytes, the agent's reason; doc comment only
    pub const Source = enum { ours, yours, person };
    pub const Accepted = enum { auto, person, rejected };
};

pub const Species = struct { code: SpeciesCode, common: []const u8, scientific: []const u8, family: []const u8, order: []const u8 };

pub const QueueItem = struct {
    photo: []const u8, // Photo.id (Drive file id), not a copy of the Photo
    agent: Agent,
    attempts: u8 = 0,
    last_error: ?[]const u8 = null,
    pub const Agent = enum { ours, yours, both };
};
