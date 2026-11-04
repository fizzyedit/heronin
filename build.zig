const std = @import("std");
const fizzy = @import("fizzy");
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });
    const fizzy_dep = b.dependency("fizzy", .{ // TODO(web-storage)
        .target = target,
        .optimize = optimize,
        .@"defer-app" = true,
        .@"app-name" = @as([]const u8, "heronin"),
        .@"app-display-name" = @as([]const u8, "Heronin"),
        .@"app-layout" = b.path("layout.zon"),
        .@"dynamic-plugins" = false,
        .@"workbench-file-tree" = false,
        .@"app-registry-url" = @as([]const u8, ""),
        .@"app-issues-url" = @as([]const u8, ""),
    });
    const manifest = try std.Io.Dir.cwd().readFileAlloc(b.graph.io, try b.root.joinString(b.allocator, "app/plugin.zig.zon"), b.allocator, .unlimited);
    const app = b.createModule(.{ .root_source_file = b.path("app/plugin.zig"), .target = target, .optimize = optimize });
    app.addAnonymousImport("plugin_zon", .{ .root_source_file = b.path("app/plugin.zig.zon") });
    app.addOptions(fizzy.plugin.plugin_options_import, fizzy.plugin.pluginOptions(b, "heronin", "Heronin", "0.1.0", "", manifest));
    const built = try fizzy.addApp(fizzy_dep, &.{ fizzy.plugins.workbench, .{ .name = "heronin", .module = app } });
    const install = b.addInstallArtifact(built.exe, .{});
    b.getInstallStep().dependOn(&install.step);
    b.step("native", "Build the native app").dependOn(&install.step);
    try fizzy.addWebSteps(b, fizzy_dep);
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("model/model_tests.zig"), .target = target, .optimize = optimize }) });
    tests.root_module.addImport("theme", b.createModule(.{ .root_source_file = b.path("app/theme.zig"), .target = target, .optimize = optimize }));
    tests.root_module.import_table.get("theme").?.addImport("dvui", fizzy.framework(fizzy_dep, .native).dvui);
    b.step("test", "Test models and theme").dependOn(&b.addRunArtifact(tests).step);
    b.step("check-public", "Compile the public app surface").dependOn(&built.exe.step);
}
