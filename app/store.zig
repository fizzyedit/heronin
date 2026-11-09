const model = @import("model");
pub const Error = error{ NotFound, Unsupported, Io, OutOfMemory };
pub fn Done(comptime T: type) type {
    return *const fn (ctx: ?*anyopaque, result: Error!T) void;
}
/// new is false when the store already holds this md5 (Drive matches md5Checksum).
pub const Imported = struct { photo: model.Photo, new: bool };
pub const Item = struct {
    photo: model.Photo,
    /// tags[0] is the shown tag, followed by up to four guesses; empty when untagged.
    tags: []const model.Tag,
};
/// Thumbnail.wash indexes theme.washes.
pub const Thumbnail = union(enum) { wash: u8, encoded: []const u8 };
/// The seam K7’s DriveStore fills later. Operations return immediately; only pump
/// delivers callbacks, on the caller's thread. Answer slices live until the next pump.
pub const Store = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        list: *const fn (ptr: *anyopaque, after: ?[]const u8, limit: u32, ctx: ?*anyopaque, done: Done([]const Item)) void,
        thumbnail: *const fn (ptr: *anyopaque, id: []const u8, px: u32, ctx: ?*anyopaque, done: Done(Thumbnail)) void,
        importFile: *const fn (ptr: *anyopaque, name: []const u8, bytes: []const u8, ctx: ?*anyopaque, done: Done(Imported)) void,
        setTags: *const fn (ptr: *anyopaque, id: []const u8, tags: []const model.Tag, state: model.Photo.State, ctx: ?*anyopaque, done: Done(void)) void,
        setFavorite: *const fn (ptr: *anyopaque, id: []const u8, on: bool, ctx: ?*anyopaque, done: Done(void)) void,
        places: *const fn (ptr: *anyopaque, ctx: ?*anyopaque, done: Done([]const model.Place)) void,
        pump: *const fn (ptr: *anyopaque) void,
    };
    pub fn list(self: Store, after: ?[]const u8, limit: u32, ctx: ?*anyopaque, done: Done([]const Item)) void {
        self.vtable.list(self.ptr, after, limit, ctx, done);
    }
    pub fn thumbnail(self: Store, id: []const u8, px: u32, ctx: ?*anyopaque, done: Done(Thumbnail)) void {
        self.vtable.thumbnail(self.ptr, id, px, ctx, done);
    }
    pub fn importFile(self: Store, name: []const u8, bytes: []const u8, ctx: ?*anyopaque, done: Done(Imported)) void {
        self.vtable.importFile(self.ptr, name, bytes, ctx, done);
    }
    pub fn setTags(self: Store, id: []const u8, tags: []const model.Tag, state: model.Photo.State, ctx: ?*anyopaque, done: Done(void)) void {
        self.vtable.setTags(self.ptr, id, tags, state, ctx, done);
    }
    pub fn setFavorite(self: Store, id: []const u8, on: bool, ctx: ?*anyopaque, done: Done(void)) void {
        self.vtable.setFavorite(self.ptr, id, on, ctx, done);
    }
    pub fn places(self: Store, ctx: ?*anyopaque, done: Done([]const model.Place)) void {
        self.vtable.places(self.ptr, ctx, done);
    }
    pub fn pump(self: Store) void {
        self.vtable.pump(self.ptr);
    }
};
