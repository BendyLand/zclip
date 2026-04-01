const std = @import("std");

/// Spawn `wl-paste --watch` with a null-byte separator between entries.
/// Each clipboard change writes `<content>\x00` to the returned child's stdout pipe.
/// Caller is responsible for killing/waiting the child on shutdown.
pub fn spawnWatcher(allocator: std.mem.Allocator) !std.process.Child {
    var child = std.process.Child.init(
        &.{ "wl-paste", "--watch", "sh", "-c", "cat; printf '\\x00'" },
        allocator,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    return child;
}

/// Set clipboard content using wl-copy. Spawns wl-copy in the background so
/// it can keep serving the Wayland selection until another app takes over.
/// The existing SIGCHLD handler in daemon.zig will reap it when it exits.
pub fn setClipboard(allocator: std.mem.Allocator, text: []const u8) !void {
    var child = std.process.Child.init(&.{"wl-copy"}, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    if (child.stdin) |stdin| {
        stdin.writeAll(text) catch {};
        stdin.close();
        child.stdin = null;
    }
    // do not wait — wl-copy must stay alive to serve the selection.
}
