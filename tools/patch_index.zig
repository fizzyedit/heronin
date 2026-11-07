const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const path = args[1];
    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .unlimited);
    var page = source;
    const start = std.mem.indexOf(u8, page, "<title>") orelse return error.MissingTitle;
    const end = std.mem.indexOfPos(u8, page, start, "</title>") orelse return error.MissingTitle;
    page = try std.mem.concat(allocator, u8, &.{ page[0..start], "<title>Heronin</title>", page[end + 8 ..] });
    const links =
        \\<meta name="theme-color" content="#22232a" />
        \\<link rel="manifest" href="/heronin/manifest.webmanifest" />
        \\<script>
        \\if ('serviceWorker' in navigator) {
        \\  navigator.serviceWorker.register('/heronin/sw.js', {scope: '/heronin/'});
        \\}
        \\</script>
        \\
    ;
    // Remove upstream manifest/theme tags so the app owns these declarations.
    for ([_][]const u8{ "<meta name=\"theme-color\"", "<link rel=\"manifest\"" }) |tag| {
        while (std.mem.indexOf(u8, page, tag)) |pos| {
            const close = std.mem.indexOfPos(u8, page, pos, ">") orelse return error.InvalidTag;
            page = try std.mem.concat(allocator, u8, &.{ page[0..pos], page[close + 1 ..] });
        }
    }
    const insertion = std.mem.indexOf(u8, page, "</head>") orelse return error.MissingHead;
    page = try std.mem.concat(allocator, u8, &.{ page[0..insertion], links, page[insertion..] });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = page });
}
