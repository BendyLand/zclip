const std = @import("std");
const cb = @import("clipboard.zig");
const wl = @import("wayland.zig");
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
    \\  push <entry>     - Manually add an entry to the clipboard.
    \\                     (Note: the system clipboard is *not* automatically updated when adding from a pipe.)
    \\  pipe             - Like `push`, but specifically for use in a pipe; automatically updates the system clipboard.
    \\                     (Note: `zclip pipe <entry>` will not work; it is *only* for use in pipes.)
    \\  get  <number>    - Set your system clipboard to the contents of a saved entry.
    \\                     (Tip: use `zclip list` to see entry numbers.)
    \\  last             - Alias for `zclip get 10000`; effectively gets most recently saved value.
    \\  list [flag]      - Print all currently saved entries; including a flag will show full entries.
    \\                     (Valid flags: -v, --verbose, full, all.)
    \\  len              - Print the number of saved entries.
    \\  on               - Prints whether or not the daemon is already running.
    \\  save             - Save all currently saved entries to persistent storage.
    \\                     (stored in /tmp/zclip.db)
    \\  load             - Load saved entries from persistent storage into memory.
    \\  clear            - Remove all saved items from the list.
    \\                     (Note: the current system clipboard becomes the new first entry.)
    \\  reset            - Shortcut for: zclip push "" -> zclip get 10000 -> zclip clear.
    \\                     (Effectively empties both clipboard *and* saved list.)
    \\  help             - Print this help menu.
    \\  exit             - Shut down the daemon and wipe all saved entries.
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

