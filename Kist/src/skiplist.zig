const std = @import("std");
const Allocator = std.mem.Allocator;

/// A lock-free skip list implementation for sorted in-memory storage.
/// Used as the backing data structure for MemTable.
pub fn SkipList(comptime Key: type, comptime Value: type, comptime Context: type) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            key: Key,
            value: Value,
            /// Array of next pointers, one per level
            next: [MAX_LEVELS]?*Node,
            /// Marked for logical deletion (lock-free deletion support)
            marked: bool,
            /// Fully linked (all next pointers are valid)
            fully_linked: bool,
            level: u32,
        };

        pub const MAX_LEVELS = 32;

        pub const Entry = struct {
            key: Key,
            value: Value,
        };

        pub const Iterator = struct {
            current: ?*Node,
            list: *Self,

            pub fn next(self: *Iterator) ?Entry {
                const node = self.current orelse return null;
                if (node.marked) {
                    self.current = self.findNext(node);
                    return self.next();
                }
                const result = Entry{ .key = node.key, .value = node.value };
                self.current = self.findNext(node);
                return result;
            }

            fn findNext(self: *Iterator, node: *Node) ?*Node {
                _ = self;
                var current = node.next[0];
                while (current) |nxt| {
                    if (!nxt.marked) return nxt;
                    current = nxt.next[0];
                }
                return null;
            }

            pub fn peek(self: *const Iterator) ?Entry {
                const node = self.current orelse return null;
                if (node.marked) return null;
                return Entry{ .key = node.key, .value = node.value };
            }
        };

        allocator: Allocator,
        head: Node,
        level: std.atomic.Value(u32),
        len: std.atomic.Value(usize),
        comparator: Context,
        prng: std.Random.DefaultPrng,

        pub fn init(allocator: Allocator, comparator: Context) Self {
            var head: Node = undefined;
            head.key = undefined;
            head.value = undefined;
            head.marked = false;
            head.fully_linked = false;
            head.level = 0;
            for (&head.next) |*next| next.* = null;

            return Self{
                .allocator = allocator,
                .head = head,
                .level = std.atomic.Value(u32).init(0),
                .len = std.atomic.Value(usize).init(0),
                .comparator = comparator,
                .prng = std.Random.DefaultPrng.init(0x123456789ABCDEF0),
            };
        }

        pub fn deinit(self: *Self) void {
            var current = self.head.next[0];
            while (current) |node| {
                const next = node.next[0];
                self.allocator.free(node.key);
                self.allocator.free(node.value);
                self.allocator.destroy(node);
                current = next;
            }
        }

        /// Insert a key-value pair. Returns true if key was new, false if updated.
        /// The skip list copies and owns the key and value memory.
        pub fn put(self: *Self, key: Key, value: Value) !bool {
            const level = self.randomLevel();
            const node = try self.allocator.create(Node);
            errdefer self.allocator.destroy(node);
            node.key = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(node.key);
            node.value = try self.allocator.dupe(u8, value);
            node.marked = false;
            node.fully_linked = false;
            node.level = level;

            var right: [MAX_LEVELS]?*Node = undefined;
            for (&right) |*r| r.* = null;
            var left: [MAX_LEVELS]?*Node = undefined;

            // Initialize left array to head for all levels
            for (&left) |*l| l.* = &self.head;

            self.findPosition(key, &left, &right);

            // Check if key already exists
            if (right[0]) |existing| {
                if (self.comparator.compare(key, existing.key) == 0) {
                    // Update existing node's value
                    self.allocator.free(existing.value);
                    existing.value = node.value; // take ownership of the copy
                    self.allocator.free(node.key); // free unused key copy
                    self.allocator.destroy(node);
                    return false;
                }
            }

            // Link in the new node
            var i: u32 = 0;
            while (i < level) : (i += 1) {
                node.next[i] = right[i];
                left[i].?.next[i] = node;
            }
            node.fully_linked = true;

            _ = self.len.fetchAdd(1, .release);

            // Update max level
            while (true) {
                const current_level = self.level.load(.acquire);
                if (level <= current_level) break;
                if (self.level.cmpxchgWeak(current_level, level, .release, .acquire) == null) break;
                // CAS failed (spurious or concurrent) — retry
            }

            return true;
        }

        /// Get value by key. Returns null if not found.
        pub fn get(self: *const Self, key: Key) ?Value {
            var current: ?*Node = @constCast(&self.head);
            var i: i32 = @intCast(self.level.load(.acquire));

            while (i >= 0) : (i -= 1) {
                while (current.?.next[@intCast(i)]) |next| {
                    if (self.comparator.compare(key, next.key) <= 0) break;
                    current = next;
                }
            }

            if (current.?.next[0]) |next| {
                if (!next.marked and self.comparator.compare(key, next.key) == 0) {
                    return next.value;
                }
            }
            return null;
        }

        /// Check if key exists
        pub fn contains(self: *const Self, key: Key) bool {
            return self.get(key) != null;
        }

        /// Delete a key. Returns true if key existed.
        /// Simply marks the node as deleted; it will be skipped by get/iterator.
        /// The node is reclaimed when the memtable is cleared (flushed to SSTable).
        pub fn delete(self: *Self, key: Key) bool {
            var current: ?*Node = &self.head;
            var i: i32 = @intCast(self.level.load(.acquire));

            // Find the node
            while (i >= 0) : (i -= 1) {
                while (current.?.next[@intCast(i)]) |next| {
                    if (self.comparator.compare(key, next.key) <= 0) break;
                    current = next;
                }
            }

            if (current.?.next[0]) |target| {
                if (self.comparator.compare(key, target.key) == 0 and !target.marked) {
                    target.marked = true;
                    _ = self.len.fetchSub(1, .release);
                    return true;
                }
            }
            return false;
        }

        /// Get number of entries
        pub fn count(self: *const Self) usize {
            return self.len.load(.acquire);
        }

        /// Create an iterator starting from the beginning
        pub fn iterator(self: *Self) Iterator {
            return .{
                .current = self.head.next[0],
                .list = self,
            };
        }

        /// Create an iterator starting from a key >= the given key
        pub fn lowerBound(self: *Self, key: Key) Iterator {
            var current: ?*Node = &self.head;
            var i: i32 = @intCast(self.level.load(.acquire));

            while (i >= 0) : (i -= 1) {
                while (current.?.next[@intCast(i)]) |next| {
                    if (self.comparator.compare(key, next.key) <= 0) break;
                    current = next;
                }
            }

            return .{
                .current = if (current.?.next[0]) |n| if (!n.marked) n else null else null,
                .list = self,
            };
        }

        fn findPosition(self: *Self, key: Key, left: []?*Node, right: []?*Node) void {
            var current: ?*Node = &self.head;
            var i: i32 = @intCast(self.level.load(.acquire));

            while (i >= 0) : (i -= 1) {
                while (current.?.next[@intCast(i)]) |next| {
                    if (self.comparator.compare(key, next.key) <= 0) break;
                    current = next;
                }
                left[@intCast(i)] = current;
                right[@intCast(i)] = current.?.next[@intCast(i)];
            }
        }

        fn randomLevel(self: *Self) u32 {
            var level: u32 = 1;
            while (level < MAX_LEVELS and self.prng.random().float(f64) < 0.25) {
                level += 1;
            }
            return level;
        }
    };
}

