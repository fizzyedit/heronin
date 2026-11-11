const std = @import("std");
const wire = @import("tagger.zig");
const Claude = @import("claude_tagger.zig").Claude;
const Contract = @import("contract_tagger.zig").Contract;
pub const Saved = struct { address: []const u8 = "", key: []const u8 = "", wrap: bool = false, model: []const u8 = "claude-sonnet-5-5" };
pub fn valid(saved: Saved) bool {
    _ = std.Uri.parse(saved.address) catch return false;
    const local = for ([_][]const u8{ "http://127.0.0.1", "http://localhost" }) |prefix| {
        if (std.mem.startsWith(u8, saved.address, prefix) and (saved.address.len == prefix.len or std.mem.indexOfScalar(u8, ":/", saved.address[prefix.len]) != null)) break true;
    } else false;
    return (local or (std.mem.startsWith(u8, saved.address, "https://") and saved.address.len > 8)) and !(saved.wrap and saved.model.len == 0);
}
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
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.path, a, .limited(65536)) catch |err| return if (err == error.FileNotFound) {} else err;
        var diagnostics: std.zon.parse.Diagnostics = undefined;
        try self.keep(try std.zon.parse.fromSlice(Saved, .{ .gpa = a, .arena = a, .source = try a.dupeSentinel(u8, bytes, 0), .diagnostics = &diagnostics }));
    }
    pub fn save(self: *Yours, saved: Saved) !void {
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        try std.zon.stringify.serialize(saved, .{}, &out.writer);
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
