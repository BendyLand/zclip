const std = @import("std");
const cb = @import("clipboard.zig");
const storage = @import("storage.zig");
const cmd = @import("commands.zig");
const os = std.os;
const fs = std.fs;

pub const HELP_MSG =
    \\Welcome to the zclip help menu!
    \\Run `zclip` with no arguments to start the daemon.
    \\Once running, it continuously monitors the system clipboard and tracks new entries automatically.
    \\
    \\Available commands:
    \\  push <entry>     - Manually add an entry to the clipboard
    \\  get <number>     - Set your system clipboard to the contents of a saved entry
    \\                     (Tip: use `zclip list` to see entry numbers)
    \\  list             - Show all currently saved entries
    \\  clear            - Remove all saved items from the list
    \\                     (Note: the current system clipboard becomes the new first entry)
    \\  reset            - Shortcut for: zclip push "" -> zclip get 10000 -> zclip clear
    \\                     (Effectively empties both clipboard *and* saved list)
    \\  help             - Print this help menu
    \\  exit             - Shut down the daemon and wipe all saved entries
    \\
    \\Troubleshooting:
    \\  If commands fail, the daemon may have crashed or exited uncleanly.
    \\  - Remove `/tmp/zclip.sock` manually
    \\  - Restart the daemon by running `zclip` again
    \\  - Check `/tmp/zclip.log` for logs
    \\
;


const sockaddr_un = extern struct {
    family: std.posix.sa_family_t,
    path: [108]u8,
};

fn makeSockAddrUn(path: []const u8) sockaddr_un {
    var addr = std.mem.zeroInit(sockaddr_un, .{});
    addr.family = std.posix.AF.UNIX;
    std.mem.copyForwards(u8, addr.path[0..path.len], path);
    return addr;
}

