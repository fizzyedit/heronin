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
    const web_step = &b.top_level_steps.get("web").?.step;
    const patch = b.addExecutable(.{ .name = "patch-index", .root_module = b.createModule(.{ .root_source_file = b.path("tools/patch_index.zig"), .target = b.graph.host, .optimize = optimize }) });
    const patch_run = b.addRunArtifact(patch);
    patch_run.addFileArg(fizzy_dep.namedLazyPath("web").path(b, "index.html"));
    const patched_page = patch_run.addOutputFileArg("index.html");
    const page_install = b.addInstallFileWithDir(patched_page, .{ .custom = "web" }, "index.html");
    for (web_step.dependencies.items) |dependency| page_install.step.dependOn(dependency);
    for ([_][]const u8{ "manifest.webmanifest", "sw.js" }) |name| {
        const copy = b.addInstallFileWithDir(b.path(b.fmt("web/{s}", .{name})), .{ .custom = "web" }, name);
        for (web_step.dependencies.items) |dependency| copy.step.dependOn(dependency);
        web_step.dependOn(&copy.step);
    }
    web_step.dependOn(&page_install.step);
    const checker_module = b.createModule(.{ .root_source_file = b.path("tools/check_public.zig"), .target = b.graph.host, .optimize = optimize });
    const checker = b.addExecutable(.{ .name = "check-public", .root_module = checker_module });
    const check_run = b.addRunArtifact(checker);
    check_run.setCwd(b.path("."));
    check_run.has_side_effects = true;
    const checker_tests = b.addTest(.{ .root_module = checker_module });
    const checker_test_run = b.addRunArtifact(checker_tests);
    checker_test_run.setCwd(b.path("."));
    checker_test_run.has_side_effects = true;
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("model/model_tests.zig"), .target = target, .optimize = optimize }) });
    tests.root_module.addImport("theme", b.createModule(.{ .root_source_file = b.path("app/theme.zig"), .target = target, .optimize = optimize }));
    tests.root_module.import_table.get("theme").?.addImport("dvui", fizzy.framework(fizzy_dep, .native).dvui);
    const test_step = b.step("test", "Test models, theme, and public rules");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&checker_test_run.step);
    b.step("check-public", "Check tracked files for private content").dependOn(&check_run.step);
}
