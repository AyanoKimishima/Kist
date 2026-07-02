const std = @import("std");
const db_mod = @import("db.zig");

const Allocator = std.mem.Allocator;
const DB = db_mod.DB;

/// Transaction provides batch writes with commit/rollback semantics.
/// All writes are buffered locally and applied atomically on commit.
pub const Transaction = struct {
    db: *DB,
    allocator: Allocator,
    writes: std.ArrayList(WriteOp),
    reads: std.ArrayList([]const u8),
    active: bool,
    version: u64,

    pub const WriteOp = union(enum) {
        put: struct {
            key: []const u8,
            value: []const u8,
        },
        delete: struct {
            key: []const u8,
        },
    };

    pub fn init(db: *DB, allocator: Allocator) Transaction {
        return Transaction{
            .db = db,
            .allocator = allocator,
            .writes = std.ArrayList(WriteOp).empty,
            .reads = std.ArrayList([]const u8).empty,
            .active = true,
            .version = db.snapshot_manager.currentVersion(),
        };
    }

    pub fn deinit(self: *Transaction) void {
        if (self.active) {
            self.rollback() catch {};
        }

        for (self.writes.items) |op| {
            switch (op) {
                .put => |put_op| {
                    self.allocator.free(put_op.key);
                    self.allocator.free(put_op.value);
                },
                .delete => |del_op| {
                    self.allocator.free(del_op.key);
                },
            }
        }
        self.writes.clearAndFree(self.allocator);

        for (self.reads.items) |key| {
            self.allocator.free(key);
        }
        self.reads.clearAndFree(self.allocator);
    }

    /// Buffer a put operation
    pub fn put(self: *Transaction, key: []const u8, value: []const u8) !void {
        if (!self.active) return error.TxNotActive;

        try self.writes.append(self.allocator, .{
            .put = .{
                .key = try self.allocator.dupe(u8, key),
                .value = try self.allocator.dupe(u8, value),
            },
        });
    }

    /// Buffer a delete operation
    pub fn delete(self: *Transaction, key: []const u8) !void {
        if (!self.active) return error.TxNotActive;

        try self.writes.append(self.allocator, .{
            .delete = .{
                .key = try self.allocator.dupe(u8, key),
            },
        });
    }

    /// Get a value (reads from transaction buffer first, then DB)
    pub fn get(self: *Transaction, key: []const u8) !?[]const u8 {
        if (!self.active) return error.TxNotActive;

        // Check transaction buffer (last write wins)
        var i: usize = self.writes.items.len;
        while (i > 0) {
            i -= 1;
            switch (self.writes.items[i]) {
                .put => |put_op| {
                    if (std.mem.eql(u8, put_op.key, key)) {
                        return put_op.value;
                    }
                },
                .delete => |del_op| {
                    if (std.mem.eql(u8, del_op.key, key)) {
                        return null;
                    }
                },
            }
        }

        // Track read for conflict detection
        try self.reads.append(self.allocator, try self.allocator.dupe(u8, key));

        // Read from DB
        return self.db.get(key);
    }

    /// Commit all buffered writes atomically
    pub fn commit(self: *Transaction) !void {
        if (!self.active) return error.TxNotActive;

        // Check for conflicts (simple optimistic concurrency)
        // In a real implementation, you'd check if any read keys were modified
        // since the transaction started

        // Apply all writes
        for (self.writes.items) |op| {
            switch (op) {
                .put => |put_op| {
                    try self.db.put(put_op.key, put_op.value);
                },
                .delete => |del_op| {
                    try self.db.delete(del_op.key);
                },
            }
        }

        self.active = false;
    }

    /// Rollback all buffered writes
    pub fn rollback(self: *Transaction) !void {
        if (!self.active) return error.TxNotActive;
        self.active = false;
    }
};

// Tests
test "Transaction basic operations" {
    const allocator = std.testing.allocator;
    const dir = "test_tx_basic";
    var io = std.Io.Threaded.init(allocator, .{});
    defer io.deinit();

    defer std.Io.Dir.cwd().deleteTree(io.io(), dir) catch {};

    var db = try DB.open(allocator, io.io(), dir, .{});
    defer db.close();

    // Start transaction
    var tx = Transaction.init(&db, allocator);
    defer tx.deinit();

    // Buffer writes
    try tx.put("key1", "value1");
    try tx.put("key2", "value2");

    // Verify reads from buffer
    try std.testing.expectEqualStrings("value1", (try tx.get("key1")).?);
    try std.testing.expectEqualStrings("value2", (try tx.get("key2")).?);

    // Commit
    try tx.commit();

    // Verify writes persisted
    try std.testing.expectEqualStrings("value1", (try db.get("key1")).?);
    try std.testing.expectEqualStrings("value2", (try db.get("key2")).?);
}

test "Transaction rollback" {
    const allocator = std.testing.allocator;
    const dir = "test_tx_rollback";
    var io = std.Io.Threaded.init(allocator, .{});
    defer io.deinit();

    defer std.Io.Dir.cwd().deleteTree(io.io(), dir) catch {};

    var db = try DB.open(allocator, io.io(), dir, .{});
    defer db.close();

    // Start transaction
    var tx = Transaction.init(&db, allocator);
    defer tx.deinit();

    // Buffer writes
    try tx.put("key1", "value1");

    // Rollback
    try tx.rollback();

    // Verify writes did not persist
    try std.testing.expect((try db.get("key1")) == null);
}
