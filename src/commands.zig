const std = @import("std");
const Alloc = std.mem.Allocator;
const pg_alloc = std.heap.page_allocator;

pub const INPUT_MAX: comptime_int = 1024;

pub const Command = union(enum) {
    Get: usize,
    Push: []const u8,
    List,
    Clear,
    Exit,
};

pub fn parse(input: []const u8, allocator: std.mem.Allocator) !Command {
    var it = std.mem.tokenizeScalar(u8, input, ' ');
    const cmd = it.next() orelse return error.EmptyCommand;
    var result: Command = undefined;
    if (std.mem.eql(u8, "get", cmd)) {
        const index_str = it.next() orelse return error.MissingArgument;
        const index = try std.fmt.parseInt(usize, index_str, 10);
        result = Command{ .Get = index };
    }
    else if (std.mem.eql(u8, "push", cmd)) {
        const rest = it.rest(); // everything after "push"
        const copied = try allocator.dupe(u8, rest);
        result = Command{ .Push = copied };
    }
    else if (std.mem.eql(u8, "list", cmd)) result = Command.List else if (std.mem.eql(u8, "clear", cmd)) result = Command.Clear else if (std.mem.eql(u8, "exit", cmd)) result = Command.Exit else return error.UnknownCommand;
    return result;
}

pub fn toSocketMessage(self: Command) []const u8 {
    return switch (self) {
        .Get => |i| std.fmt.allocPrintZ(std.heap.page_allocator, "get {d}", .{i}) catch "ERR",
        .Push => |s| std.fmt.allocPrintZ(std.heap.page_allocator, "push {s}", .{s}) catch "ERR",
        .List => "list",
        .Clear => "clear",
        .Exit => "exit",
    };
}

pub fn getInput(dest: *[]u8, allocator: Alloc) !void {
    var reader = std.io.getStdIn().reader();
    const buf = try reader.readUntilDelimiterAlloc(allocator, '\n', INPUT_MAX);
    defer Alloc.free(allocator, buf);
    std.mem.copyForwards(u8, dest.*, buf);
}

