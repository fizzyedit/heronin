const std = @import("std");
const rule = @import("sw_rule.zig");
const Url = rule.Url;

test "two deploys leave one web.wasm entry and navigation works offline" {
    var cached: [8]Url = undefined;
    var count: usize = 0;
    const shell: Url = .{ .pathname = "/heronin/index.html" };
    const legacy: Url = .{ .pathname = "/heronin/web.wasm" };
    const first: Url = .{ .pathname = legacy.pathname, .search = "?build=one" };
    const second: Url = .{ .pathname = legacy.pathname, .search = "?build=two" };
    const other: Url = .{ .pathname = "/heronin/other.wasm", .search = first.search };
    const foreign: Url = .{ .origin = "https://other.test", .pathname = legacy.pathname };
    for ([_]Url{ shell, legacy, foreign, first, other, second }) |stored| {
        cached[count] = stored;
        count += 1;
        var kept: usize = 0;
        for (cached[0..count]) |old| {
            if (!rule.shouldDelete(old, stored)) {
                cached[kept] = old;
                kept += 1;
            }
        }
        count = kept;
    }
    var wasm_count: usize = 0;
    for (cached[0..count]) |entry| {
        if (std.mem.eql(u8, entry.origin, second.origin) and std.mem.eql(u8, entry.pathname, second.pathname)) {
            wasm_count += 1;
            try std.testing.expectEqualStrings(second.search, entry.search);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), wasm_count);
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqualDeep(second, rule.offlineDocument(cached[0..count], second, false).?);
    for ([_][]const u8{ "/heronin/", "/heronin/deep-link" }) |path| {
        const request: Url = .{ .pathname = path };
        try std.testing.expectEqualDeep(shell, rule.offlineDocument(cached[0..count], request, true).?);
        try std.testing.expectEqual(null, rule.offlineDocument(cached[0..count], request, false));
    }
}

test "worker source keeps the modeled pruning and shell fallback rules" {
    const allocator = std.testing.allocator;
    const worker = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "web/sw.js", allocator, .unlimited);
    defer allocator.free(worker);
    for ([_][]const u8{
        "await cache.put(request, response);",
        "for (const key of await cache.keys())",
        "old.origin === url.origin && old.pathname === url.pathname &&",
        "old.search !== url.search) await cache.delete(key);",
        "return (await cache.match(request)) ||",
        "(request.mode === 'navigate' && await cache.match(ROOT + 'index.html')) ||",
        "const ROOT = '/heronin/';",
        "ROOT + 'index.html'",
    }) |text| try std.testing.expect(std.mem.indexOf(u8, worker, text) != null);
}
