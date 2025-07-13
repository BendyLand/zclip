const std = @import("std");
const cb = @import("clipboard.zig");
const sqlite = @import("sqlite");

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

    pub fn set(self: *MasterList, key: []const u8, value: u16) !void {
        if (self.items.contains(key)) return;
        const copy = try self.allocator.dupe(u8, key);
        try self.items.put(copy, value);
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

pub const DB = struct {
    db: sqlite.Db,

    pub fn init() !DB {
        const db = try sqlite.Db.init(.{
            .mode = sqlite.Db.Mode{ .File = "/tmp/zclip.db" },
            .open_flags = .{
                .write = true,
                .create = true,
            },
            .threading_mode = .MultiThread,
        });
        return DB{ .db = db };
    }

    pub fn saveEntries(self: *DB, entries: *MasterList) !void {
        const createQuery =
            \\CREATE TABLE IF NOT EXISTS clipboard (
            \\    id INTEGER NOT NULL,
            \\    text TEXT UNIQUE NOT NULL PRIMARY KEY
            \\);
        ;
        var createStmt = try self.db.prepare(createQuery);
        defer createStmt.deinit();
        createStmt.exec(.{}, .{}) catch |err| {
            std.debug.print("Unable to create sqlite db for clipboard entries: {any}\n", .{err});
            return error.TableNotCreated;
        };
        const clearQuery = "DELETE FROM clipboard";
        var clearStmt = try self.db.prepare(clearQuery);
        defer clearStmt.deinit();
        try clearStmt.exec(.{}, .{});
        const insertQuery = "INSERT INTO clipboard (id, text) VALUES (?, ?)";
        var insertStmt = try self.db.prepare(insertQuery);
        defer insertStmt.deinit();
        var it = entries.items.keyIterator();
        while (it.next()) |item| {
            const id = entries.items.get(item.*);
            insertStmt.reset();
            try insertStmt.exec(.{}, .{
                .id = @as(i64, id.?),
                .text = item.*,
            });
        }
    }

    pub fn loadEntries(self: *DB, master: *MasterList, allocator: std.mem.Allocator) !void {
        const Entry = struct {
            id: u16,
            text: []const u8,
        };
        const query = "SELECT * FROM clipboard;";
        var stmt = try self.db.prepare(query);
        defer stmt.deinit();
        const entries = try stmt.all(Entry, allocator, .{}, .{});
        master.items.clearRetainingCapacity();
        for (entries) |entry| {
            try master.set(entry.text, entry.id);
        }
    }
};

