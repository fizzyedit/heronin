const std = @import("std");
const source = @embedFile("sw_source");

const Url = struct { pathname: []const u8, search: []const u8, navigate: bool = false };

// Mirrors the service worker rule on URL.pathname and URL.search.
fn pruneSuperseded(cached: Url, stored: Url) bool {
    if (stored.navigate) return false;
    var asset = false;
    inline for (.{ "web.wasm", "web.js", "fizzy.js", "fizzy-worker.js" }) |name| {
        asset = asset or std.mem.eql(u8, stored.pathname, "/heronin/" ++ name);
    }
    return asset and stored.search.len != 0 and
        std.mem.eql(u8, cached.pathname, stored.pathname) and
        !std.mem.eql(u8, cached.search, stored.search);
}

test "pruneSuperseded preserves shell and navigation stores" {
    const shell: Url = .{ .pathname = "/heronin/", .search = "" };
    try std.testing.expect(!pruneSuperseded(shell, .{ .pathname = shell.pathname, .search = "?x=1" }));
    try std.testing.expect(!pruneSuperseded(shell, .{ .pathname = shell.pathname, .search = "?x=1", .navigate = true }));
    inline for (.{ "web.wasm", "web.js", "fizzy.js", "fizzy-worker.js" }) |name| {
        const old: Url = .{ .pathname = "/heronin/" ++ name, .search = "?v=old" };
        try std.testing.expect(pruneSuperseded(old, .{ .pathname = old.pathname, .search = "?v=new" }));
        try std.testing.expect(!pruneSuperseded(old, .{ .pathname = old.pathname, .search = "?v=new", .navigate = true }));
    }
    const font: Url = .{ .pathname = "/heronin/NotoSansKR-Regular.ttf", .search = "" };
    try std.testing.expect(!pruneSuperseded(font, .{ .pathname = font.pathname, .search = "?x=1" }));
}

fn offlineFallback(exact: ?[]const u8, navigate: bool, shell: ?[]const u8) ?[]const u8 {
    return exact orelse if (navigate) shell else null;
}

test "pruneSuperseded keeps one web.wasm deploy and preserves other paths" {
    const old: Url = .{ .pathname = "/heronin/web.wasm", .search = "?v=old" };
    const new: Url = .{ .pathname = old.pathname, .search = "?v=new" };
    const other: Url = .{ .pathname = "/heronin/web.js", .search = old.search };
    var wasm_entries: usize = 0;
    for ([_]Url{ old, new, other }) |cached| {
        if (!pruneSuperseded(cached, new) and std.mem.eql(u8, cached.pathname, new.pathname)) wasm_entries += 1;
    }
    try std.testing.expect(pruneSuperseded(old, new));
    try std.testing.expect(!pruneSuperseded(new, new));
    try std.testing.expectEqual(@as(usize, 1), wasm_entries);
    try std.testing.expect(!pruneSuperseded(other, new));
    try std.testing.expect(pruneSuperseded(.{ .pathname = old.pathname, .search = "" }, new));
    try std.testing.expect(!pruneSuperseded(old, .{ .pathname = old.pathname, .search = "" }));
}

test "navigation miss falls back to cached shell document" {
    try std.testing.expectEqualStrings("shell document", offlineFallback(null, true, "shell document").?);
    try std.testing.expectEqualStrings("exact document", offlineFallback("exact document", true, "shell document").?);
    try std.testing.expectEqual(@as(?[]const u8, null), offlineFallback(null, false, "shell document"));
    try std.testing.expectEqual(@as(?[]const u8, null), offlineFallback(null, true, null));
    try std.testing.expect(std.mem.indexOf(u8, source, "request.mode === 'navigate' && await cache.match(ROOT)") != null);
}

test "service worker names and implements pruneSuperseded" {
    try std.testing.expect(std.mem.indexOf(u8, source, "// Rule pruneSuperseded:") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "cached.pathname === stored.pathname && cached.search !== stored.search") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "if (request.mode === 'navigate' || !stored.search ||") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "!['web.wasm', 'web.js', 'fizzy.js', 'fizzy-worker.js'].some(name => stored.pathname === ROOT + name)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "await cache.delete(key)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "if (response.ok) await cache.put(request, response.clone())") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "await store(cache, request, response)") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "if (response.ok) await store(cache, event.request, response)") != null);
}