pub fn runDaemon(allocator: std.mem.Allocator) !void {
    _ = cb.c.signal(cb.c.SIGCHLD, handle_sigchld);
    var clipboard = try cb.ClipboardContext.init();
    defer clipboard.deinit();
    var tray = storage.Tray.init(allocator);
    defer tray.deinit();
    var master = storage.MasterList.init(allocator);
    defer master.deinit();
    const socket_path = "/tmp/zclip.sock";
    const listener_fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(listener_fd);
    const sockaddr = makeSockAddrUn(socket_path);
    const sockaddr_ptr = @as(*const std.posix.sockaddr, @ptrCast(&sockaddr));
    const sockaddr_len = @as(std.posix.socklen_t, @intCast(@sizeOf(sockaddr_un)));
    try std.posix.bind(listener_fd, sockaddr_ptr, sockaddr_len);
    try std.posix.listen(listener_fd, 10);
    std.debug.print("Daemon listening on {s}\n", .{socket_path});
    // Set up XFixes
    var xfixes_event_base: c_int = 0;
    var xfixes_error_base: c_int = 0;
    if (cb.c.XFixesQueryExtension(clipboard.display, &xfixes_event_base, &xfixes_error_base) == 0) {
        return error.XFixesNotAvailable;
    }
    // Register for clipboard selection change notifications
    const clipboard_atom = cb.c.XInternAtom(clipboard.display, "CLIPBOARD", 0);
    cb.c.XFixesSelectSelectionInput(
        clipboard.display,
        clipboard.window, // invisible window that owns the clipboard selection
        clipboard_atom,
        cb.c.XFixesSetSelectionOwnerNotifyMask,
    );
    var conn_buf: [1024 * 1024]u8 = undefined;
    const POLLIN = 0x001;
    const PollFd = cb.c.struct_pollfd;
    var poll_fds: [2]PollFd = .{
        .{ .fd = cb.c.XConnectionNumber(clipboard.display), .events = POLLIN, .revents = 0 },
        .{ .fd = listener_fd, .events = POLLIN, .revents = 0 },
    };
    var last_clip_owner: cb.c.Window = 0;
    const poll_interval_ns = std.time.ns_per_s; // Poll every 1 second
    var last_poll = try std.time.Instant.now();
    const EINTR = 4; // POSIX standard: Interrupted system call
    while (true) {
        const ready = blk: {
            while (true) {
                const rc = cb.c.poll(&poll_fds, poll_fds.len, 100); // small timeout
                if (rc >= 0) break :blk rc;
                const errno = std.posix.errno(rc);
                if (@intFromEnum(errno) == EINTR) {
                    std.debug.print("poll() interrupted by signal, retrying...\n", .{});
                    continue;
                }
                std.debug.print("poll() failed with errno {}: {any}\n", .{ errno, errno });
                return error.PollFailed;
            }
        };
        if (ready <= 0) continue;
        const now = try std.time.Instant.now();
        // Handle clipboard change via XFixes event
        if (poll_fds[0].revents & POLLIN != 0) {
            var event: cb.c.XEvent = undefined;
            while (cb.c.XPending(clipboard.display) > 0) {
                _ = cb.c.XNextEvent(clipboard.display, &event);
                if (event.type == xfixes_event_base + cb.c.XFixesSelectionNotify) {
                    const current_owner = cb.c.XGetSelectionOwner(clipboard.display, clipboard_atom);
                    if (current_owner != last_clip_owner and current_owner != 0) {
                        last_clip_owner = current_owner;
                        const polled = clipboard.captureClipboard(&allocator) catch null;
                        if (polled) |text| {
                            if (!master.items.contains(text)) {
                                try master.add(text);
                                try master.updateTray(&tray);
                            }
                        }
                    }
                }
            }
        }
        if (now.since(last_poll) >= std.time.ns_per_s) {
            last_poll = now;
            const polled = clipboard.captureClipboard(&allocator) catch null;
            if (polled) |text| {
                if (!master.items.contains(text)) {
                    try master.add(text);
                    try master.updateTray(&tray);
                }
            }
        }
        // Fallback polling every N seconds
        if (now.since(last_poll) >= poll_interval_ns) {
            last_poll = now;
            const current_owner = cb.c.XGetSelectionOwner(clipboard.display, clipboard_atom);
            if (current_owner != 0 and current_owner != last_clip_owner) {
                last_clip_owner = current_owner;
                const maybe_text = clipboard.captureClipboard(&allocator) catch null;
                if (maybe_text) |text| {
                    if (!master.items.contains(text)) {
                        try master.add(text);
                        try master.updateTray(&tray);
                    }
                }
            }
        }
        // Handle socket commands
        if (poll_fds[1].revents & POLLIN != 0) {
            const conn_fd = std.posix.accept(listener_fd, null, null, std.posix.SOCK.NONBLOCK) catch null;
            if (conn_fd) |fd| {
                defer std.posix.close(fd);
                const bytes_read = try std.posix.read(fd, &conn_buf);
                const input = conn_buf[0..bytes_read];
                const command = cmd.parse(input, allocator) catch {
                    _ = try std.posix.write(fd, "ERR Invalid Command\n");
                    continue;
                };
                try handleCommand(command, &master, &tray, fd, allocator);
            }
        }
    }
}

pub fn daemonize(log_path: []const u8, redirect_stdout: bool) !void {
    // First fork
    const fork_result = try std.posix.fork();
    if (fork_result < 0) return error.ForkFailed;
    if (fork_result > 0) std.posix.exit(0); // Parent exits
    // Start new session
    _ = std.os.linux.setsid();
    // Optional second fork (for double-fork daemonization)
    // const fork_result2 = try std.posix.fork();
    // if (fork_result2 > 0) std.posix.exit(0); // Optional double-fork
    // Redirect stdio to a log file
    const file = try std.fs.cwd().createFile(log_path, .{
        .truncate = true,
        .read = true,
    });
    const fd = file.handle;
    try std.posix.dup2(fd, std.io.getStdIn().handle);
    try std.posix.dup2(fd, std.io.getStdErr().handle);
    if (redirect_stdout) {
        try std.posix.dup2(fd, std.io.getStdOut().handle);
    }
    // Optionally: chdir to root to avoid blocking filesystem unmounts
    try std.posix.chdir("/");
}

