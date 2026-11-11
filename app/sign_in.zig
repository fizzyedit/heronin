const drive_link = @import("drive_link.zig");
const std = @import("std");
const core = @import("core");
const dvui = @import("dvui");
pub var account: Account = .{};
pub const Account = struct {
    state: enum { off, checking, signed_out, opening, signed_in } = if (@import("builtin").cpu.arch == .wasm32) .checking else .off,
    email: ?[]const u8 = null,
    failed: enum { none, popup, sign_out } = .none,
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    transport: ?core.vfs.http.Transport = null,
    base: []const u8 = "",
    job: ?core.vfs.http.Job = null,
    pub const deinit = deinitAccount;
};
fn deinitAccount(self: *Account) void {
    if (self.job) |job| self.transport.?.cancel(job);
    if (@import("builtin").cpu.arch == .wasm32) core.transport.WebOAuth.cancel();
    self.arena.deinit();
    self.* = .{};
}
pub fn ready() bool {
    return account.state == .signed_in or account.state == .off;
}
pub fn check(transport: core.vfs.http.Transport, base: []const u8) void {
    account.transport, account.base, account.state = .{ transport, base, .checking };
    send(.GET, "token");
}
fn send(method: core.vfs.http.Method, path: []const u8) void {
    if (account.job != null) return;
    const a = account.arena.allocator();
    const url = @import("tag_queue.zig").serverUrl(a, account.base, path) catch return answered(null, error.Io);
    account.job = account.transport.?.request(account.arena.child_allocator, .{ .method = method, .url = url }, answered, null) catch return answered(null, error.Io);
}
fn answered(_: ?*anyopaque, result: core.vfs.Error!core.vfs.http.Response) void {
    account.job = null;
    const response = result catch return failure();
    defer response.deinit(account.arena.child_allocator);
    if (account.state != .checking) {
        if (response.status == 204) {
            if (drive_link.link.host) |host| drive_link.link.give(host, "", 0);
            account.state, account.email = .{ .signed_out, null };
        } else failure();
        return;
    }
    account.state = if (response.status == 200) .checking else if (response.status == 502) .signed_in else if (response.status == 401) .signed_out else .off;
    if (response.status == 401) account.email = null;
    if (response.status != 200) return;
    const parsed = std.json.parseFromSlice(struct { email: []const u8, access_token: []const u8, expires_in: u32 }, account.arena.child_allocator, response.body, .{ .ignore_unknown_fields = true }) catch return failure();
    defer parsed.deinit();
    if (drive_link.link.host) |host| drive_link.link.give(host, parsed.value.access_token, parsed.value.expires_in);
    _ = account.arena.reset(.retain_capacity);
    account.email = account.arena.allocator().dupe(u8, parsed.value.email) catch null;
    account.state = .signed_in;
}
pub fn open() void {
    if (@import("builtin").cpu.arch == .wasm32) {
        account.state, account.failed = .{ .opening, .none };
        core.transport.WebOAuth.begin(account.arena.allocator(), "/heronin/api/login", opened, null) catch {};
    }
}
pub fn opened(_: ?*anyopaque, result: ?[]u8) void {
    if (result) |value| {
        account.arena.allocator().free(value);
        check(account.transport.?, account.base);
    } else {
        account.state, account.failed = .{ .signed_out, .popup };
    }
}
pub fn signOut() void {
    account.failed = .none;
    send(.POST, "logout");
}
pub fn lost() void {
    if (drive_link.link.host) |host| drive_link.link.give(host, "", 0);
    if (account.state == .signed_in) account.state = .signed_out;
}
pub fn button(id: usize) void {
    const opening = account.state == .opening;
    if (dvui.button(@src(), if (opening) "Signing in…" else "Sign in", .{ .grayed = opening }, .{ .id_extra = id, .tag = "heronin-sign-in", .min_size_content = .{ .h = 44 } }) and !opening) open();
}
pub fn banner() void {
    if (account.state != .signed_out and account.state != .opening) return;
    dvui.labelNoFmt(@src(), "Sign in with Google to tag photos and name places", .{}, .{});
    button(0);
    if (account.failed == .popup) dvui.labelNoFmt(@src(), "Sign-in did not finish. Allow pop-ups for this site and try again.", .{}, .{ .tag = "heronin-sign-in-note" });
}
fn failure() void {
    account.state, account.failed = if (account.state == .checking) .{ .off, .none } else .{ .signed_in, .sign_out };
}
pub fn step() void {
    if (account.job != null or account.state != .signed_in or (!drive_link.link.token_due and !drive_link.link.retry)) return;
    drive_link.link.token_due = false;
    drive_link.link.retry = false;
    check(account.transport.?, account.base);
}
