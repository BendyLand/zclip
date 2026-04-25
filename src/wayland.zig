const std = @import("std");

/// Spawn `wl-paste --watch` with a null-byte separator between entries.
/// Each clipboard change writes `<content>\x00` to the returned child's stdout pipe.
/// Caller is responsible for killing/waiting the child on shutdown.
pub fn spawnWatcher(allocator: std.mem.Allocator) !std.process.Child {
    var child = std.process.Child.init(
        &.{ "wl-paste", "--watch", "sh", "-c", "cat; printf '\\000'" },
        allocator,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    return child;
}

/// Spawn wl-copy with the given text and return the child handle.
/// Caller appends it to wl_copies in daemon.zig so it is killed on shutdown;
/// the SIGCHLD handler reaps it early when another app takes the selection.
pub fn setClipboard(allocator: std.mem.Allocator, text: []const u8) !std.process.Child {
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
    return child;
}
