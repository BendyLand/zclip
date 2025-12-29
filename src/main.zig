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
        var command: cmd.Command = undefined;
        if (std.mem.eql(u8, arg, "push")) {
            // No argument? Try to read from stdin
            var stdin_reader = std.io.getStdIn().reader();
            var value = try stdin_reader.readAllAlloc(pg_alloc, 1024 * 1024);
            value = @constCast(std.mem.trimEnd(u8, value, " \n"));
            command = cmd.Command{ .Push = value };
        }
        else if (std.mem.eql(u8, arg, "help")) {
            std.debug.print(daemon.HELP_MSG ++ "\n", .{});
            return;
        }
        else {
            command = cmd.parse(arg, pg_alloc) catch |err| {
                const writer = std.io.getStdErr().writer();
                if (err == error.UnknownCommand) {
                    _ = try writer.write("Unknown command. To see a list of valid commands, please run `zclip help`.\n");
                }
                else std.debug.print("Unable to send command to daemon: {any}\n", .{err});
                std.posix.exit(1);
            };
        }
        daemon.sendCommandToDaemon(command) catch |err| {
            const writer = std.io.getStdErr().writer();
            if (err == error.FileNotFound) {
                if (command == .On) {
                    _ = try writer.write("false\n\n");
                    return;
                }
                _ = try writer.write("Daemon not running. Please run `zclip` with no arguments to start it.\n");
            }
            else if (err == error.ConnectionRefused) {
                _ = try writer.write("Daemon crashed at some point.\nPlease manually remove `/tmp/zclip.sock` to restore functionality.\nYou may also check `/tmp/zclip.log` to see what happened.\n");
            }
            else std.debug.print("Unable to send command to daemon: {any}\n", .{err}); 
            std.posix.exit(1);
        };
    }
}