pub fn runDaemon(allocator: std.mem.Allocator, use_wayland: bool) !void {
    _ = cb.c.signal(cb.c.SIGCHLD, handle_sigchld);
    // Initialise whichever backend we need.
    var clipboard: ?cb.ClipboardContext = if (!use_wayland) try cb.ClipboardContext.init() else null;
    defer if (clipboard) |*ctx| ctx.deinit();
    var watcher: ?std.process.Child = if (use_wayland) try wl.spawnWatcher(allocator) else null;
    defer if (watcher) |*w| {
        _ = w.kill() catch {};
        _ = w.wait() catch {};
    };
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
    std.debug.print("Daemon listening on {s} (backend: {s})\n", .{
        socket_path,
        if (use_wayland) "wayland" else "x11",
    });
    // X11-only: set up XFixes selection-change notifications.
    var xfixes_event_base: c_int = 0;
    var xfixes_error_base: c_int = 0;
    var clipboard_atom: cb.c.Atom = 0;
    var last_clip_owner: cb.c.Window = 0;
    var last_poll = try std.time.Instant.now();
    const poll_interval_ns = std.time.ns_per_s;

    if (!use_wayland) {
        if (cb.c.XFixesQueryExtension(clipboard.?.display, &xfixes_event_base, &xfixes_error_base) == 0) {
            return error.XFixesNotAvailable;
        }
        clipboard_atom = cb.c.XInternAtom(clipboard.?.display, "CLIPBOARD", 0);
        cb.c.XFixesSelectSelectionInput(
            clipboard.?.display,
            clipboard.?.window,
            clipboard_atom,
            cb.c.XFixesSetSelectionOwnerNotifyMask,
        );
    }
    // fd[0] is the X11 display connection (X11) or the wl-paste --watch pipe (Wayland).
    const monitor_fd: i32 = if (use_wayland)
        @intCast(watcher.?.stdout.?.handle)
    else
        cb.c.XConnectionNumber(clipboard.?.display);
    var conn_buf: [1024 * 1024]u8 = undefined;
    const POLLIN = 0x001;
    const PollFd = cb.c.struct_pollfd;
    var poll_fds: [2]PollFd = .{
        .{ .fd = monitor_fd, .events = POLLIN, .revents = 0 },
        .{ .fd = listener_fd, .events = POLLIN, .revents = 0 },
    };
    // persistent accumulation buffer for Wayland pipe reads;
    // avoids partial-read splits when a single clipboard entry
    //   spans multiple read() calls.
    var wl_accum = std.ArrayList(u8).init(allocator);
    defer wl_accum.deinit();
    // track spawned wl-copy children so they can be killed on daemon shutdown.
    var wl_copies = std.ArrayList(std.process.Child).init(allocator);
    defer {
        for (wl_copies.items) |*child| {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
        }
        wl_copies.deinit();
    }
    const EINTR = 4;
    while (true) {
        const ready = blk: {
            while (true) {
                const rc = cb.c.poll(&poll_fds, poll_fds.len, 100);
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
        // handle monitor fd events.
        if (poll_fds[0].revents & POLLIN != 0) {
            if (use_wayland) {
                var read_buf: [64 * 1024]u8 = undefined;
                const n = std.posix.read(monitor_fd, &read_buf) catch 0;
                if (n == 0) {
                    std.debug.print("wl-paste watcher exited, shutting down daemon\n", .{});
                    return;
                }
                try wl_accum.appendSlice(read_buf[0..n]);
                // process every null-terminated message that has fully arrived.
                while (std.mem.indexOfScalar(u8, wl_accum.items, 0)) |null_pos| {
                    const chunk = wl_accum.items[0..null_pos];
                    const text = std.mem.trimRight(u8, chunk, "\n");
                    if (text.len > 0 and !master.items.contains(text)) {
                        try master.add(text);
                        try master.updateTray(&tray);
                    }
                    const consumed = null_pos + 1;
                    const leftover = wl_accum.items[consumed..];
                    std.mem.copyForwards(u8, wl_accum.items[0..leftover.len], leftover);
                    wl_accum.shrinkRetainingCapacity(leftover.len);
                }
            }
            else {
                // x11: process XFixes selection-owner-change events.
                var event: cb.c.XEvent = undefined;
                while (cb.c.XPending(clipboard.?.display) > 0) {
                    _ = cb.c.XNextEvent(clipboard.?.display, &event);
                    if (event.type == xfixes_event_base + cb.c.XFixesSelectionNotify) {
                        const current_owner = cb.c.XGetSelectionOwner(clipboard.?.display, clipboard_atom);
                        if (current_owner != last_clip_owner and current_owner != 0) {
                            last_clip_owner = current_owner;
                            const polled = clipboard.?.captureClipboard(&allocator) catch null;
                            if (polled) |text| {
                                defer allocator.free(text);
                                if (!master.items.contains(text)) {
                                    try master.add(text);
                                    try master.updateTray(&tray);
                                }
                            }
                        }
                    }
                }
            }
        }
        // x11-only fallback polling.
        if (!use_wayland) {
            if (now.since(last_poll) >= std.time.ns_per_s) {
                last_poll = now;
                const polled = clipboard.?.captureClipboard(&allocator) catch null;
                defer if (polled) |text| allocator.free(text);
                if (polled) |text| {
                    if (!master.items.contains(text)) {
                        try master.add(text);
                        try master.updateTray(&tray);
                    }
                }
            }
            if (now.since(last_poll) >= poll_interval_ns) {
                last_poll = now;
                const current_owner = cb.c.XGetSelectionOwner(clipboard.?.display, clipboard_atom);
                if (current_owner != 0 and current_owner != last_clip_owner) {
                    last_clip_owner = current_owner;
                    const maybe_text = clipboard.?.captureClipboard(&allocator) catch null;
                    if (maybe_text) |text| {
                        defer allocator.free(text);
                        if (!master.items.contains(text)) {
                            try master.add(text);
                            try master.updateTray(&tray);
                        }
                    }
                }
            }
        }
        // handle socket commands (same for both backends).
        if (poll_fds[1].revents & POLLIN != 0) {
            const conn_fd = std.posix.accept(listener_fd, null, null, 0) catch null;
            if (conn_fd) |fd| {
                defer std.posix.close(fd);
                const bytes_read = try std.posix.read(fd, &conn_buf);
                const input = conn_buf[0..bytes_read];
                const command = cmd.parse(input, allocator) catch {
                    _ = try std.posix.write(fd, "ERR Invalid Command\n");
                    continue;
                };
                try handleCommand(command, &master, &tray, fd, allocator, use_wayland, &wl_copies);
            }
        }
    }
}

pub fn daemonize(log_path: []const u8, redirect_stdout: bool) !void {
    // first fork
    const fork_result = try std.posix.fork();
    if (fork_result < 0) return error.ForkFailed;
    if (fork_result > 0) std.posix.exit(0); // Parent exits
    // start new session
    _ = std.os.linux.setsid();
    // optional second fork (for double-fork daemonization)
    // const fork_result2 = try std.posix.fork();
    // if (fork_result2 > 0) std.posix.exit(0); // optional double-fork
    // redirect stdio to a log file
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
    // optionally: chdir to root to avoid blocking filesystem unmounts
    try std.posix.chdir("/");
}

fn handleCommand(
    command: cmd.Command,
    master: *storage.MasterList,
    tray: *storage.Tray,
    conn_fd: std.posix.fd_t,
    allocator: std.mem.Allocator,
    use_wayland: bool,
    wl_copies: *std.ArrayList(std.process.Child),
) !void {
    switch (command) {
        .Push => |val| {
            try master.add(val);
            master.*.allocator.free(val);
            try master.updateTray(tray);
            _ = try std.posix.write(conn_fd, "OK\n");
        },
        .List => |maybeVal| {
            var showAll = false;
            if (maybeVal) |val| {
                const eql = std.mem.eql;
                if (eql(u8, val, "-v") or
                    eql(u8, val, "--verbose") or
                    eql(u8, val, "full") or
                    eql(u8, val, "all"))
                {
                    showAll = true;
                }
            }
            const mb: usize = if (showAll) 100 else 10;
            var stream = std.io.fixedBufferStream(allocator.alloc(u8, 1024 * 1024 * mb) catch return); // temp buffer
            defer allocator.free(stream.buffer);
            // items will be displayed starting from 1
            try master.updateTray(tray);
            var i: u8 = 0;
            for (tray.items.items) |item| {
                var line_it = std.mem.splitScalar(u8, item, '\n');
                var limited_lines = std.ArrayList([]const u8).init(allocator);
                defer limited_lines.deinit();
                const maxLines = 10;
                var count: usize = 0;
                while (line_it.next()) |line| : (count += 1) {
                    if (count < maxLines) {
                        try limited_lines.append(line);
                    }
                    else {
                        break;
                    }
                }
                var total_lines = count; // includes the ones we’ve seen
                while (line_it.next() != null) : (total_lines += 1) {} // count remaining
                if (total_lines > maxLines and !showAll) {
                    const head = try std.mem.join(allocator, "\n", limited_lines.items);
                    defer allocator.free(head);
                    try stream.writer().print(
                        "{d}: {s}\n({d} more lines...)\n",
                        .{ i + 1, head, total_lines - maxLines },
                    );
                }
                else {
                    try stream.writer().print("{d}: {s}\n", .{ i + 1, item });
                }
                i += 1;
            }
            _ = try std.posix.write(conn_fd, stream.getWritten());
        },
        .Get => |idx| {
            var index = idx;
            if (idx <= 0) index = 1 else if (idx >= tray.items.items.len) index = tray.items.items.len;
            index -= 1;
            const val = tray.items.items[index];
            _ = try std.posix.write(conn_fd, val);
            _ = try std.posix.write(conn_fd, "\n");
            if (use_wayland) {
                const copy_child = wl.setClipboard(allocator, val) catch |err| {
                    std.debug.print("wl-copy failed: {any}\n", .{err});
                    return;
                };
                // track the child so it is killed on daemon shutdown;
                // the SIGCHLD handler reaps it early when another app
                //   takes the selection.
                wl_copies.append(copy_child) catch {};
            }
            else {
                // fork a child that temporarily owns the X11 selection.
                if (try std.posix.fork() == 0) {
                    std.posix.close(conn_fd);
                    try daemonize("/tmp/zclip-set.log", false);
                    var cb2 = try cb.ClipboardContext.init();
                    defer cb2.deinit();
                    try cb.ClipboardContext.setClipboard(&cb2, val);
                    std.posix.exit(0);
                }
            }
        },
        .Pipe => {
            // NOOP when handled here; the logic lives in main
        },
        .Clear => {
            tray.*.items.items.len = 0;
            var it = master.*.items.iterator();
            while (it.next()) |item| {
                master.*.allocator.free(item.key_ptr.*);
            }
            master.*.items.clearRetainingCapacity();
            master.*.latest = 0;
            _ = try std.posix.write(conn_fd, "OK Cleared\n");
        },
        .Exit => {
            _ = try std.posix.write(conn_fd, "Goodbye\n");
            try fs.cwd().deleteFile("/tmp/zclip.sock");
            std.debug.print("Shutting down zclip daemon\n", .{});
            return error.Exit;
        },
        .Help => {
            _ = try std.posix.write(conn_fd, HELP_MSG);
        },
        .On => {
            _ = try std.posix.write(conn_fd, "true\n");
        },
        .Len => {
            const msg = try std.fmt.allocPrint(allocator, "{d}\n", .{tray.items.items.len});
            defer allocator.free(msg);
            _ = try std.posix.write(conn_fd, msg);
        },
        .Reset => {
            try master.items.put("", master.latest);
            try master.updateTray(tray);
            if (tray.items.items.len == 0) {
                _ = try std.posix.write(conn_fd, "ERR No items in tray\n");
                return;
            }
            // .Get = 10000 will wrap to the last valid index in the current list
            // (unless someone manages to fit 10000 unique items in their list without an OOM error)
            try handleCommand(cmd.Command{ .Get = 10000 }, master, tray, conn_fd, allocator, use_wayland, wl_copies);
            tray.*.items.items.len = 0;
            master.*.items.clearRetainingCapacity();
            master.*.latest = 0;
        },
        .Last => {
            try handleCommand(cmd.Command{ .Get = 10000 }, master, tray, conn_fd, allocator, use_wayland, wl_copies);
        },
        .Save => {
            var db = try storage.DB.init();
            db.saveEntries(master) catch {
                _ = try std.posix.write(conn_fd, "ERR Unable to create persistent storage\n");
                return;
            };
            _ = try std.posix.write(conn_fd, "OK\n");
        },
        .Load => {
            var db = try storage.DB.init();
            db.loadEntries(master, allocator) catch {
                _ = try std.posix.write(conn_fd, "ERR No saved entries found\n");
                return;
            };
            _ = try std.posix.write(conn_fd, "OK\n");
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
        // it's safe to proceed — no existing socket
        return true;
    }
    return false;
}

pub fn sendCommandToDaemon(command: cmd.Command) !void {
    const socket_path = "/tmp/zclip.sock";
    // create socket
    const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(fd);
    // prepare address
    const sockaddr = makeSockAddrUn(socket_path);
    const sockaddr_ptr = @as(*const std.posix.sockaddr, @ptrCast(&sockaddr));
    const sockaddr_len = @as(std.posix.socklen_t, @intCast(@sizeOf(sockaddr_un)));
    // connect to daemon
    try std.posix.connect(fd, sockaddr_ptr, sockaddr_len);
    // send command
    const msg = cmd.toSocketMessage(command);
    _ = try std.posix.write(fd, msg);
    // optionally: read a response
    var buf: [1024 * 1024]u8 = undefined;
    const n = try std.posix.read(fd, &buf);
    const response = buf[0..n];
    std.debug.print("Daemon responded:\n{s}\n", .{response});
}

fn handle_sigchld(_: c_int) callconv(.C) void {
    // loop to reap all dead children
    while (true) {
        const pid = std.c.waitpid(-1, null, std.c.W.NOHANG);
        if (pid <= 0) break;
    }
}

