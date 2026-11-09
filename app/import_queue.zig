const std = @import("std");
const api = @import("store.zig");
pub const State = enum { queued, uploading, already_there, failed, imported };
/// name borrows the caller's names; keep them alive for the queue's lifetime.
pub const Row = struct { name: []const u8, state: State, photo_id: ?[]const u8 = null, err: ?api.Error = null };
pub const Queue = struct {
    allocator: std.mem.Allocator,
    rows: std.ArrayList(Row) = .empty,
    pending: std.ArrayList([]u8) = .empty,
    busy: bool = false,
    active: usize = 0,
    pub fn add(self: *Queue, names: []const []const u8, bytes: []const []u8) error{ TooMany, OutOfMemory }!void {
        if (names.len > 10) return error.TooMany;
        std.debug.assert(names.len == bytes.len);
        try self.rows.ensureUnusedCapacity(self.allocator, names.len);
        try self.pending.ensureUnusedCapacity(self.allocator, bytes.len);
        for (names, bytes) |name, buffer| {
            self.rows.appendAssumeCapacity(.{ .name = name, .state = .queued });
            self.pending.appendAssumeCapacity(buffer);
        }
    }
    pub fn step(self: *Queue, store: api.Store) void {
        if (self.busy) return;
        for (self.rows.items, 0..) |*row, i| {
            if (row.state != .queued) continue;
            self.busy = true;
            self.active = i;
            row.state = .uploading;
            store.importFile(row.name, self.pending.items[i], self, done);
            return;
        }
    }
    fn done(ctx: ?*anyopaque, result: api.Error!api.Imported) void {
        const self: *Queue = @ptrCast(@alignCast(ctx.?));
        const row = &self.rows.items[self.active];
        defer self.busy = false;
        defer self.pending.items[self.active] = &.{};
        defer self.allocator.free(self.pending.items[self.active]);
        if (result) |value| {
            const id = self.allocator.dupe(u8, value.photo.id) catch null;
            row.* = .{ .name = row.name, .state = if (id == null) .failed else if (value.new) .imported else .already_there, .photo_id = id, .err = if (id == null) error.OutOfMemory else null };
        } else |err| {
            row.state = .failed;
            row.err = err;
        }
    }
    pub fn deinit(self: *Queue) void {
        for (self.pending.items) |bytes| self.allocator.free(bytes);
        for (self.rows.items) |row| if (row.photo_id) |id| self.allocator.free(id);
        self.pending.deinit(self.allocator);
        self.rows.deinit(self.allocator);
    }
};
pub const Counts = struct { total: usize = 0, finished: usize = 0, tagged: usize = 0, review: usize = 0, skipped: usize = 0 };
pub fn counts(rows: []const Row, items: []const api.Item) Counts {
    var result: Counts = .{ .total = rows.len };
    for (rows) |row| {
        if (row.state == .queued or row.state == .uploading) continue;
        result.finished += 1;
        if (row.state != .imported and row.state != .already_there) continue;
        for (items) |item| {
            if (!std.mem.eql(u8, item.photo.id, row.photo_id orelse continue)) continue;
            inline for (.{ "tagged", "review", "skipped" }) |state| {
                if (item.photo.state == @field(@TypeOf(item.photo.state), state)) @field(result, state) += 1;
            }
            break;
        }
    }
    return result;
}
