const dvui = @import("dvui");
const theme = @import("../theme.zig");
pub const Tab = enum {
    library,
    species,
    add,
    agent,
    pub fn title(self: Tab) []const u8 {
        return switch (self) {
            .library => "Library",
            .species => "Species",
            .add => "Add",
            .agent => "Agent",
        };
    }
};
pub fn draw(current: *Tab) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer bar.deinit();
    const icons = [_][]const u8{ dvui.entypo.images, dvui.entypo.leaf, dvui.entypo.plus, dvui.entypo.user };
    inline for (@typeInfo(Tab).@"enum".field_names, 0..) |name, i| {
        const tab: Tab = @field(Tab, name);
        const selected = current.* == tab;
        const fill = if (selected) theme.orange[0] else theme.card;
        const text = if (selected) theme.card else theme.tab_off_ink;
        var button: dvui.ButtonWidget = undefined;
        button.init(@src(), .{}, .{ .id_extra = i, .min_size_content = .{ .w = 52, .h = 44 }, .max_size_content = .width(52), .padding = .all(0), .margin = .all(0), .border = .all(2), .corners = .round(0), .color_fill = .{ .color = fill }, .color_fill_hover = .{ .color = fill }, .color_fill_press = .{ .color = fill }, .color_text = .{ .color = text }, .color_border = .{ .color = theme.border } });
        defer button.deinit();
        button.processEvents();
        button.drawBackground();
        var stack = dvui.box(@src(), .{ .dir = .vertical }, .{ .gravity_x = 0.5, .gravity_y = 0.5 });
        dvui.icon(@src(), "tab", icons[i], .{}, .{ .min_size_content = .{ .w = 18, .h = 18 }, .gravity_x = 0.5, .color_text = .{ .color = text } });
        dvui.labelNoFmt(@src(), tab.title(), .{}, .{ .font = dvui.Font.theme(.body).withSize(12), .gravity_x = 0.5, .color_text = .{ .color = text } });
        stack.deinit();
        if (button.clicked()) current.* = tab;
    }
}
