const std = @import("std");
const skiplist = @import("skiplist.zig");
const types = @import("types.zig");
const config = @import("config.zig");

const Allocator = std.mem.Allocator;
const BytesContext = skiplist.BytesContext;

/// In-memory sorted table backed by a skip list.
/// When the size exceeds the configured maximum, it should be flushed to an SSTable.
pub const MemTable = struct {
    list: skiplist.SkipList([]const u8, []const u8, BytesContext),
    size: usize,
    max_size: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator, max_size: usize) MemTable {
        return MemTable{
            .list = skiplist.SkipList([]const u8, []const u8, BytesContext).init(allocator, .{}),
            .size = 0,
            .max_size = max_size,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MemTable) void {
        self.list.deinit();
    }

    /// Put a key-value pair into the memtable.
    /// Returns true if the key was new (insert), false if it was an update.
    pub fn put(self: *MemTable, key: []const u8, value: []const u8) !bool {
        const is_new = try self.list.put(key, value);
        if (is_new) {
            self.size += key.len + value.len + @sizeOf(usize) * 2; // approximate memory cost
        }
        return is_new;
    }

    /// Get value by key. Returns null if not found.
    pub fn get(self: *const MemTable, key: []const u8) ?[]const u8 {
        return self.list.get(key);
    }

    /// Check if key exists
    pub fn contains(self: *const MemTable, key: []const u8) bool {
        return self.list.contains(key);
    }

    /// Delete a key. Returns true if key existed.
    pub fn delete(self: *MemTable, key: []const u8) bool {
        // Check if key exists (not marked as deleted)
        const existed = self.list.get(key) != null;
        // Insert a tombstone marker (replaces existing value if present)
        const is_new = self.list.put(key, "") catch false;
        if (is_new) {
            // New tombstone — add key cost only (empty value)
            self.size += key.len + @sizeOf(usize);
        }
        // If key existed, put replaced old value with "" — no size change needed
        // (old value memory was freed by skip list, new cost is approximately same)
        return existed;
    }

    /// Check if the memtable is full and needs to be flushed
    pub fn isFull(self: *const MemTable) bool {
        return self.size >= self.max_size;
    }

    /// Get number of entries
    pub fn count(self: *const MemTable) usize {
        return self.list.count();
    }

    /// Create an iterator
    pub fn iterator(self: *MemTable) skiplist.SkipList([]const u8, []const u8, BytesContext).Iterator {
        return self.list.iterator();
    }

    /// Create an iterator starting from a key >= the given key
    pub fn lowerBound(self: *MemTable, key: []const u8) skiplist.SkipList([]const u8, []const u8, BytesContext).Iterator {
        return self.list.lowerBound(key);
    }

    /// Clear all entries (used after flush to SSTable)
    pub fn clear(self: *MemTable) void {
        self.list.deinit();
        self.list = skiplist.SkipList([]const u8, []const u8, BytesContext).init(self.allocator, .{});
        self.size = 0;
    }

    /// Collect all entries sorted by key (for flushing to SSTable).
    /// Returns deep copies — caller owns the returned key/value memory.
    pub fn collectSorted(self: *MemTable) !std.ArrayList(Entry) {
        var entries = std.ArrayList(Entry).init(self.allocator);
        errdefer {
            for (entries.items) |e| {
                self.allocator.free(e.key);
                self.allocator.free(e.value);
            }
            entries.deinit();
        }

        var iter = self.iterator();
        while (iter.next()) |item| {
            try entries.append(.{
                .key = try self.allocator.dupe(u8, item.key),
                .value = try self.allocator.dupe(u8, item.value),
            });
        }
        return entries;
    }

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
    };
};

// Tests
test "MemTable put and get" {
    const allocator = std.testing.allocator;
    var mt = MemTable.init(allocator, 1024 * 1024);
    defer mt.deinit();

    _ = try mt.put("key1", "value1");
    _ = try mt.put("key2", "value2");

    try std.testing.expectEqualStrings("value1", mt.get("key1").?);
    try std.testing.expectEqualStrings("value2", mt.get("key2").?);
    try std.testing.expect(mt.get("missing") == null);
}

test "MemTable isFull" {
    const allocator = std.testing.allocator;
    var mt = MemTable.init(allocator, 100);
    defer mt.deinit();

    // Small memtable should become full quickly
    for (0..20) |i| {
        const key = try std.fmt.allocPrint(allocator, "key_{d}", .{i});
        defer allocator.free(key);
        const val = try std.fmt.allocPrint(allocator, "val_{d}", .{i});
        defer allocator.free(val);
        _ = try mt.put(key, val);
    }

    try std.testing.expect(mt.isFull());
}