/// Simple byte slice comparator for skip list
pub const BytesContext = struct {
    pub fn compare(self: *const BytesContext, a: []const u8, b: []const u8) i32 {
        _ = self;
        const min_len = @min(a.len, b.len);
        for (0..min_len) |i| {
            if (a[i] < b[i]) return -1;
            if (a[i] > b[i]) return 1;
        }
        if (a.len < b.len) return -1;
        if (a.len > b.len) return 1;
        return 0;
    }
};

// Tests
test "SkipList basic operations" {
    const allocator = std.testing.allocator;
    var list = SkipList([]const u8, []const u8, BytesContext).init(allocator, .{});
    defer list.deinit();

    // Insert
    _ = try list.put("hello", "world");
    _ = try list.put("foo", "bar");
    _ = try list.put("abc", "123");

    try std.testing.expectEqual(@as(usize, 3), list.count());

    // Get
    try std.testing.expectEqualStrings("world", list.get("hello").?);
    try std.testing.expectEqualStrings("bar", list.get("foo").?);
    try std.testing.expect(list.get("missing") == null);

    // Update
    const is_new = try list.put("hello", "updated");
    try std.testing.expect(!is_new);
    try std.testing.expectEqualStrings("updated", list.get("hello").?);

    // Delete
    try std.testing.expect(list.delete("foo"));
    try std.testing.expect(list.get("foo") == null);
    try std.testing.expectEqual(@as(usize, 2), list.count());
}

test "SkipList iteration" {
    const allocator = std.testing.allocator;
    var list = SkipList([]const u8, []const u8, BytesContext).init(allocator, .{});
    defer list.deinit();

    _ = try list.put("c", "3");
    _ = try list.put("a", "1");
    _ = try list.put("b", "2");

    var iter = list.iterator();
    const first = iter.next().?;
    try std.testing.expectEqualStrings("a", first.key);

    const second = iter.next().?;
    try std.testing.expectEqualStrings("b", second.key);

    const third = iter.next().?;
    try std.testing.expectEqualStrings("c", third.key);

    try std.testing.expect(iter.next() == null);
}
