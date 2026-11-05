const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const theme = @import("theme.zig");
const tabs = @import("views/tabs.zig");
pub const plugin_options = @import("fizzy_plugin_options");
pub const plugin_id = plugin_options.id;
var plugin: sdk.Plugin = .{ .state = undefined, .vtable = &.{ .deinit = deinit }, .id = plugin_id, .display_name = plugin_options.name };
var current: tabs.Tab = .library;
pub fn register(host: *sdk.Host) !void {
    plugin.state = @ptrCast(host);
    try host.registerPlugin(&plugin);
    try host.registerSurface(.{ .id = "heronin.library", .owner = &plugin, .title = "Library", .keywords = &.{"heronin"}, .scrolls_itself = true, .draw = draw });
}
fn deinit(_: *anyopaque) void {
    current = .library;
}
fn draw(_: ?*anyopaque) anyerror!dvui.App.Result {
    dvui.themeSet(theme.light(dvui.themeGet()));
    var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .color_fill = .{ .color = theme.paper }, .padding = .all(16) });
    defer page.deinit();
    {
        var content = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer content.deinit();
        dvui.labelNoFmt(@src(), current.title(), .{}, .{ .font = dvui.Font.theme(.title), .color_text = .{ .color = theme.red[0] } });
        if (current == .library) dvui.labelNoFmt(@src(), "No photos yet.", .{}, .{});
    }
    tabs.draw(&current);
    return .ok;
}
