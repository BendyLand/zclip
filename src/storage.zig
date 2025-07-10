const std = @import("std");
const cb = @import("clipboard.zig");

pub const Tray = struct {
    items: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) Tray {
        return Tray{
            .items = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Tray) void {
        for (self.items.items) |item| {
            self.items.allocator.free(item);
        }
        self.items.deinit();
    }

    pub fn setFromMap(self: *Tray, map: *const std.StringHashMap(u16)) !void {
        for (self.items.items) |item| {
            self.items.allocator.free(item);
        }
        try self.items.resize(map.count());
        var it = map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const copied = try self.items.allocator.dupe(u8, key);
            try self.items[entry.value_ptr.*](copied);
        }
    }
};

pub const MasterList = struct {
    items: std.StringHashMap(u16),
    allocator: std.mem.Allocator,
    latest: u16 = 0,

    pub fn init(allocator: std.mem.Allocator) MasterList {
        return MasterList{
            .items = std.StringHashMap(u16).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn add(self: *MasterList, value: []const u8) !void {
        if (self.items.contains(value)) return;
        const copy = try self.allocator.dupe(u8, value);
        try self.items.put(copy, self.latest);
        self.latest += 1;
    }

    pub fn contains(self: *MasterList, value: []const u8) bool {
        return self.items.contains(value);
    }

    pub fn deinit(self: *MasterList) void {
        self.items.deinit();
    }

    pub fn updateTray(self: *MasterList, tray: *Tray) !void {
        try tray.items.resize(0); // Clear
        // Collect key-value pairs into a temp array
        var temp = try tray.items.allocator.alloc(struct {
            text: []const u8,
            index: u16,
        }, self.items.count());
        defer tray.items.allocator.free(temp);
        var it = self.items.iterator();
        var i: usize = 0;
        while (it.next()) |entry| {
            temp[i] = .{
                .text = entry.key_ptr.*,
                .index = entry.value_ptr.*,
            };
            i += 1;
        }
        // Sort entries by insertion index
        tray.items = try sortKeysByValue(self.*.allocator, self.items);
    }

    pub fn sortKeysByValue(
        allocator: std.mem.Allocator,
        map: std.StringHashMap(u16),
    ) !std.ArrayList([]const u8) {
        var list = std.ArrayList([]const u8).init(allocator);
        var it = map.keyIterator();
        while (it.next()) |key| {
            try list.append(key.*);
        }
        const Ctx = struct {
            map: std.StringHashMap(u16),
            pub fn lessThan(self: @This(), a: []const u8, b: []const u8) bool {
                return self.map.get(a).? < self.map.get(b).?;
            }
        };
        std.mem.sort([]const u8, list.items, Ctx{ .map = map }, Ctx.lessThan);
        return list;
    }
};

