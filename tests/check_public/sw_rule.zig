const std = @import("std");

// URL fields correspond to the browser URL object's origin, pathname and search.
pub const Url = struct {
    origin: []const u8 = "https://example.test",
    pathname: []const u8,
    search: []const u8 = "",
};

pub fn shouldDelete(old: Url, stored: Url) bool {
    return std.mem.eql(u8, old.origin, stored.origin) and
        std.mem.eql(u8, old.pathname, stored.pathname) and
        !std.mem.eql(u8, old.search, stored.search);
}

pub fn offlineDocument(cached: []const Url, request: Url, navigation: bool) ?Url {
    for (cached) |entry| {
        if (std.mem.eql(u8, entry.origin, request.origin) and
            std.mem.eql(u8, entry.pathname, request.pathname) and
            std.mem.eql(u8, entry.search, request.search)) return entry;
    }
    if (navigation) for (cached) |entry| {
        if (std.mem.eql(u8, entry.pathname, "/heronin/index.html") and entry.search.len == 0) return entry;
    };
    return null;
}
