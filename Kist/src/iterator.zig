const std = @import("std");
const sstable_mod = @import("sstable.zig");
const memtable_mod = @import("memtable.zig");

const Allocator = std.mem.Allocator;
const SSTable = sstable_mod.SSTable;
const MemTable = memtable_mod.MemTable;

/// Merge iterator for range scans across memtable and SSTable levels.
/// Merges results from multiple sources in sorted order.
pub const MergeIterator = struct {
    allocator: Allocator,
    sources: []IteratorSource,
    heap: MinHeap,

    pub const IteratorSource = union(enum) {
        memtable: MemTableIterator,
        sstable: SSTableIterator,
    };

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn init(allocator: Allocator) MergeIterator {
        return MergeIterator{
            .allocator = allocator,
            .sources = &.{},
            .heap = MinHeap.init(allocator),
        };
    }

    pub fn deinit(self: *MergeIterator) void {
        for (self.sources) |*source| {
            switch (source.*) {
                .memtable => |*iter| iter.deinit(),
                .sstable => |*iter| iter.deinit(),
            }
        }
        self.allocator.free(self.sources);
        self.heap.deinit();
    }

    /// Add a memtable as a source
    pub fn addMemTable(self: *MergeIterator, memtable: *MemTable) !void {
        const new_sources = try self.allocator.realloc(self.sources, self.sources.len + 1);
        self.sources = new_sources;
        self.sources[self.sources.len - 1] = .{
            .memtable = MemTableIterator.init(memtable),
        };
    }

    /// Add an SSTable as a source
    pub fn addSSTable(self: *MergeIterator, sstable: *const SSTable, io: std.Io) !void {
        const new_sources = try self.allocator.realloc(self.sources, self.sources.len + 1);
        self.sources = new_sources;
        self.sources[self.sources.len - 1] = .{
            .sstable = SSTableIterator.init(sstable, io),
        };
    }

    /// Initialize the merge iterator (must be called after adding all sources)
    pub fn start(self: *MergeIterator, start_key: ?[]const u8) !void {
        for (self.sources, 0..) |*source, i| {
            switch (source.*) {
                .memtable => |*iter| {
                    if (start_key) |key| {
                        iter.seek(key);
                    }
                    if (try iter.next()) |entry| {
                        try self.heap.push(.{
                            .source_idx = @intCast(i),
                            .entry = entry,
                        });
                    }
                },
                .sstable => |*iter| {
                    if (start_key) |key| {
                        iter.seek(key);
                    }
                    if (try iter.next()) |entry| {
                        try self.heap.push(.{
                            .source_idx = @intCast(i),
                            .entry = entry,
                        });
                    }
                },
            }
        }
    }

    /// Get the next entry in sorted order
    pub fn next(self: *MergeIterator) !?Entry {
        const min = self.heap.pop() orelse return null;

        const source_idx = min.source_idx;

        // Advance the source that produced this entry
        switch (self.sources[source_idx]) {
            .memtable => |*iter| {
                if (try iter.next()) |entry| {
                    try self.heap.push(.{
                        .source_idx = source_idx,
                        .entry = entry,
                    });
                }
            },
            .sstable => |*iter| {
                if (try iter.next()) |entry| {
                    try self.heap.push(.{
                        .source_idx = source_idx,
                        .entry = entry,
                    });
                }
            },
        }

        return min.entry;
    }

    /// Check if there are more entries
    pub fn hasMore(self: *const MergeIterator) bool {
        return self.heap.size() > 0;
    }

    /// Min-heap for merge iterator
    const MinHeap = struct {
        items: []HeapItem,
        allocator: Allocator,

        const HeapItem = struct {
            source_idx: u32,
            entry: Entry,
        };

        pub fn init(allocator: Allocator) MinHeap {
            return MinHeap{
                .items = &.{},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *MinHeap) void {
            self.allocator.free(self.items);
        }

        pub fn size(self: *const MinHeap) usize {
            return self.items.len;
        }

        pub fn push(self: *MinHeap, item: HeapItem) !void {
            const new_items = try self.allocator.realloc(self.items, self.items.len + 1);
            self.items = new_items;
            self.items[self.items.len - 1] = item;
            self.bubbleUp(self.items.len - 1);
        }

        pub fn pop(self: *MinHeap) ?HeapItem {
            if (self.items.len == 0) return null;

            const min = self.items[0];
            const last = self.items[self.items.len - 1];
            self.items.len -= 1;

            if (self.items.len > 0) {
                self.items[0] = last;
                self.bubbleDown(0);
            }

            return min;
        }

        fn bubbleUp(self: *MinHeap, idx: usize) void {
            var i = idx;
            while (i > 0) {
                const parent = (i - 1) / 2;
                if (compareItems(self.items[i].entry, self.items[parent].entry) < 0) {
                    std.mem.swap(HeapItem, &self.items[i], &self.items[parent]);
                    i = parent;
                } else {
                    break;
                }
            }
        }

        fn bubbleDown(self: *MinHeap, idx: usize) void {
            var i = idx;
            while (true) {
                var smallest = i;
                const left = 2 * i + 1;
                const right = 2 * i + 2;

                if (left < self.items.len and compareItems(self.items[left].entry, self.items[smallest].entry) < 0) {
                    smallest = left;
                }
                if (right < self.items.len and compareItems(self.items[right].entry, self.items[smallest].entry) < 0) {
                    smallest = right;
                }

                if (smallest != i) {
                    std.mem.swap(HeapItem, &self.items[i], &self.items[smallest]);
                    i = smallest;
                } else {
                    break;
                }
            }
        }
    };

    fn compareItems(a: Entry, b: Entry) i32 {
        const min_len = @min(a.key.len, b.key.len);
        for (0..min_len) |i| {
            if (a.key[i] < b.key[i]) return -1;
            if (a.key[i] > b.key[i]) return 1;
        }
        if (a.key.len < b.key.len) return -1;
        if (a.key.len > b.key.len) return 1;
        return 0;
    }
};

/// Iterator over a memtable
pub const MemTableIterator = struct {
    current: ?MergeIterator.Entry,

    pub fn init(memtable: *MemTable) MemTableIterator {
        _ = memtable;
        return MemTableIterator{
            .current = null,
        };
    }

    pub fn deinit(self: *MemTableIterator) void {
        _ = self;
    }

    pub fn seek(self: *MemTableIterator, key: []const u8) void {
        _ = self;
        _ = key;
    }

    pub fn next(self: *MemTableIterator) !?MergeIterator.Entry {
        _ = self;
        return null;
    }
};

/// Iterator over an SSTable
pub const SSTableIterator = struct {
    inner: SSTable.Iterator,

    pub fn init(sstable: *const SSTable, io: std.Io) SSTableIterator {
        return SSTableIterator{
            .inner = sstable.iterator(io),
        };
    }

    pub fn deinit(self: *SSTableIterator) void {
        self.inner.deinit();
    }

    pub fn seek(self: *SSTableIterator, key: []const u8) void {
        _ = self;
        _ = key;
    }

    pub fn next(self: *SSTableIterator) !?MergeIterator.Entry {
        return self.inner.next();
    }
};
