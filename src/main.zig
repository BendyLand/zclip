const std = @import("std");
const cmd = @import("commands.zig");
const daemon = @import("daemon.zig");
const Alloc = std.mem.Allocator;
var pg_alloc = std.heap.page_allocator;

pub fn main() !void {
    const args = try std.process.argsAlloc(pg_alloc);
    defer std.process.argsFree(pg_alloc, args);
    if (args.len == 1) {
        if (try daemon.safeToStartDaemon()) {
            // No args → run in daemon mode
            daemon.daemonize("/tmp/zclip.log", true) catch |err| {
                std.debug.print("Failed to daemonize: {any}\n", .{err});
                return;
            };
            try daemon.runDaemon(pg_alloc);
        }
    }
    else {
        // Args given → run in sender mode
        const arg = try std.mem.join(pg_alloc, " ", args[1..]);
        const command = try cmd.parse(arg, pg_alloc); 
        try daemon.sendCommandToDaemon(command); 
    }
}

