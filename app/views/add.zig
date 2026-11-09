const std = @import("std");
const dvui = @import("dvui");
const imports = @import("../import_queue.zig");
const theme = @import("../theme.zig");
const lib = @import("library.zig");
var too_many = false;
var cloud = false;
var open_picker = false;
pub fn pick(queue: *imports.Queue) void {
    const requested = open_picker;
    open_picker = false;
    if (requested) too_many = false;
    var names: [10][]const u8 = undefined;
    var bytes: [10][]u8 = undefined;
    var n: usize = 0;
    if (comptime @import("builtin").target.cpu.arch == .wasm32) {
        const id = dvui.Id.extendId(null, @src(), 0);
        if (requested) dvui.dialogWasmFileOpenMultiple(id, .{ .accept = "image/jpeg" });
        const files = dvui.wasmFileUploadedMultiple(id) orelse return;
        if (files.len > 10) {
            too_many = true;
            return;
        }
        for (files) |file| {
            const data = file.readData(queue.allocator) catch continue;
            const name = queue.allocator.dupe(u8, file.name) catch {
                queue.allocator.free(data);
                continue;
            };
            names[n] = name;
            bytes[n] = data;
            n += 1;
        }
    } else {
        if (!requested) return;
        const paths = (dvui.dialogNativeFileOpenMultiple(dvui.currentWindow().arena(), .{ .filters = &.{ "*.jpg", "*.jpeg" }, .filter_description = "photos" }) catch return) orelse return;
        if (paths.len > 10) {
            too_many = true;
            return;
        }
        for (paths) |path| {
            const data = std.Io.Dir.cwd().readFileAlloc(dvui.io, path, queue.allocator, .unlimited) catch continue;
            const name = queue.allocator.dupe(u8, std.fs.path.basename(path)) catch {
                queue.allocator.free(data);
                continue;
            };
            names[n] = name;
            bytes[n] = data;
            n += 1;
        }
    }
    queue.add(names[0..n], bytes[0..n]) catch |err| {
        too_many = err == error.TooMany;
        for (names[0..n], bytes[0..n]) |name, data| {
            queue.allocator.free(name);
            queue.allocator.free(data);
        }
    };
}
pub fn draw(queue: *imports.Queue, state: *lib.State, store: @import("../store.zig").Store) void {
    queue.step(store);
    if (queue.busy) dvui.refresh(null, @src(), null);
    dvui.labelNoFmt(@src(), "Add photos", .{}, .{ .font = dvui.Font.theme(.title), .color_text = .{ .color = theme.red[0] } });
    inline for (.{ "Camera", "From phone gallery", "Folder or cloud" }, 0..) |title, i| {
        if (dvui.button(@src(), title, .{}, .{ .id_extra = i, .min_size_content = .{ .h = 44 }, .expand = .horizontal, .color_fill = .{ .color = if (i == 0) theme.orange[0] else theme.chip }, .color_text = .{ .color = if (i == 0) theme.card else theme.ink } })) {
            if (i == 2) cloud = true else {
                open_picker = true;
                pick(queue);
            }
        }
    }
    if (cloud) lib.label("Save photos into the Heronin folder in Google Drive");
    if (too_many) lib.label("Pick up to 10 photos at a time.");
    const counts = imports.counts(queue.rows.items, state.items);
    if (counts.total == 0) return;
    lib.label(lib.fmt("Adding {d} photos, {d} done", .{ counts.total, counts.finished }));
    const width = dvui.parentGet().data().rect.w;
    var track = dvui.box(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .h = 12 }, .background = true, .color_fill = .{ .color = theme.chip } });
    var bar = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = width * @as(f32, @floatFromInt(counts.finished)) / @as(f32, @floatFromInt(counts.total)), .h = 12 }, .background = true, .color_fill = .{ .color = theme.olive[0] } });
    bar.deinit();
    track.deinit();
    inline for (.{ counts.tagged, counts.review, counts.skipped }, .{ "tagged", "need a look", "not a bird" }, .{ theme.olive[0], theme.mustard[2], theme.chip }, .{ theme.card, theme.ink, theme.brown[0] }) |n, word, fill, ink| {
        dvui.labelNoFmt(@src(), lib.fmt("{d} {s}", .{ n, word }), .{}, .{ .background = true, .color_fill = .{ .color = fill }, .color_text = .{ .color = ink } });
    }
    if (counts.review > 0 and dvui.button(@src(), lib.fmt("Review {d} that need a look", .{counts.review}), .{}, .{ .min_size_content = .{ .h = 44 } })) {
        state.filter = .review;
        @import("../plugin.zig").current = .library;
    }
    lib.label("QUEUE");
    var scroll = @import("core").widgets.ScrollArea.init(@src(), .{ .horizontal = .none }, .{ .expand = .both });
    defer scroll.deinit();
    for (queue.rows.items, 0..) |row, i| {
        var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = i, .expand = .horizontal, .background = true, .color_fill = .{ .color = theme.washes[i % 6] } });
        defer box.deinit();
        lib.label(row.name);
        if (row.err) |err| lib.label(@errorName(err));
        if (row.state == .imported) {
            var status: @import("model").Photo.State = .new;
            for (state.items) |item| {
                if (std.mem.eql(u8, item.photo.id, row.photo_id orelse "")) {
                    status = item.photo.state;
                    break;
                }
            }
            lib.badge(status);
        } else {
            const style = switch (row.state) {
                .uploading => theme.working,
                .failed => theme.failed,
                else => theme.waiting,
            };
            const word = switch (row.state) {
                .uploading => "Uploading",
                .already_there => "Already there",
                .failed => "Failed",
                else => "Waiting",
            };
            dvui.labelNoFmt(@src(), word, .{}, .{ .background = true, .color_fill = .{ .color = style.fill }, .color_text = .{ .color = style.ink } });
        }
    }
}
