const std = @import("std");
const wire = @import("tagger.zig");
const Claude = @import("claude_tagger.zig").Claude;
const Contract = @import("contract_tagger.zig").Contract;
pub const Saved = struct { address: []const u8 = "", key: []const u8 = "", wrap: bool = false, model: []const u8 = "claude-sonnet-5-5" };
pub fn valid(saved: Saved) bool {
    const uri = std.Uri.parse(saved.address) catch return false;
    const host = switch (uri.host orelse return false) {
        inline else => |text| text,
    };
    const local = std.mem.eql(u8, uri.scheme, "http") and (std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "127.0.0.1"));
    const https = std.mem.eql(u8, uri.scheme, "https") and std.mem.startsWith(u8, saved.address, "https://");
    return uri.user == null and uri.password == null and host.len > 0 and (local or https) and !(saved.wrap and saved.model.len == 0);
}
const limit = 65536;
// Your own agent in $HERONIN_DATA/yours.zon (0600): https anywhere, plain http only on this machine.
pub const Yours = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    saved: Saved = .{},
    arena: ?std.heap.ArenaAllocator = null,
    claude: Claude = undefined,
    contract: Contract = undefined,
    pub fn deinit(self: *Yours) void {
        if (self.arena) |*arena| arena.deinit();
    }
    pub fn load(self: *Yours) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.path, a, .limited(limit)) catch |err| return if (err == error.FileNotFound) {} else err;
        var diagnostics: std.zon.parse.Diagnostics = undefined;
        try self.keep(try std.zon.parse.fromSlice(Saved, .{ .gpa = a, .arena = a, .source = try a.dupeSentinel(u8, bytes, 0), .diagnostics = &diagnostics }));
    }
    pub fn save(self: *Yours, saved: Saved) !void {
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        try std.zon.stringify.serialize(saved, .{}, &out.writer);
        if (out.written().len >= limit) return error.TooLarge;
        var file = try std.Io.Dir.cwd().createFileAtomic(self.io, self.path, .{ .permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o600), .replace = true });
        defer file.deinit(self.io);
        try file.file.writeStreamingAll(self.io, out.written());
        try file.replace(self.io);
        try self.keep(saved);
    }
    fn keep(self: *Yours, saved: Saved) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const kept: Saved = .{ .address = try a.dupe(u8, saved.address), .key = try a.dupe(u8, saved.key), .wrap = saved.wrap, .model = try a.dupe(u8, saved.model) };
        self.deinit();
        self.* = .{ .gpa = self.gpa, .io = self.io, .path = self.path, .saved = kept, .arena = arena };
    }
    pub fn tagger(self: *Yours, io: std.Io) ?wire.Tagger {
        if (self.saved.address.len == 0) return null;
        self.claude = .{ .io = io, .config = .{ .key = self.saved.key, .model = self.saved.model, .url = self.saved.address } };
        self.contract = .{ .io = io, .address = self.saved.address, .key = self.saved.key };
        return if (self.saved.wrap) self.claude.tagger() else self.contract.tagger();
    }
};