fn handleCommand(
    command: cmd.Command,
    master: *storage.MasterList,
    tray: *storage.Tray,
    conn_fd: std.posix.fd_t,
    allocator: std.mem.Allocator,
) !void {
    switch (command) {
        .Push => |val| {
            try master.add(val);
            try master.updateTray(tray);
            _ = try std.posix.write(conn_fd, "OK\n");
        },
        .List => {
            var stream = std.io.fixedBufferStream(allocator.alloc(u8, 1024 * 1024 * 10) catch return); // temp buffer
            defer allocator.free(stream.buffer);
            // Items will be displayed starting from 1
            try master.updateTray(tray);
            var i: u8 = 0;
            for (tray.items.items) |item| {
                try stream.writer().print("{d}: {s}\n", .{ i + 1, item });
                i += 1;
            }
            _ = try std.posix.write(conn_fd, stream.getWritten());
        },
        .Get => |idx| {
            var index = idx;
            if (idx <= 0) index = 1 else if (idx >= tray.items.items.len) index = tray.items.items.len;
            index -= 1;
            const val = tray.items.items[index];
            // Write response *before* forking
            _ = try std.posix.write(conn_fd, val);
            _ = try std.posix.write(conn_fd, "\n");
            // Fork and daemonize
            if (try std.posix.fork() == 0) {
                // In child
                std.posix.close(conn_fd);
                try daemonize("/tmp/zclip-set.log", false);
                var cb2 = try cb.ClipboardContext.init();
                defer cb2.deinit();
                try cb.ClipboardContext.setClipboard(&cb2, val);
                std.posix.exit(0);
            }
        },
        .Clear => {
            tray.*.items.items.len = 0;
            master.*.items.clearRetainingCapacity();
            master.*.latest = 0;
            _ = try std.posix.write(conn_fd, "OK Cleared\n");
        },
        .Exit => {
            _ = try std.posix.write(conn_fd, "Goodbye\n");
            try fs.cwd().deleteFile("/tmp/zclip.sock");
            std.debug.print("Shutting down zclip daemon\n", .{});
            std.posix.exit(0); // or break the loop
        },
        .Help => {
            _ = try std.posix.write(conn_fd, HELP_MSG);
        },
        .Reset => {
            try master.add("");
            try master.updateTray(tray);
            if (tray.items.items.len == 0) {
                _ = try std.posix.write(conn_fd, "ERR No items in tray\n");
                return;
            }
            // .Get = 10000 will wrap to the last valid index in the current list
            // (unless someone manages to fit 10000 unique items in their list without an OOM error)
            try handleCommand(cmd.Command{ .Get = 10000 }, master, tray, conn_fd, allocator);
            tray.*.items.items.len = 0;
            master.*.items.clearRetainingCapacity();
            master.*.latest = 0;
        },
    }
}

pub fn safeToStartDaemon() !bool {
    const sock_path = "/tmp/zclip.sock";
    const stat_result = std.fs.cwd().statFile(sock_path);
    if (stat_result) |res| {
        std.debug.print("zclip daemon is already running or crashed uncleanly: {any}\n", .{res});
        return false;
    }
    else |err| {
        if (err != error.FileNotFound) return false;
        // It's safe to proceed — no existing socket
        return true;
    }
    return false;
}

pub fn sendCommandToDaemon(command: cmd.Command) !void {
    const socket_path = "/tmp/zclip.sock";
    // Create socket
    const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(fd);
    // Prepare address
    const sockaddr = makeSockAddrUn(socket_path);
    const sockaddr_ptr = @as(*const std.posix.sockaddr, @ptrCast(&sockaddr));
    const sockaddr_len = @as(std.posix.socklen_t, @intCast(@sizeOf(sockaddr_un)));
    // Connect to daemon
    try std.posix.connect(fd, sockaddr_ptr, sockaddr_len);
    // Send command
    const msg = cmd.toSocketMessage(command);
    _ = try std.posix.write(fd, msg);
    // Optionally: read a response
    var buf: [1024 * 1024]u8 = undefined;
    const n = try std.posix.read(fd, &buf);
    const response = buf[0..n];
    std.debug.print("Daemon responded:\n{s}\n", .{response});
}

fn handle_sigchld(_: c_int) callconv(.C) void {
    // Loop to reap all dead children
    while (true) {
        const pid = std.c.waitpid(-1, null, std.c.W.NOHANG);
        if (pid <= 0) break;
    }
}

