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
    const model = b.addModule("model", .{ .root_source_file = b.path("model/model.zig"), .target = target, .optimize = optimize });
    const app = b.createModule(.{ .root_source_file = b.path("app/plugin.zig"), .target = target, .optimize = optimize });
    app.addImport("model", model);
    const wire = b.addModule("wire", .{ .root_source_file = b.path("server/tagger.zig"), .target = target, .optimize = optimize });
    wire.addImport("model", model);
    app.addImport("wire", wire);
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
    tests.root_module.addImport("model", model);
    tests.root_module.addImport("theme", b.createModule(.{ .root_source_file = b.path("app/theme.zig"), .target = target, .optimize = optimize }));
    tests.root_module.import_table.get("theme").?.addImport("dvui", fizzy.framework(fizzy_dep, .native).dvui);
    const test_step = b.step("test", "Test models, theme, and public rules");
    const app_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("app/app_tests.zig"), .target = target, .optimize = optimize }) });
    app_tests.root_module.addImport("model", model);
    app_tests.root_module.addImport("wire", wire);
    // Match fizzy's headless UI tests: layout and widget checks need no SDL or GPU.
    const testing_dvui = fizzy_dep.builder.dependency("fizzy_sdk", .{}).builder.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .testing,
    }).module("dvui_testing");
    const native_core = fizzy.framework(fizzy_dep, .native).core;
    const testing_core = b.createModule(.{ .root_source_file = native_core.root_source_file, .target = target, .optimize = optimize });
    var core_imports = native_core.import_table.iterator();
    while (core_imports.next()) |entry| testing_core.addImport(entry.key_ptr.*, entry.value_ptr.*);
    testing_core.addImport("dvui", testing_dvui);
    // These core dependencies also carry dvui types; keep the test graph on one backend.
    for ([_][]const u8{ "glass", "replay" }) |name| {
        const original = native_core.import_table.get(name).?;
        const headless = b.createModule(.{ .root_source_file = original.root_source_file, .target = target, .optimize = optimize });
        var deps = original.import_table.iterator();
        while (deps.next()) |entry| headless.addImport(entry.key_ptr.*, entry.value_ptr.*);
        headless.addImport("dvui", testing_dvui);
        testing_core.addImport(name, headless);
    }
    const view_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("app/view_tests.zig"), .target = target, .optimize = optimize }) });
    app_tests.root_module.addImport("dvui", testing_dvui);
    app_tests.root_module.addImport("core", testing_core);
    view_tests.root_module.addImport("model", model);
    view_tests.root_module.addImport("wire", wire);
    view_tests.root_module.addImport("dvui", testing_dvui);
    view_tests.root_module.addImport("core", testing_core);
    const view_test_run = b.addRunArtifact(view_tests);
    test_step.dependOn(&view_test_run.step);
    test_step.dependOn(&b.addRunArtifact(app_tests).step);
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&checker_test_run.step);
    const server_model = b.createModule(.{ .root_source_file = b.path("model/model.zig"), .target = b.graph.host, .optimize = optimize });
    const server_module = b.createModule(.{ .root_source_file = b.path("server/main.zig"), .target = b.graph.host, .optimize = optimize });
    server_module.addImport("model", server_model);
    server_module.addAnonymousImport("fake_tags", .{ .root_source_file = b.path("tests/fixtures/fake_tags.json") });
    const server = b.addExecutable(.{ .name = "server", .root_module = server_module });
    b.step("server", "Install the tagging server").dependOn(&b.addInstallArtifact(server, .{}).step);
    const server_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("server/server_tests.zig"), .target = b.graph.host, .optimize = optimize }) });
    server_tests.root_module.addImport("model", server_model);
    server_tests.root_module.addAnonymousImport("fake_tags", .{ .root_source_file = b.path("tests/fixtures/fake_tags.json") });
    test_step.dependOn(&b.addRunArtifact(server_tests).step);
    b.step("check-public", "Check tracked files for private content").dependOn(&check_run.step);
}
