const std = @import("std");
const Rule = enum { image, fixture_size, server, credentials, jsonl, env, hostname, address, anthropic, oauth, client_secret, bearer };

fn image(path: []const u8, data: []const u8) bool {
    const ext = std.fs.path.extension(path);
    for ([_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".ico", ".svg", ".avif", ".heic", ".tif", ".tiff" }) |suffix| {
        if (std.ascii.eqlIgnoreCase(ext, suffix)) return true;
    }
    return std.mem.startsWith(u8, data, "\x89PNG") or std.mem.startsWith(u8, data, "\xff\xd8\xff") or
        std.mem.startsWith(u8, data, "GIF8") or (data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP"));
}

fn token(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~+/=", c) != null;
}

fn violation(path: []const u8, data: []const u8) ?Rule {
    const base = std.fs.path.basename(path);
    if (std.mem.eql(u8, base, "server.zon")) return .server;
    if (std.mem.eql(u8, base, "credentials.zon")) return .credentials;
    if (std.mem.endsWith(u8, base, ".jsonl")) return .jsonl;
    if (std.mem.startsWith(u8, base, ".env")) return .env;
    if (image(path, data)) {
        if (!std.mem.startsWith(u8, path, "tests/fixtures/")) return .image;
        if (data.len > 64 * 1024) return .fixture_size;
    }
    if (!std.unicode.utf8ValidateSlice(data) or std.mem.indexOfScalar(u8, data, 0) != null) return null;
    for ([_]struct { []const u8, Rule }{
        .{ ".ts" ++ ".net", .hostname },
        .{ "sk-" ++ "ant-", .anthropic },
        .{ "GOC" ++ "SPX-", .oauth },
    }) |entry| if (std.mem.indexOf(u8, data, entry[0]) != null) return entry[1];
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        if (std.mem.startsWith(u8, data[i..], "100.") and (i == 0 or (!std.ascii.isAlphanumeric(data[i - 1]) and data[i - 1] != '.'))) {
            var end = i;
            while (end < data.len and (std.ascii.isDigit(data[end]) or data[end] == '.')) : (end += 1) {}
            // Sentence punctuation is not an extra address octet.
            var candidate = data[i..end];
            if (std.mem.endsWith(u8, candidate, ".")) candidate = candidate[0 .. candidate.len - 1];
            var parts = std.mem.splitScalar(u8, candidate, '.');
            var octets: [4]u8 = undefined;
            var count: usize = 0;
            while (parts.next()) |part| {
                if (count == 4) {
                    count += 1;
                    break;
                }
                octets[count] = std.fmt.parseInt(u8, part, 10) catch break;
                count += 1;
            }
            if (count == 4 and parts.next() == null and octets[1] >= 64 and octets[1] <= 127) return .address;
        }
        if (std.mem.startsWith(u8, data[i..], "Bearer ")) {
            var end = i + 7;
            while (end < data.len and token(data[end])) : (end += 1) {}
            if (end - i - 7 >= 20) return .bearer;
        }
        const key = "client_secret";
        if (std.mem.startsWith(u8, data[i..], key)) {
            var pos = i + key.len;
            while (pos < data.len and (std.ascii.isWhitespace(data[pos]) or data[pos] == '"' or data[pos] == '\'')) : (pos += 1) {}
            if (pos < data.len and (data[pos] == ':' or data[pos] == '=')) {
                pos += 1;
                while (pos < data.len and (std.ascii.isWhitespace(data[pos]) or data[pos] == '"' or data[pos] == '\'')) : (pos += 1) {}
                if (pos < data.len and std.mem.indexOfScalar(u8, ",;}\r\n", data[pos]) == null) return .client_secret;
            }
        }
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const result = try std.process.run(allocator, init.io, .{ .argv = &.{ "git", "ls-files", "-z" } });
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
    var paths = std.mem.splitScalar(u8, result.stdout, 0);
    var failed = false;
    while (paths.next()) |path| {
        if (path.len == 0 or std.mem.startsWith(u8, path, "tests/check_public/")) continue;
        const data = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .unlimited);
        if (violation(path, data)) |rule| {
            std.debug.print("{s}: {s}\n", .{ path, @tagName(rule) });
            failed = true;
        }
    }
    if (failed) return error.PublicCheckFailed;
}

test "each public rule rejects its tree; clean tree passes" {
    const io = std.testing.io;
    inline for (@typeInfo(Rule).@"enum".field_names) |name| {
        try std.testing.expectEqual(@field(Rule, name), (try scanTree(io, "tests/check_public/" ++ name)).?);
    }
    try std.testing.expectEqual(null, try scanTree(io, "tests/check_public/clean"));
}

test "address followed by a full stop is rejected" {
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/check_public/address/trailing-stop.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqual(Rule.address, violation("trailing-stop.txt", data).?);
}

test "address range boundaries and punctuation" {
    for ([_][]const u8{ "100" ++ ".64.0.0.", "(100" ++ ".127.255.255).", "100" ++ ".101.102.103", "reach it at 100" ++ ".101.102.103.", "100" ++ ".101.102.103. Next sentence." }) |data| {
        try std.testing.expectEqual(Rule.address, violation("address.txt", data).?);
    }
    for ([_][]const u8{ "100" ++ ".63.255.255.", "100" ++ ".128.0.0.", "100" ++ ".101.102.256.", "100" ++ ".101.102.103.4", "1100" ++ ".101.102.103." }) |data| {
        try std.testing.expectEqual(null, violation("address.txt", data));
    }
}

fn scanTree(io: std.Io, path: []const u8) !?Rule {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(std.testing.allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const data = try dir.readFileAlloc(io, entry.path, std.testing.allocator, .unlimited);
        defer std.testing.allocator.free(data);
        const normalized = try std.testing.allocator.dupe(u8, entry.path);
        defer std.testing.allocator.free(normalized);
        std.mem.replaceScalar(u8, normalized, '\\', '/');
        if (violation(normalized, data)) |rule| return rule;
    }
    return null;
}
