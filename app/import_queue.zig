const std = @import("std");
const api = @import("store.zig");
pub const State = enum { queued, uploading, already_there, failed, imported };
pub const Row = struct { name: []const u8, state: State, photo_id: ?[]const u8 = null, err: ?api.Error = null };
pub const Queue = struct {
    allocator: std.mem.Allocator,
    rows: std.ArrayList(Row) = .empty,
    pending: std.ArrayList([]u8) = .empty,
    busy: bool = false,
    active: usize = 0,
    flight: Row = undefined,
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
            self.flight = row.*;
            store.importFile(row.name, self.pending.items[i], &self.flight, done);
            return;
        }
    }
    fn done(ctx: ?*anyopaque, result: api.Error!api.Imported) void {
        const self: *Queue = @fieldParentPtr("flight", @as(*Row, @ptrCast(@alignCast(ctx.?))));
        const row = &self.rows.items[self.active];
        if (result) |value| {
            row.state = if (value.new) .imported else .already_there;
            row.photo_id = value.photo.id;
        } else |err| {
            row.state = .failed;
            row.err = err;
        }
        self.allocator.free(self.pending.items[self.active]);
        self.pending.items[self.active] = &.{};
        self.busy = false;
    }
    pub fn deinit(self: *Queue) void {
        for (self.pending.items) |bytes| self.allocator.free(bytes);
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
