const std = @import("std");
const block_mod = @import("block.zig");
const bloom_mod = @import("bloom_filter.zig");

const Allocator = std.mem.Allocator;
const Block = block_mod.Block;
const BloomFilter = bloom_mod.BloomFilter;

/// SSTable (Sorted String Table) - immutable sorted on-disk file.
///
/// File layout:
/// ┌─────────────────┐
/// │  Data Block 0   │  (4KB default, prefix-compressed keys)
/// │  Data Block 1   │
/// │  ...            │
/// ├─────────────────┤
/// │  Index Block    │  (block_handle: offset + size per block)
/// ├─────────────────┤
/// │  Bloom Filter   │  (10 bits/key, ~1% false positive)
/// ├─────────────────┤
/// │  Footer (32B)   │  [index_offset: u64][index_size: u64][bloom_offset: u64][bloom_size: u64][magic: u64]
/// └─────────────────┘
pub const SSTable = struct {
    file_path: []const u8,
    index: IndexBlock,
    bloom: ?BloomFilter,
    level: u32,
    min_key: []const u8,
    max_key: []const u8,

    pub const MAGIC: u64 = 0x4b49535453535442; // "KISTSSTB"

    /// Index block entry: describes where a data block is on disk
    pub const BlockHandle = extern struct {
        offset: u64 align(1),
        size: u64 align(1),
    };

    /// Index block: array of BlockHandles
    pub const IndexBlock = struct {
        handles: []BlockHandle,
        first_keys: [][]const u8, // First key of each block (for binary search)
        allocator: Allocator,

        pub fn init(allocator: Allocator) IndexBlock {
            return IndexBlock{
                .handles = &.{},
                .first_keys = &.{},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *IndexBlock) void {
            for (self.first_keys) |key| {
                self.allocator.free(key);
            }
            self.allocator.free(self.first_keys);
            self.allocator.free(self.handles);
        }
    };

    /// Footer on disk
    pub const Footer = extern struct {
        index_offset: u64 align(1),
        index_size: u64 align(1),
        bloom_offset: u64 align(1),
        bloom_size: u64 align(1),
        magic: u64 align(1),
    };

    pub const SSTABLE_FOOTER_SIZE = @sizeOf(Footer);

    /// Writer for building an SSTable from sorted entries
    pub const Writer = struct {
        allocator: Allocator,
        file_path: []const u8,
        data_blocks: std.ArrayList(DataBlock),
        entries: std.ArrayList(Entry),

        pub const Entry = struct {
            key: []const u8,
            value: []const u8,
        };

        pub const DataBlock = struct {
            entries: []Entry,
            min_key: []const u8,
            max_key: []const u8,
        };

        pub fn init(allocator: Allocator, file_path: []const u8) Writer {
            return Writer{
                .allocator = allocator,
                .file_path = file_path,
                .data_blocks = std.ArrayList(DataBlock).empty,
                .entries = std.ArrayList(Entry).empty,
            };
        }

        pub fn deinit(self: *Writer) void {
            for (self.data_blocks.items) |db| {
                self.allocator.free(db.entries);
            }
            self.data_blocks.clearAndFree(self.allocator);
            self.entries.clearAndFree(self.allocator);
        }

        /// Add an entry (must be added in sorted order)
        pub fn add(self: *Writer, key: []const u8, value: []const u8) !void {
            try self.entries.append(self.allocator, Entry{
                .key = try self.allocator.dupe(u8, key),
                .value = try self.allocator.dupe(u8, value),
            });
        }

        /// Build the SSTable file
        pub fn finish(self: *Writer) !SSTable {
            const block_size = 4096; // Default block size

            // Split entries into data blocks
            var current_block_entries = std.ArrayList(Entry).empty;
            defer current_block_entries.clearAndFree(self.allocator);

            var block_min_key: ?[]const u8 = null;
            var block_max_key: ?[]const u8 = null;

            for (self.entries.items) |entry| {
                if (block_min_key == null) {
                    block_min_key = entry.key;
                }
                block_max_key = entry.key;

                try current_block_entries.append(self.allocator, entry);

                // Check if block is full (approximate by entry count * avg size)
                var total_size: usize = 0;
                for (current_block_entries.items) |e| {
                    total_size += 2 + e.key.len + 2 + e.value.len;
                }

                if (total_size >= block_size) {
                    // Flush this block
                    const entries_copy = try current_block_entries.toOwnedSlice(self.allocator);
                    try self.data_blocks.append(self.allocator, DataBlock{
                        .entries = entries_copy,
                        .min_key = block_min_key.?,
                        .max_key = block_max_key.?,
                    });
                    block_min_key = null;
                    block_max_key = null;
                    current_block_entries.clearRetainingCapacity();
                }
            }

            // Flush remaining entries
            if (current_block_entries.items.len > 0) {
                const entries_copy = try current_block_entries.toOwnedSlice(self.allocator);
                try self.data_blocks.append(self.allocator, DataBlock{
                    .entries = entries_copy,
                    .min_key = block_min_key.?,
                    .max_key = block_max_key.?,
                });
            }

            // Build bloom filter
            var bloom = try BloomFilter.init(self.allocator, self.entries.items.len, 10);
            for (self.entries.items) |entry| {
                bloom.add(entry.key);
            }

            // Write to disk
            return try writeSSTable(self.allocator, self.file_path, self.data_blocks.items, &bloom);
        }
    };

    /// Write an SSTable file
    fn writeSSTable(
        allocator: Allocator,
        file_path: []const u8,
        data_blocks: []Writer.DataBlock,
        bloom: *const BloomFilter,
    ) !SSTable {
        // Open file for writing
        const dir = std.Io.Dir.cwd();
        const io = try getIo();
        const file = try dir.createFile(io, file_path, .{
            .truncate = true,
            .read = true,
        });
        defer file.close(io);

        var file_pos: u64 = 0;
        var index_handles = std.ArrayList(BlockHandle).empty;
        defer index_handles.clearAndFree(allocator);

        var first_keys = std.ArrayList([]const u8).empty;
        defer {
            for (first_keys.items) |key| {
                allocator.free(key);
            }
            first_keys.clearAndFree(allocator);
        }

        // Write data blocks
        for (data_blocks) |data_block| {
            // Encode block
            const block = try Block.encode(allocator, data_block.entries);
            defer allocator.free(block.data);

            const block_handle = BlockHandle{
                .offset = file_pos,
                .size = @intCast(block.data.len),
            };

            try file.writeStreamingAll(io, block.data);
            file_pos += block.data.len;

            try index_handles.append(allocator, block_handle);
            try first_keys.append(allocator, try allocator.dupe(u8, data_block.min_key));
        }

        // Write index block
        const index_offset = file_pos;
        for (index_handles.items) |handle| {
            try file.writeStreamingAll(io, std.mem.asBytes(&handle));
        }
        const index_size = file_pos - index_offset;

        // Write bloom filter
        const bloom_offset = file_pos;
        try file.writeStreamingAll(io, bloom.encode());
        const bloom_size = bloom.encodedSize();

        // Write footer
        const footer = Footer{
            .index_offset = index_offset,
            .index_size = index_size,
            .bloom_offset = bloom_offset,
            .bloom_size = bloom_size,
            .magic = MAGIC,
        };
        try file.writeStreamingAll(io, std.mem.asBytes(&footer));

        // Build SSTable struct
        const min_key = if (data_blocks.len > 0) try allocator.dupe(u8, data_blocks[0].min_key) else try allocator.dupe(u8, "");
        const max_key = if (data_blocks.len > 0) try allocator.dupe(u8, data_blocks[data_blocks.len - 1].max_key) else try allocator.dupe(u8, "");

        const handles_copy = try index_handles.toOwnedSlice(allocator);
        const first_keys_copy = try first_keys.toOwnedSlice(allocator);

        return SSTable{
            .file_path = try allocator.dupe(u8, file_path),
            .index = IndexBlock{
                .handles = handles_copy,
                .first_keys = first_keys_copy,
                .allocator = allocator,
            },
            .bloom = bloom.*,
            .level = 0,
            .min_key = min_key,
            .max_key = max_key,
        };
    }

    /// Get the io - temporary helper until we refactor to pass io through
    fn getIo() !std.Io {
        // This is a workaround. In a real implementation, io should be passed in.
        return error.IoNotAvailable;
    }

    /// Read an SSTable from disk
    pub fn open(allocator: Allocator, file_path: []const u8, io: std.Io) !SSTable {
        var dir = std.Io.Dir.cwd();
        const file = try dir.openFile(io, file_path, .{ .mode = .read_only });
        defer file.close(io);

        const stat = try file.stat(io);
        const file_size = stat.size;

        if (file_size < SSTABLE_FOOTER_SIZE) return error.Corrupted;

        // Read footer
        var footer_buf: [SSTABLE_FOOTER_SIZE]u8 = undefined;
        _ = try file.readPositionalAll(io, &footer_buf, file_size - SSTABLE_FOOTER_SIZE);
        const footer: Footer = @bitCast(footer_buf);

        if (footer.magic != MAGIC) return error.Corrupted;

        // Read index block
        const index_data = try allocator.alloc(u8, @intCast(footer.index_size));
        defer allocator.free(index_data);
        _ = try file.readPositionalAll(io, index_data, footer.index_offset);

        // Parse index block
        const num_blocks: u32 = @intCast(@divExact(footer.index_size, @sizeOf(BlockHandle)));
        const handles: [*]BlockHandle = @alignCast(@ptrCast(index_data.ptr));
        const index_handles = handles[0..num_blocks];

        // Read first keys from data blocks
        var first_keys = try allocator.alloc([]const u8, num_blocks);
        errdefer {
            for (first_keys) |key| allocator.free(key);
            allocator.free(first_keys);
        }

        for (index_handles, 0..) |handle, i| {
            // Read first entry of each block to get the first key
            if (handle.size < 6) return error.Corrupted; // Need at least key_len(2) + key(1) + val_len(2)

            var len_buf: [2]u8 = undefined;
            _ = try file.readPositionalAll(io, &len_buf, handle.offset);
            const first_key_len = std.mem.readInt(u16, &len_buf, .little);

            if (first_key_len > handle.size) return error.Corrupted;

            const key_buf = try allocator.alloc(u8, first_key_len);
            _ = try file.readPositionalAll(io, key_buf, handle.offset + 2);
            first_keys[i] = key_buf;
        }

        // Copy handles to owned slice
        const handles_copy = try allocator.dupe(BlockHandle, index_handles);

        // Read bloom filter
        var bloom: ?BloomFilter = null;
        if (footer.bloom_size > 0) {
            const bloom_data = try allocator.alloc(u8, @intCast(footer.bloom_size));
            _ = try file.readPositionalAll(io, bloom_data, footer.bloom_offset);
            const num_bits: u32 = @intCast(footer.bloom_size * 8);
            const num_hashes: u32 = @max(1, (num_bits * 69 / 100) / @max(1, num_bits / 10));
            bloom = BloomFilter.decode(bloom_data, num_bits, @min(num_hashes, 30));
        }

        // Get min/max keys
        const min_key = if (first_keys.len > 0) try allocator.dupe(u8, first_keys[0]) else try allocator.dupe(u8, "");
        errdefer allocator.free(min_key);
        const max_key = if (first_keys.len > 0) blk: {
            // Read last entry of last block to get max key
            const last_handle = index_handles[index_handles.len - 1];
            var last_buf = try allocator.alloc(u8, @intCast(last_handle.size));
            defer allocator.free(last_buf);
            _ = try file.readPositionalAll(io, last_buf, last_handle.offset);

            // Parse last entry
            var pos: usize = 0;
            var last_key: []const u8 = "";
            while (pos < last_buf.len) {
                if (pos + 2 > last_buf.len) break;
                const klen = std.mem.readInt(u16, last_buf[pos..][0..2], .little);
                pos += 2;
                if (pos + klen > last_buf.len) break;
                last_key = last_buf[pos..][0..klen];
                pos += klen;
                if (pos + 2 > last_buf.len) break;
                const vlen = std.mem.readInt(u16, last_buf[pos..][0..2], .little);
                pos += 2;
                pos += vlen;
            }
            break :blk try allocator.dupe(u8, last_key);
        } else try allocator.dupe(u8, "");
        errdefer allocator.free(max_key);

        return SSTable{
            .file_path = try allocator.dupe(u8, file_path),
            .index = IndexBlock{
                .handles = handles_copy,
                .first_keys = first_keys,
                .allocator = allocator,
            },
            .bloom = bloom,
            .level = 0,
            .min_key = min_key,
            .max_key = max_key,
        };
    }

    pub fn deinit(self: *SSTable) void {
        self.index.deinit();
        if (self.bloom) |*b| {
            b.deinit(self.index.allocator);
        }
        self.index.allocator.free(self.file_path);
        self.index.allocator.free(self.min_key);
        self.index.allocator.free(self.max_key);
    }

    /// Look up a key in the SSTable
    pub fn get(self: *const SSTable, key: []const u8, io: std.Io) !?[]const u8 {
        // Check bloom filter first (fast negative lookup)
        if (self.bloom) |bloom| {
            if (!bloom.mightContain(key)) return null;
        }

        // Binary search index to find the right block
        const block_idx = self.findIndexBlock(key);
        if (block_idx >= self.index.handles.len) return null;

        const handle = self.index.handles[block_idx];

        // Read the data block
        var dir = std.Io.Dir.cwd();
        const file = try dir.openFile(io, self.file_path, .{ .mode = .read_only });
        defer file.close(io);

        const block_data = try self.index.allocator.alloc(u8, @intCast(handle.size));
        defer self.index.allocator.free(block_data);

        _ = try file.readPositionalAll(io, block_data, handle.offset);

        var block = Block.decode(block_data);

        // Binary search within the block
        const idx = block.lowerBound(key);
        if (idx >= block.num_entries) return null;

        const entry = block.get(idx) orelse return null;
        if (std.mem.eql(u8, entry.key, key)) {
            return entry.value;
        }
        return null;
    }

    /// Create an iterator over the SSTable
    pub fn iterator(self: *const SSTable, io: std.Io) Iterator {
        return Iterator{
            .sstable = self,
            .io = io,
            .block_idx = 0,
            .entry_idx = 0,
            .block_data = null,
            .current_block = null,
        };
    }

    pub const Iterator = struct {
        sstable: *const SSTable,
        io: std.Io,
        block_idx: u32,
        entry_idx: u32,
        block_data: ?[]u8,
        current_block: ?Block,

        pub fn next(self: *Iterator) !?Block.Entry {
            while (self.block_idx < self.sstable.index.handles.len) {
                if (self.current_block == null) {
                    // Load next block
                    const handle = self.sstable.index.handles[self.block_idx];
                    var dir = std.Io.Dir.cwd();
                    const file = try dir.openFile(self.io, self.sstable.file_path, .{ .mode = .read_only });
                    defer file.close(self.io);

                    self.block_data = try self.sstable.index.allocator.alloc(u8, @intCast(handle.size));
                    _ = try file.readPositionalAll(self.io, self.block_data.?, handle.offset);
                    self.current_block = Block.decode(self.block_data.?);
                }

                const block = self.current_block.?;
                if (self.entry_idx < block.num_entries) {
                    const entry = block.get(self.entry_idx);
                    self.entry_idx += 1;
                    return entry;
                }

                // Move to next block
                if (self.block_data) |data| {
                    self.sstable.index.allocator.free(data);
                }
                self.block_data = null;
                self.current_block = null;
                self.block_idx += 1;
                self.entry_idx = 0;
            }
            return null;
        }

        pub fn deinit(self: *Iterator) void {
            if (self.block_data) |data| {
                self.sstable.index.allocator.free(data);
            }
        }
    };

    /// Find which data block might contain the key
    fn findIndexBlock(self: *const SSTable, key: []const u8) u32 {
        // Binary search on first_keys
        var lo: u32 = 0;
        var hi: u32 = @intCast(self.index.first_keys.len);

        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (compareBytes(self.index.first_keys[mid], key) <= 0) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }

        // lo-1 is the block that might contain the key
        return if (lo > 0) lo - 1 else 0;
    }

    fn compareBytes(a: []const u8, b: []const u8) i32 {
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
