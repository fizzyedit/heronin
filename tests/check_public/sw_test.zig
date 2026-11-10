const std = @import("std");

test "two deploys leave one web.wasm entry and navigation works offline" {
    var lib = try std.DynLib.open("libjavascriptcoregtk-4.0.so.18");
    defer lib.close();
    const create = lib.lookup(*const fn (?*anyopaque) callconv(.c) ?*anyopaque, "JSGlobalContextCreate").?;
    const release = lib.lookup(*const fn (?*anyopaque) callconv(.c) void, "JSGlobalContextRelease").?;
    const string = lib.lookup(*const fn ([*:0]const u8) callconv(.c) ?*anyopaque, "JSStringCreateWithUTF8CString").?;
    const free_string = lib.lookup(*const fn (?*anyopaque) callconv(.c) void, "JSStringRelease").?;
    const eval = lib.lookup(*const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque, c_int, *?*anyopaque) callconv(.c) ?*anyopaque, "JSEvaluateScript").?;
    const boolean = lib.lookup(*const fn (?*anyopaque, ?*anyopaque) callconv(.c) bool, "JSValueToBoolean").?;
    const ctx = create(null);
    defer release(ctx);
    const allocator = std.testing.allocator;
    const worker = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "web/sw.js", allocator, .unlimited);
    defer allocator.free(worker);
    const source = try std.mem.concatWithSentinel(allocator, u8, &.{ @embedFile("sw_mock.js"), worker, @embedFile("sw_cases.js") }, 0);
    defer allocator.free(source);
    const script = string(source);
    defer free_string(script);
    var exception: ?*anyopaque = null;
    _ = eval(ctx, script, null, null, 1, &exception);
    try std.testing.expect(exception == null);
    // JavaScriptCore drains promise jobs when the outer evaluation returns.
    const result = string("globalThis.passed === true");
    defer free_string(result);
    try std.testing.expect(boolean(ctx, eval(ctx, result, null, null, 1, &exception)));
    try std.testing.expect(exception == null);
}
